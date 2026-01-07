package main

import (
    "cabinet/mongodb"
    "errors"

	"fmt"
	"os/exec"
	"time"
)

type CabService struct{}

// ClientArgs represents client request arguments
 type ClientArgs struct {
    ClientID    int
    ClientClock int
    ObjID       string
    ObjType     int 
    ObjIDs   []string
    ObjTypes []int
    CmdPlain    [][]byte
    CmdMongo    []mongodb.Query
    Type        int
 }

// ClientReply represents reply to client
type ClientReply struct {
	LeaderClock int
	Success     bool
	ErrorMsg    string
	ExeResult   string
}

// Per-request wrapper so each client RPC gets its own response channel
type ClientRequest struct {
	Args      *ClientArgs
	Resp      chan *ClientReply
	StartTime time.Time // Track when request entered the system for full latency measurement
}

// Queue for incoming client requests; each request carries its own response channel
var clientRequestQueue = make(chan *ClientRequest, 100)

func NewCabService() *CabService {
	return &CabService{}
}

type ReplyInfo struct {
	SID    int
	PClock int
	Recv   Reply
}

type Args struct {
	PrioClock int
	PrioVal   float64
	CmdPlain  [][]byte
	CmdMongo  []mongodb.Query
	CmdPy     []string
	Type      int

	// Mixed batching support (optional). When populated, the server can
	// decide per-operation paths (FAST/SLOW/HOT) based on ObjTypes.
	IsMixed  bool
	ObjIDs   []string
	ObjTypes []int
	// For non-mixed batches the leader may also populate these for
	// backward compatibility.
	ObjID   string
	ObjType int
}

type Reply struct {
	// ServerID and PrioClock are filled by leader
	// ServerID  int
	// PrioClock int

	ExeResult string
	ErrorMsg  error

	// Detailed outcome fields used by leader/client metrics
	Accepted    bool
	PathUsed    string
	LeaderClock int
	Success     bool
}

// ClientRequestService handles requests from clients and triggers consensus
func (s *CabService) ClientRequestService(args *ClientArgs, reply *ClientReply) error {
	// Only leader should handle client requests
	if myServerID != 0 {
		reply.Success = false
		reply.ErrorMsg = "only leader can handle client requests"
		return errors.New(reply.ErrorMsg)
	}

	// ❌ REMOVED: RPC-level measurement - Now measured at consensus layer for server-side metrics
	// This avoids double-counting and ensures server metrics aggregate all client requests

	// Start measuring FULL consensus latency from when request enters the system
	requestStartTime := time.Now()
	queueStartTime := time.Now()

	log.Infof("[LATENCY] Leader received client request | ClientID: %d | ClientClock: %d | ObjID: %s | ObjType: %d | BatchSize: %d | RequestArrivalTime: %v",
		args.ClientID, args.ClientClock, args.ObjID, args.ObjType, len(args.CmdPlain), requestStartTime.UnixMilli())

	respCh := make(chan *ClientReply, 1)
	clientRequestQueue <- &ClientRequest{Args: args, Resp: respCh, StartTime: requestStartTime}

	queueWaitTime := time.Since(queueStartTime)
	log.Debugf("[LATENCY-BREAKDOWN] ClientClock %d | QueueWaitTime: %v ms", args.ClientClock, queueWaitTime.Milliseconds())

	// Wait for consensus result on our private channel (includes queue wait + consensus)
	consensusSendTime := time.Now()
	result := <-respCh
	consensusResponseTime := time.Since(consensusSendTime)

	// ❌ REMOVED: RPC-level measurement end - Now handled at consensus layer

	// Calculate full consensus latency (including queue wait + consensus + commit)
	fullLatency := time.Since(requestStartTime)
	responsePreparationTime := time.Since(consensusSendTime)
	
	reply.LeaderClock = result.LeaderClock
	reply.Success = result.Success
	reply.ExeResult = result.ExeResult
	reply.ErrorMsg = result.ErrorMsg
	
	log.Infof("[LATENCY-BREAKDOWN] ClientClock %d | LeaderClock: %d | QueueWait: %v ms | ConsensusTotal: %v ms | ResponsePrep: %v ms | TotalServerSide: %v ms",
		args.ClientClock, result.LeaderClock, queueWaitTime.Milliseconds(), consensusResponseTime.Milliseconds(), 
		responsePreparationTime.Microseconds(), fullLatency.Milliseconds())

	return nil
}

// Update ConsensusService to log batch composition ratios
func (s *CabService) ConsensusService(args *Args, reply *Reply) error {
	// 1. First update priority
	// log.Infof("received args: %v", args)
	err := mypriority.UpdatePriority(args.PrioClock, args.PrioVal)
	if err != nil {
		log.Errorf("update priority failed | err: %v", err)
		reply.ErrorMsg = err
		return err
	}

	// 2. Then do transaction job
	switch args.Type {
	case PlainMsg:
		return conJobPlainMsg(args, reply)
	case MongoDB:
		return conJobMongoDB(args, reply)
	}

	err = errors.New("unidentified job")
	log.Errorf("err: %v | receievd type: %v", err, args.Type)
	return err
}

