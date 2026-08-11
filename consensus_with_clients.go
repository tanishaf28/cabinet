package main

import (
	"cabinet/mongodb"
	"fmt"
	"math/rand"
	"sort"
	"time"
)

func repliedServerIDs(replies []ReplyInfo) []int {
	ids := make([]int, 0, len(replies))
	seen := make(map[int]struct{}, len(replies))
	for _, r := range replies {
		if _, ok := seen[r.SID]; ok {
			continue
		}
		seen[r.SID] = struct{}{}
		ids = append(ids, r.SID)
	}
	sort.Ints(ids)
	return ids
}

func missingFollowerIDs(expected map[serverID]priority, replies []ReplyInfo) []int {
	responded := make(map[int]struct{}, len(replies))
	for _, r := range replies {
		responded[r.SID] = struct{}{}
	}
	missing := make([]int, 0, len(expected))
	for sid := range expected {
		if _, ok := responded[sid]; !ok {
			missing = append(missing, sid)
		}
	}
	sort.Ints(missing)
	return missing
}

func validateClientRequestPayload(clientReq *ClientArgs) error {
	if clientReq == nil {
		return fmt.Errorf("nil client request")
	}

	// Reads carry no CmdPlain/CmdMongo payload -- there's nothing to commit,
	// only ObjIDs to look up -- so the emptiness checks below don't apply.
	if clientReq.IsRead {
		if len(clientReq.ObjIDs) == 0 && clientReq.ObjID == "" {
			return fmt.Errorf("read request has no ObjID(s)")
		}
		return nil
	}

	switch clientReq.Type {
	case PlainMsg:
		if len(clientReq.CmdPlain) == 0 {
			return fmt.Errorf("empty plain-message batch")
		}
		for i := 0; i < len(clientReq.CmdPlain); i++ {
			if len(clientReq.CmdPlain[i]) == 0 {
				return fmt.Errorf("empty plain payload at index %d", i)
			}
		}
	case MongoDB:
		if len(clientReq.CmdMongo) == 0 {
			return fmt.Errorf("empty mongodb batch")
		}
	}

	return nil
}

