package main

import (
	"cabinet/mongodb"
	"errors"
	"fmt"
	"os/exec"
	"sync"
	"sync/atomic"
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
    // IsRead marks this request as a quorum-confirmed read instead of a
    // write: the leader skips UpdateObjectCommit and instead answers with
    // its own locally stored ObjectState.Value once the same priority
    // quorum used for writes (ReadIndex-style) confirms it. CmdPlain/CmdMongo
    // are left empty for reads -- there is nothing to commit.
    IsRead bool
 }

// ClientReply represents reply to client
type ClientReply struct {
	LeaderClock int
	Success     bool
	ErrorMsg    string
	ExeResult   string
	// ReadValues holds the leader's locally stored value for each ObjID in
	// the read batch (same order as the request's ObjIDs); nil entries mean
	// that object has never been written. Unused for writes.
	ReadValues []interface{}
}

// Per-request wrapper so each client RPC gets its own response channel
type ClientRequest struct {
	Args      *ClientArgs
	Resp      chan *ClientReply
	StartTime time.Time // Track when request entered the system for full latency measurement
}

// Queue for incoming client requests; each request carries its own response channel
var clientRequestQueue = make(chan *ClientRequest, 10000)

// Graceful shutdown coordination (added for proper shutdown handling)
var shutdownOnce sync.Once
var shutdownSignal = make(chan struct{}) // Closed when shutdown initiated
var shutdownComplete = make(chan struct{}) // Closed when shutdown complete
var shutdownInProgress atomic.Bool

// followerStop is a best-effort stop signal for follower loops.
// It is closed when shutdown is requested on a follower.
var followerStop = make(chan struct{})

func NewCabService() *CabService {
	return &CabService{}
}

type ReplyInfo struct {
	SID       int
	PClock    int
	Recv      Reply
	Timestamp time.Time // Timestamp when reply was received (Bug #1: ordering fix)
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
	if shutdownInProgress.Load() {
		reply.Success = false
		reply.ErrorMsg = "server shutting down"
		return nil
	}

	// Only leader should handle client requests
	if myServerID != 0 {
		reply.Success = false
		reply.ErrorMsg = "only leader can handle client requests"
		return errors.New(reply.ErrorMsg)
	}

	// Capture arrival for full end-to-end server-side latency (queue + consensus + response).
	requestStartTime := time.Now()
	enqueueStartTime := time.Now()

	batchSize := len(args.CmdPlain)
	if args.Type == MongoDB {
		batchSize = len(args.CmdMongo)
	}

	log.Infof("[LATENCY] Leader received client request | ClientID: %d | ClientClock: %d | ObjID: %s | ObjType: %d | BatchSize: %d | RequestArrivalTime: %v",
		args.ClientID, args.ClientClock, args.ObjID, args.ObjType, batchSize, requestStartTime.UnixMilli())

	respCh := make(chan *ClientReply, 1)
	clientRequestQueue <- &ClientRequest{Args: args, Resp: respCh, StartTime: requestStartTime}

	enqueueDelay := time.Since(enqueueStartTime)
	log.Debugf("[LATENCY-BREAKDOWN] ClientClock %d | EnqueueDelay: %v ms", args.ClientClock, enqueueDelay.Milliseconds())

	// Wait for consensus result on our private channel (includes queue wait + consensus)
	consensusSendTime := time.Now()
	result := <-respCh
	consensusResponseTime := time.Since(consensusSendTime)

	// Calculate full consensus latency (including queue wait + consensus + commit)
	fullLatency := time.Since(requestStartTime)
	responsePreparationTime := time.Since(consensusSendTime)
	
	reply.LeaderClock = result.LeaderClock
	reply.Success = result.Success
	reply.ExeResult = result.ExeResult
	reply.ErrorMsg = result.ErrorMsg
	
	log.Infof("[LATENCY-BREAKDOWN] ClientClock %d | LeaderClock: %d | EnqueueBlock: %v ms | ConsensusTotal: %v ms | ResponsePrep: %v ms | TotalServerSide: %v ms",
		args.ClientClock, result.LeaderClock, enqueueDelay.Milliseconds(), consensusResponseTime.Milliseconds(), 
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
	case MongoConfirm:
		return conJobMongoConfirm(args, reply)
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
	if args.PrioVal > 0 {
		slowCount, conflictCount := 0, 0
		if args.IsMixed && len(args.ObjTypes) == batchSize {
			for i := 0; i < batchSize; i++ {
				switch args.ObjTypes[i] {
				case DependentObject:
					conflictCount++
				default: // IndependentObject
					slowCount++
				}
			}
		} else {
			switch args.ObjType {
			case DependentObject:
				conflictCount = batchSize
			default: // IndependentObject
				slowCount = batchSize
			}
		}

	path := buildMixedPath(slowCount, conflictCount)
		// Record per-operation metrics on follower: conflicts for dependent, slow path for independent
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
				case DependentObject:
					conflictCount++
				default: // IndependentObject
					slowCount++
				}
			}
		}

		path := buildMixedPath(slowCount, conflictCount)
		reply.PathUsed = path
		reply.ExeResult = time.Since(start).String()
		reply.Success = true
		reply.Accepted = true
		reply.LeaderClock = args.PrioClock

		// Log the batch composition ratio
		log.Infof("[Leader] Batch processed | size=%d | MIXED(SLOW:%d,CONFLICT:%d)",
			len(args.CmdPlain), slowCount, conflictCount)
		return nil
	}

	// Non-mixed single object batch
	var path string
	switch args.ObjType {
	case DependentObject:
		path = fmt.Sprintf("CONFLICT:%d", batchSize)
	default: // IndependentObject
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

// conJobMongoDB handles the leader's initial MongoDB proposal on a follower.
// It deliberately does NOT write to MongoDB yet - see the MongoConfirm doc
// comment in parameters.go for why. It only acks so its priority counts
// toward the leader's quorum; the actual write happens later, only for a
// round that actually committed, via conJobMongoConfirm.
func conJobMongoDB(args *Args, reply *Reply) (err error) {
	log.Debugf("Server %d acking PClock %d (write deferred to MongoConfirm)", myServerID, args.PrioClock)
	reply.Success = true
	reply.Accepted = true
	reply.LeaderClock = args.PrioClock
	reply.ExeResult = "0s"
	return nil
}

// conJobMongoConfirm handles a MongoConfirm broadcast: the leader's
// best-effort notice that a MongoDB round actually reached quorum, so this
// follower should now physically apply the queries to its own local
// MongoDB. Deliberately not routed through consensus - every recipient
// already voted yes for this exact round during the proposal phase, so
// applying the already-agreed value needs no further agreement. A follower
// that misses this message simply serves stale reads for these keys until
// its next write, never an incorrect commit.
func conJobMongoConfirm(args *Args, reply *Reply) (err error) {
	if mongoDbFollower == nil {
		reply.Success = true
		reply.Accepted = true
		reply.ExeResult = "0s"
		return nil
	}

	start := time.Now()

	_, queryLatency, err := mongoDbFollower.FollowerAPI(args.CmdMongo)
	if err != nil {
		log.Errorf("[MONGO-CONFIRM] server %d failed to apply confirmed batch | err: %v | queryLatency %v", myServerID, err, queryLatency)
		reply.ErrorMsg = err
		return
	}

	reply.Success = true
	reply.Accepted = true
	reply.ExeResult = time.Since(start).String()

	log.Debugf("Server %d applied confirmed MongoDB batch for PClock %d", myServerID, args.PrioClock)

	return
}