func conJobPlainMsg(args *Args, reply *Reply) (err error) {
	start := time.Now()

	// Avoid expensive per-message logging when executing large batches.
	batchSize := len(args.CmdPlain)
	if batchSize > 0 {
		log.Debugf("pClock: %v | executing plain-msg batch | batchSize=%d | firstMsgLen=%d bytes",
			args.PrioClock, batchSize, len(args.CmdPlain[0]))
	} else {
		log.Debugf("pClock: %v | executing empty plain-msg batch", args.PrioClock)
	}

	// Determine role
	curServer := myServerID
	isLeader := mystate.GetLeaderID() == curServer

	// Helper to form PathUsed string for mixed batches
	buildMixedPath := func(slowCount, conflictCount int) string {
		if slowCount > 0 && conflictCount > 0 {
			return fmt.Sprintf("MIXED(SLOW:%d,CONFLICT:%d)", slowCount, conflictCount)
		}
		if conflictCount > 0 {
			return fmt.Sprintf("CONFLICT:%d", conflictCount)
		}
		if slowCount > 0 {
			return "SLOW"
		}
		return "FAILED"
	}

	// If follower receiving a slow-path proposal (PrioVal > 0), treat as vote
	if args.PrioVal > 0 && !isLeader {
		slowCount, conflictCount := 0, 0
		if args.IsMixed && len(args.ObjTypes) == batchSize {
			for i := 0; i < batchSize; i++ {
				switch args.ObjTypes[i] {
				case HotObject:
					conflictCount++
				default: // IndependentObject or CommonObject
					slowCount++
				}
			}
		} else {
			switch args.ObjType {
			case HotObject:
				conflictCount = batchSize
			default: // IndependentObject or CommonObject
				slowCount = batchSize
			}
		}

	path := buildMixedPath(slowCount, conflictCount)
		// Record per-operation metrics on follower: conflicts for hot, slow path for indep/common
		if slowCount > 0 {
			perfM.AddSlowCommits(slowCount)
		}
		if conflictCount > 0 {
			perfM.AddConflictCommits(conflictCount)
		}

		reply.PathUsed = path
		reply.LeaderClock = args.PrioClock
		reply.Success = true
		reply.Accepted = true
		reply.ExeResult = time.Since(start).String()
		return nil
	}

	// If this is a mixed batch arriving at server, classify and return
	if args.IsMixed {
		slowCount, conflictCount := 0, 0
		if len(args.ObjTypes) == len(args.CmdPlain) {
			for i := 0; i < len(args.CmdPlain); i++ {
				switch args.ObjTypes[i] {
				case HotObject:
					conflictCount++
				default: // IndependentObject or CommonObject
					slowCount++
				}
			}
		}

		path := buildMixedPath(slowCount, conflictCount)
		reply.PathUsed = path
		reply.ExeResult = time.Since(start).String()
		reply.Success = true
		reply.Accepted = true
		reply.LeaderClock = mystate.GetLeaderID()

		// Log the batch composition ratio
		log.Infof("[Leader] Batch processed | size=%d | MIXED(SLOW:%d,CONFLICT:%d)",
			len(args.CmdPlain), slowCount, conflictCount)
		return nil
	}

	// Non-mixed single object batch
	var path string
	switch args.ObjType {
	case HotObject:
		path = fmt.Sprintf("CONFLICT:%d", batchSize)
	default: // IndependentObject or CommonObject
		path = "SLOW"
	}

	reply.PathUsed = path
	reply.ExeResult = time.Since(start).String()
	reply.Success = true
	reply.Accepted = true
	reply.LeaderClock = mystate.GetLeaderID()
	return nil
}

func conJobPythonScript(args *Args, reply *Reply) (err error) {
	start := time.Now()

	err = exec.Command("python3", args.CmdPy...).Run()

	if err != nil {
		log.Errorf("run cmd failed | err: %v", err)
		reply.ErrorMsg = err
		return
	}

	reply.ExeResult = time.Now().Sub(start).String()
	return
}

func conJobMongoDB(args *Args, reply *Reply) (err error) {

	//if myServerID == 1 || myServerID == 2 {
	//	time.Sleep(2 * time.Second)
	//}

	//gob.Register([]mongodb.Query{})
	log.Debugf("Server %d is executing PClock %d", myServerID, args.PrioClock)

	start := time.Now()

	_, queryLatency, err := mongoDbFollower.FollowerAPI(args.CmdMongo)
	if err != nil {
		log.Errorf("run cmd failed | err: %v | queryLatency %v", err, queryLatency)
		reply.ErrorMsg = err
		return
	}

	reply.ExeResult = time.Since(start).String()

	// //fmt.Println("Average latency of Mongo DB queries: ", queryLatency)
	// for i, queryRes := range queryResults {
	// 	if i >= 2 && i < len(queryResults)-3 {
	// 		continue
	// 	}
	// 	//fmt.Printf("\nResult of the %vth query: \n", i)
	// 	for _, queRes := range queryRes {
	// 		//if uid, ok := queRes["_id"]; ok {
	// 		if _, ok := queRes["_id"]; ok {
	// 			//fmt.Println("_id", "is", uid)
	// 			delete(queRes, "_id")
	// 		}
	// 		//for k, v := range queRes {
	// 		//	fmt.Println(k, "is", v)
	// 		//}
	// 	}
	// }

	log.Debugf("Server %d finished PClock %d", myServerID, args.PrioClock)

	return
}