func startSyncCabInstanceWithClients() {
	leaderPClock := 0

	crashList := prepCrashList()
	log.Infof("crash list prepared. Leader entering serial loop")

	for {
		select {
		case <-shutdownSignal:
			shutdownInProgress.Store(true)
			log.Infof("Leader: graceful shutdown signal received, draining queue...")
			drainDeadline := time.Now().Add(10 * time.Second)
			for {
				select {
				case clientReqWrapper := <-clientRequestQueue:
					if clientReqWrapper == nil {
						close(shutdownComplete)
						return
					}
					clientReqWrapper.Resp <- &ClientReply{Success: false, ErrorMsg: "server shutting down"}
					if time.Now().After(drainDeadline) {
						close(shutdownComplete)
						return
					}
				case <-time.After(100 * time.Millisecond):
					close(shutdownComplete)
					return
				}
			}

		case clientReqWrapper := <-clientRequestQueue:
			if clientReqWrapper == nil {
				log.Infof("Leader: clientRequestQueue closed")
				close(shutdownComplete)
				return
			}

			if shutdownInProgress.Load() {
				clientReqWrapper.Resp <- &ClientReply{Success: false, ErrorMsg: "server shutting down"}
				continue
			}

			clientReq := clientReqWrapper.Args

			requestStartTime := clientReqWrapper.StartTime
			if requestStartTime.IsZero() {
				requestStartTime = time.Now()
			}

			if err := validateClientRequestPayload(clientReq); err != nil {
				log.Errorf("rejecting invalid client request | err: %v", err)
				clientReqWrapper.Resp <- &ClientReply{
					Success:  false,
					ErrorMsg: err.Error(),
				}
				continue
			}

			myPClock := leaderPClock
			leaderPClock++
			fpriorities := pManager.GetFollowerPriorities(myPClock)

			if myPClock == crashTime && crashMode != 0 {
				log.Warnf("[CRASH] Leader dropping connections to %v at pClock=%d (simulating crash)", crashList, myPClock)
				conns.Lock()
				for _, sID := range crashList {
					delete(conns.m, sID)
				}
				conns.Unlock()
			}

			// Inline consensus (no goroutine): fully serial like original Cabinet.
			perfM.RecordStarter(myPClock)

			receiver := make(chan ReplyInfo, numOfServers)
			issueClientOps(myPClock, fpriorities, "CabService.ConsensusService", receiver, clientReq)

			prioSum := mypriority.GetPrioVal()
			prioQueue := make(chan serverID, numOfServers)
			var repliesReceived []ReplyInfo

			timeoutDur := 5 * time.Second
			if shutdownInProgress.Load() {
				timeoutDur = 250 * time.Millisecond
			}
			timeout := time.After(timeoutDur)
			reached := false

			for !reached {
				select {
				case rinfo := <-receiver:
					repliesReceived = append(repliesReceived, rinfo)
					if w, ok := fpriorities[rinfo.SID]; ok {
						prioSum += w
					}

					if prioSum > mypriority.GetMajority() {
						var readValues []interface{}

						if clientReq.IsRead {
							// Quorum (ReadIndex-style) read: the priority quorum reached above
							// already confirms this leader is still backed by a majority for
							// pClock myPClock, exactly as it would for a write at this slot.
							// Cabinet has no per-object value on followers (only the leader
							// calls UpdateObjectCommit), so the value answered is always the
							// leader's own local ObjectState.Value -- there is no fast/local
							// read path to fall back to.
							ids := clientReq.ObjIDs
							if len(ids) == 0 {
								ids = []string{clientReq.ObjID}
							}
							readValues = make([]interface{}, len(ids))
							for i, objID := range ids {
								if obj := mystate.GetObject(objID); obj != nil {
									obj.Lock()
									readValues[i] = obj.Value
									obj.Unlock()
								}
							}
							mystate.AddCommitIndex(batchsize)
						} else {
							switch clientReq.Type {
							case PlainMsg:
								bsz := len(clientReq.CmdPlain)
								conflictOps, slowOps := 0, 0
								for i := 0; i < bsz; i++ {
									objID := clientReq.ObjID
									if i < len(clientReq.ObjIDs) {
										objID = clientReq.ObjIDs[i]
									}
									mystate.UpdateObjectCommit(objID, mystate.GetLeaderID(), [][]byte{clientReq.CmdPlain[i]}, "SLOW")

									objType := clientReq.ObjType
									if i < len(clientReq.ObjTypes) {
										objType = clientReq.ObjTypes[i]
									}
									if objType == DependentObject {
										perfM.IncConflict(myPClock)
										conflictOps++
									} else {
										perfM.IncSlowPath(myPClock)
										slowOps++
									}
								}
								mystate.AddCommitIndex(batchsize)
								if conflictOps > 0 {
									perfM.AddConflictCommits(conflictOps)
								}
								if slowOps > 0 {
									perfM.AddSlowCommits(slowOps)
								}

							case MongoDB:
								bsz := len(clientReq.CmdMongo)
								conflictOps, slowOps := 0, 0
								for i := 0; i < bsz; i++ {
									objID := clientReq.ObjID
									if i < len(clientReq.ObjIDs) {
										objID = clientReq.ObjIDs[i]
									}
									mystate.UpdateObjectCommit(objID, mystate.GetLeaderID(), []mongodb.Query{clientReq.CmdMongo[i]}, "SLOW")

									objType := clientReq.ObjType
									if i < len(clientReq.ObjTypes) {
										objType = clientReq.ObjTypes[i]
									}
									if objType == DependentObject {
										perfM.IncConflict(myPClock)
										conflictOps++
									} else {
										perfM.IncSlowPath(myPClock)
										slowOps++
									}
								}
								mystate.AddCommitIndex(batchsize)
								if conflictOps > 0 {
									perfM.AddConflictCommits(conflictOps)
								}
								if slowOps > 0 {
									perfM.AddSlowCommits(slowOps)
								}
								// Followers deferred their own MongoDB write
								// during the proposal phase (see
								// conJobMongoDB/MongoConfirm doc) - now that
								// quorum is confirmed, tell them to apply it
								// for real.
								go broadcastMongoConfirm(clientReq.CmdMongo)

							default:
								mystate.AddCommitIndex(batchsize)
							}
						}

						fullLatency := time.Since(requestStartTime)
						log.Infof("[LATENCY] pClock=%d | Full=%dms", myPClock, fullLatency.Milliseconds())

						perfM.RecordFinisher(myPClock)

						clientReqWrapper.Resp <- &ClientReply{
							LeaderClock: myPClock,
							Success:     true,
							ExeResult:   fullLatency.String(),
							ReadValues:  readValues,
						}

						sort.Slice(repliesReceived, func(i, j int) bool {
							return repliesReceived[i].Timestamp.Before(repliesReceived[j].Timestamp)
						})
						for _, rinfo := range repliesReceived {
							prioQueue <- rinfo.SID
						}
						close(prioQueue)

						if err := pManager.UpdateFollowerPriorities(myPClock+1, prioQueue, mystate.GetLeaderID()); err != nil {
							log.Errorf("UpdateFollowerPriorities failed pClock=%d | err: %v", myPClock, err)
						}
						pscheme := pManager.GetPriorityScheme()
						if len(pscheme) > 0 {
							if err := mypriority.UpdatePriority(myPClock+1, pscheme[0]); err != nil {
								log.Errorf("Leader priority update failed pClock=%d: %v", myPClock, err)
							}
						}

						reached = true
					}

				case <-timeout:
					if shutdownInProgress.Load() {
						clientReqWrapper.Resp <- &ClientReply{LeaderClock: myPClock, Success: false, ErrorMsg: "server shutting down"}
					} else {
						log.Errorf("TIMEOUT at pClock=%d | Responded=%v | Missing=%v",
							myPClock, repliedServerIDs(repliesReceived), missingFollowerIDs(fpriorities, repliesReceived))
						perfM.RecordFinisher(myPClock)
						clientReqWrapper.Resp <- &ClientReply{LeaderClock: myPClock, Success: false, ErrorMsg: "consensus timeout"}
					}
					reached = true
				}
			}
		}
	}
}

