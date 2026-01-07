package main

import (
	"cabinet/mongodb"
	"math/rand"
	"time"
)

func startSyncCabInstanceWithClients() {
	leaderPClock := 0

	// Load MongoDB queries if needed (currently unused, but kept for future use)
	var mongoDBQueries []mongodb.Query
	if evalType == MongoDB {
		var err error
		mongoDBQueries, err = mongodb.ReadQueryFromFile(mongodb.DataPath + "run_workload" + mongoLoadType + ".dat")
		if err != nil {
			log.Errorf("ReadQueryFromFile failed | err: %v", err)
			return
		}
		_ = mongoDBQueries // Mark as intentionally unused for now
	}

	// prepare crash list
	crashList := prepCrashList()
	log.Infof("crash list was successfully prepared.")

	log.Infof("Leader waiting for client requests...")

	for {
		// Wait for client request wrapper (contains args + response channel)
		clientReqWrapper := <-clientRequestQueue
		clientReq := clientReqWrapper.Args
		
		// Use the request's original start time for accurate full-system latency
		requestStartTime := clientReqWrapper.StartTime
		if requestStartTime.IsZero() {
			requestStartTime = time.Now() // Fallback for backwards compatibility
		}
		
		consensusStartTime := time.Now() // When consensus actually begins
		queueWaitTime := time.Since(requestStartTime)

		log.Debugf("[LATENCY-BREAKDOWN] Starting consensus | pClock: %d | QueueWaitTime: %v ms", 
			leaderPClock, queueWaitTime.Milliseconds())

		
		perfM.RecordStarter(leaderPClock)

		primaryObjID := clientReq.ObjID
		primaryObjType := clientReq.ObjType
		if len(clientReq.ObjIDs) > 0 {
			primaryObjID = clientReq.ObjIDs[0]
		}
		if len(clientReq.ObjTypes) > 0 {
			primaryObjType = clientReq.ObjTypes[0]
		}
		objTypeName := getObjectTypeName(primaryObjType)
		log.Infof("Processing client request | ClientID: %d | ClientClock: %d | ObjID: %s | ObjType: %s",
			clientReq.ClientID, clientReq.ClientClock, primaryObjID, objTypeName)

		serviceMethod := "CabService.ConsensusService"
		receiver := make(chan ReplyInfo, numOfServers)

		// crash tests
		if leaderPClock == crashTime && crashMode != 0 {
			conns.Lock()
			for _, sID := range crashList {
				delete(conns.m, sID)
			}
			conns.Unlock()
		}

		

		// 1. get priority
		fpriorities := pManager.GetFollowerPriorities(leaderPClock)
		log.Infof("pClock: %v | priorities: %+v", leaderPClock, fpriorities)
		log.Infof("pClock: %v | quorum size (t+1) is %v | majority: %v", leaderPClock, pManager.GetQuorumSize(), pManager.GetMajority())

		// 2. broadcast rpcs with client data
		broadcastStartTime := time.Now()
		issueClientOps(leaderPClock, fpriorities, serviceMethod, receiver, clientReq)
		broadcastTime := time.Since(broadcastStartTime)
		log.Debugf("[LATENCY-BREAKDOWN] pClock %d | BroadcastTime: %v μs", leaderPClock, broadcastTime.Microseconds())

		// 3. waiting for results
		quorumWaitStartTime := time.Now()
		prioSum := mypriority.PrioVal
		prioQueue := make(chan serverID, numOfServers)
		var followersResults []ReplyInfo

		timeout := time.After(5 * time.Second)
		reached := false

		for !reached {
			select {
			case rinfo := <-receiver:
				prioQueue <- rinfo.SID
				log.Infof("recv pClock: %v | serverID: %v", leaderPClock, rinfo.SID)

				fpriorities := pManager.GetFollowerPriorities(leaderPClock)
				prioSum += fpriorities[rinfo.SID]
				followersResults = append(followersResults, rinfo)

				if prioSum > mypriority.Majority {
					// Perform per-object commits (mirror WOC semantics).
					// For PlainMsg use CmdPlain; for MongoDB use CmdMongo. If per-op ObjIDs
					// are provided, use them; otherwise fall back to the primary ObjID.
					switch clientReq.Type {
					case PlainMsg:
						bsz := len(clientReq.CmdPlain)
						for i := 0; i < bsz; i++ {
							objID := clientReq.ObjID
							if len(clientReq.ObjIDs) > i {
								objID = clientReq.ObjIDs[i]
							}

							// payload is a single-operation slice for UpdateObjectCommit
							payload := [][]byte{clientReq.CmdPlain[i]}

							mystate.UpdateObjectCommit(objID, mystate.GetLeaderID(), payload, "SLOW")

							if obj := mystate.GetObject(objID); obj != nil {
								obj.Lock()
								obj.LastCommitType = "SLOW"
								obj.LastCommitTime = time.Now()
								obj.Unlock()
							}

							mystate.AddCommitIndex(batchsize)
							
							// Record per-operation metrics: conflicts for hot objects, slow path for others
							objType := clientReq.ObjType
							if len(clientReq.ObjTypes) > i {
								objType = clientReq.ObjTypes[i]
							}
							if objType == HotObject {
								perfM.IncConflict(leaderPClock)
							} else {
								perfM.IncSlowPath(leaderPClock)
							}
						}
						// Count conflicts and slow commits separately
						conflictOps := 0
						slowOps := 0
						for i := 0; i < bsz; i++ {
							objType := clientReq.ObjType
							if len(clientReq.ObjTypes) > i {
								objType = clientReq.ObjTypes[i]
							}
							if objType == HotObject {
								conflictOps++
							} else {
								slowOps++
							}
						}
						if conflictOps > 0 {
							perfM.AddConflictCommits(conflictOps)
						}
						if slowOps > 0 {
							perfM.AddSlowCommits(slowOps)
						}

					case MongoDB:
						bsz := len(clientReq.CmdMongo)
						for i := 0; i < bsz; i++ {
							objID := clientReq.ObjID
							if len(clientReq.ObjIDs) > i {
								objID = clientReq.ObjIDs[i]
							}

							payload := []mongodb.Query{clientReq.CmdMongo[i]}

							mystate.UpdateObjectCommit(objID, mystate.GetLeaderID(), payload, "SLOW")

							if obj := mystate.GetObject(objID); obj != nil {
								obj.Lock()
								obj.LastCommitType = "SLOW"
								obj.LastCommitTime = time.Now()
								obj.Unlock()
							}

							mystate.AddCommitIndex(batchsize)
							
							// Record per-operation metrics: conflicts for hot objects, slow path for others
							objType := clientReq.ObjType
							if len(clientReq.ObjTypes) > i {
								objType = clientReq.ObjTypes[i]
							}
							if objType == HotObject {
								perfM.IncConflict(leaderPClock)
							} else {
								perfM.IncSlowPath(leaderPClock)
							}
						}
						// Count conflicts and slow commits separately
						conflictOps := 0
						slowOps := 0
						for i := 0; i < bsz; i++ {
							objType := clientReq.ObjType
							if len(clientReq.ObjTypes) > i {
								objType = clientReq.ObjTypes[i]
							}
							if objType == HotObject {
								conflictOps++
							} else {
								slowOps++
							}
						}
						if conflictOps > 0 {
							perfM.AddConflictCommits(conflictOps)
						}
						if slowOps > 0 {
							perfM.AddSlowCommits(slowOps)
						}

					default:
						// Fallback: advance by configured batchsize
						mystate.AddCommitIndex(batchsize)
					}

					quorumWaitTime := time.Since(quorumWaitStartTime)
					consensusTime := time.Since(consensusStartTime)
					fullLatency := time.Since(requestStartTime)
					commitTime := time.Since(consensusStartTime) - quorumWaitTime
					
					log.Infof("[LATENCY-BREAKDOWN] Consensus reached | pClock: %v | QueueWait: %v ms | Broadcast: %v μs | QuorumWait: %v ms | Commit: %v μs | ConsensusTotal: %v ms | FullLatency: %v ms | cmtIndex: %v",
						leaderPClock, queueWaitTime.Milliseconds(), broadcastTime.Microseconds(), 
						quorumWaitTime.Milliseconds(), commitTime.Microseconds(), 
						consensusTime.Milliseconds(), fullLatency.Milliseconds(), mystate.GetCommitIndex())

					// Send success response to the specific client RPC
					clientReqWrapper.Resp <- &ClientReply{
						LeaderClock: leaderPClock,
						Success:     true,
						ExeResult:   fullLatency.String(),
					}

					reached = true
				}

			case <-timeout:
				log.Errorf("timeout waiting for responses at pClock %v; check connections with followers!", leaderPClock)
				
				// ✅ Finish measurement even on timeout
				perfM.RecordFinisher(leaderPClock)
				
				// Send timeout error to the specific client RPC
				clientReqWrapper.Resp <- &ClientReply{
					LeaderClock: leaderPClock,
					Success:     false,
					ErrorMsg:    "consensus timeout",
				}
				return
			}
		}

		leaderPClock++
		
		//  END consensus-layer measurement AFTER pClock update (server-side metrics for all clients)
		perfM.RecordFinisher(leaderPClock - 1) // Record for the just-completed pClock
		
		err := pManager.UpdateFollowerPriorities(leaderPClock, prioQueue, mystate.GetLeaderID())
		if err != nil {
			log.Errorf("UpdateFollowerPriorities failed | err: %v", err)
			return
		}

		log.Infof("prio updated for pClock %v", leaderPClock)
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
	right := (pClock+1)*batchsize - 1
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
	default:
		break
	}

	return
}