// issueClientOps broadcasts client operations to all followers
func issueClientOps(pClock prioClock, p map[serverID]priority, method string, r chan ReplyInfo, clientReq *ClientArgs) {
	conns.RLock()
	defer conns.RUnlock()

	for _, conn := range conns.m {
		args := &Args{
			PrioClock: pClock,
			PrioVal:   p[conn.serverID],
			Type:      clientReq.Type,
			CmdPlain:  clientReq.CmdPlain,
			CmdMongo:  clientReq.CmdMongo,
		}

		go executeRPC(conn, method, args, r)
	}
}


func issuePlainMsgOps(pClock prioClock, p map[serverID]priority, method string, r chan ReplyInfo) {
	conns.RLock()
	defer conns.RUnlock()

	var plainMessage [][]byte
	for i := 0; i < batchsize; i++ {
		plainMessage = append(plainMessage, genRandomBytes(msgsize))
	}

	for _, conn := range conns.m {
		args := &Args{
			PrioClock: pClock,
			PrioVal:   p[conn.serverID],
			Type:      PlainMsg,
			CmdPlain:  plainMessage,
		}

		go executeRPC(conn, method, args, r)
	}
}

func issueMongoDBOps(pClock prioClock, p map[serverID]priority, method string, r chan ReplyInfo, allQueries []mongodb.Query) (allDone bool) {
	conns.RLock()
	defer conns.RUnlock()

	// [|0 ,1, 2 | -> first round
	//, 3 , 4, 5 ] -> second round
	left := pClock * batchsize
	right := (pClock + 1) * batchsize
	if right > len(allQueries) {
		log.Infof("MongoDB evaluation finished")
		allDone = true
		return
	}

	for _, conn := range conns.m {
		args := &Args{
			PrioClock: pClock,
			PrioVal:   p[conn.serverID],
			Type:      MongoDB,
			CmdMongo:  allQueries[left:right],
		}

		go executeRPC(conn, method, args, r)
	}

	return
}

// broadcastMongoConfirm best-effort-notifies every follower that a MongoDB
// round actually reached quorum, so each should now physically apply
// queries to its own local MongoDB (see conJobMongoDB/conJobMongoConfirm and
// the MongoConfirm doc comment in parameters.go). Errors are intentionally
// ignored: no cluster agreement is needed to apply a value every recipient
// already voted yes for during the proposal phase.
func broadcastMongoConfirm(queries []mongodb.Query) {
	args := &Args{Type: MongoConfirm, CmdMongo: queries}
	conns.RLock()
	defer conns.RUnlock()
	for _, conn := range conns.m {
		go func(c *ServerDock) {
			reply := Reply{}
			_ = c.txClient.Call("CabService.ConsensusService", args, &reply)
		}(conn)
	}
}

func prepCrashList() (crashList []int) {
	switch crashMode {
	case 0:
		break
	case 1:
		for i := 1; i < quorum; i++ {
			crashList = append(crashList, i)
		}
	case 2:
		for i := 1; i < quorum; i++ {
			crashList = append(crashList, numOfServers-i)
		}
	case 3:
		// // evenly distributed
		// for i := 0; i < 5; i++ {
		// 	for j := 1; j <= (quorum-1) / 5; j++ {
		// 		crashList = append(crashList, i*(numOfServers/5) + j)
		// 	}
		// }

		// randomly distributed
		rand.Seed(time.Now().UnixNano())

		for i := 1; i < quorum; i++ {
			contains := false
			for {
				crashID := rand.Intn(numOfServers-1) + 1

				for _, cID := range crashList {
					if cID == crashID {
						contains = true
						break
					}
				}

				if contains {
					contains = false
					continue
				} else {
					crashList = append(crashList, crashID)
					break
				}
			}
		}
	case 4:
		// Crash exactly one explicit replica, regardless of F - lets you
		// compare a single failure against the usual F-replica crash test.
		if crashTarget >= 0 {
			crashList = append(crashList, crashTarget)
		}
	default:
		break
	}

	return
}

func executeRPC(conn *ServerDock, serviceMethod string, args *Args, receiver chan ReplyInfo) {
	reply := Reply{}

	log.Debugf("[RPC-DEBUG] Calling %s on server %d for pClock %d", serviceMethod, conn.serverID, args.PrioClock)

	stack := make(chan struct{}, 1)
	var prev chan struct{}

	conn.jobQMu.Lock()
	conn.jobQ[args.PrioClock] = stack
	if args.PrioClock > 0 {
		prev = conn.jobQ[args.PrioClock-1]
	}
	conn.jobQMu.Unlock()

	if prev != nil {
		// Waiting for the completion of its previous RPC
		<-prev
	}

	defer func() {
		conn.jobQMu.Lock()
		if ch, ok := conn.jobQ[args.PrioClock]; ok {
			select {
			case ch <- struct{}{}:
			default:
			}
		}
		// Bug #5 fix: Prune old jobQ entries to prevent memory leak
		if args.PrioClock >= 10 {
			delete(conn.jobQ, args.PrioClock-10)
		}
		conn.jobQMu.Unlock()
	}()

	err := conn.txClient.Call(serviceMethod, args, &reply)
	callArrivalTime := time.Now() // Record arrival timestamp (Bug #1: FIFO ordering)

	if err != nil {
		log.Errorf("RPC call error: %v", err)
		markFollowerFailure(conn)
		return
	}
	markFollowerSuccess(conn)

	rinfo := ReplyInfo{
		SID:       conn.serverID,
		PClock:    args.PrioClock,
		Recv:      reply,
		Timestamp: callArrivalTime, // Include timestamp for ordering (Bug #1)
	}
	receiver <- rinfo

	log.Debugf("RPC %s succeeded | result: %+v", serviceMethod, rinfo)
}

// Helper to get object type name for logging
func getObjectTypeName(objType int) string {
	switch objType {
	case IndependentObject:
		return "INDEP"
	case DependentObject:
		return "DEP"
	default:
		return "UNKNOWN"
	}
}