func executeRPC(conn *ServerDock, serviceMethod string, args *Args, receiver chan ReplyInfo) {
	reply := Reply{}

	stack := make(chan struct{}, 1)

	conn.jobQMu.Lock()
	conn.jobQ[args.PrioClock] = stack
	conn.jobQMu.Unlock()

	if args.PrioClock > 0 {
		// Waiting for the completion of its previous RPC
		<-conn.jobQ[args.PrioClock-1]
	}

	err := conn.txClient.Call(serviceMethod, args, &reply)

	if err != nil {
		log.Errorf("RPC call error: %v", err)
		return
	}

	rinfo := ReplyInfo{
		SID:    conn.serverID,
		PClock: args.PrioClock,
		Recv:   reply,
	}
	receiver <- rinfo

	conn.jobQMu.Lock()
	conn.jobQ[args.PrioClock] <- struct{}{}
	conn.jobQMu.Unlock()

	log.Debugf("RPC %s succeeded | result: %+v", serviceMethod, rinfo)
}

// Helper to get object type name for logging
func getObjectTypeName(objType int) string {
	switch objType {
	case HotObject:
		return "HOT"
	case IndependentObject:
		return "INDEP"
	case CommonObject:
		return "COMMON"
	default:
		return "UNKNOWN"
	}
}