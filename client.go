package main

import (
	"cabinet/config"
	"cabinet/eval"
	"cabinet/mongodb"
	"fmt"
	"math/rand"
	"net/rpc"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func RunClient(myServerID int, configPath string, numOps int, batchMode string, batchComposition string) {
	log.Infof("Client %d: SEQUENTIAL mode enabled (ordered batches)", myServerID)
	
	// --- 1. Parse cluster configuration ---
	clusterConf := config.ParseClusterConfig(numOfServers, configPath)
	cluster := make(map[int]string)
	for sid, info := range clusterConf {
		cluster[sid] = info[config.ServerIP] + ":" + info[config.ServerRPCListenerPort]
	}

	leaderID := 0
	leaderAddr := cluster[leaderID]
	conn, err := rpc.Dial("tcp", leaderAddr)
	if err != nil {
		log.Fatalf("Client %d: failed to connect to leader at %s: %v", myServerID, leaderAddr, err)
	}
	defer conn.Close()
	log.Infof("Client %d: connected to leader at %s", myServerID, leaderAddr)

	// --- 3. Graceful shutdown ---
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	// --- 4. Initialize logical clock and performance meter ---
	var clientClock int
	var clockLock sync.Mutex
	incrementClock := func() int {
		clockLock.Lock()
		defer clockLock.Unlock()
		clientClock++
		return clientClock
	}

	fileSuffix := fmt.Sprintf("client%d_eval", myServerID)
	clientPerfM := eval.PerfMeter{}
	clientPerfM.Init(1, batchsize, fileSuffix)

	// Atomic flag to prevent duplicate metric saves
	var metricsSaved atomic.Bool

	// Background goroutine to save metrics on interrupt
	go func() {
		<-stop
		if !metricsSaved.Load() {
			fmt.Printf("Client %d interrupted. Saving metrics...\n", myServerID)
			if err := clientPerfM.SaveToFile(); err != nil {
				log.Errorf("Client %d: failed to save metrics: %v", myServerID, err)
			} else {
				fmt.Printf("Client %d: ✓ Client metrics saved to ./eval/client%d_eval.csv\n", myServerID, myServerID)
			}
			metricsSaved.Store(true)
		}
		os.Exit(0)
	}()

	rand.Seed(time.Now().UnixNano() + int64(myServerID))

	opsLabel := fmt.Sprintf("%d", numOps)
	if numOps <= 0 {
		opsLabel = "infinite"
	}

	fmt.Printf("Client %d started | Total Ops: %s | Batch Mode: %s | Batch Size: %d | Eval Type: %s\n",
		myServerID, opsLabel, batchMode, batchsize, evalTypeName(evalType))

	if evalType != PlainMsg && evalType != MongoDB {
		log.Fatalf("Client %d: unsupported eval type %d (only PlainMsg=0 and MongoDB=2 supported)", myServerID, evalType)
	}

	// Validate object ratios
	totalRatio := hotObjRatio + indepObjRatio + commonObjRatio
	if totalRatio != 100 {
		log.Fatalf("Client %d: Object ratios must sum to 100%% (hot=%d%% + indep=%d%% + common=%d%% = %d%%)",
			myServerID, hotObjRatio, indepObjRatio, commonObjRatio, totalRatio)
	}

	if batchComposition == "mixed" {
		log.Infof("Client %d: MIXED batch mode - each batch contains diverse objects and types", myServerID)
	} else {
		log.Infof("Client %d: OBJECT-SPECIFIC batch mode - each batch targets one object type (different IDs allowed)", myServerID)
	}
	
	fmt.Printf("  Object Distribution: Hot=%d%% | Independent=%d%% | Common=%d%%\n",
		hotObjRatio, indepObjRatio, commonObjRatio)

	// --- 5. Preload MongoDB queries if needed ---
	var mongoDBQueries []mongodb.Query
	if evalType == MongoDB {
		filePath := fmt.Sprintf("%srun_workload%s.dat", mongodb.DataPath, mongoLoadType)
		var err error
		mongoDBQueries, err = mongodb.ReadQueryFromFile(filePath)
		if err != nil {
			log.Errorf("ReadQueryFromFile failed | err: %v", err)
			return
		}
		log.Infof("Client %d: loaded %d MongoDB queries", myServerID, len(mongoDBQueries))
	}

	// --- 6. Job queue for controlled concurrency ---
	jobQ := make(map[int]chan struct{})

	op := 0
	conflictCounter := 0 // Counts committed hot objects

	// --- 7. Main operation loop ---
	// Run indefinitely if numOps <= 0, otherwise run for numOps operations
	infinite := numOps <= 0
	for infinite || op < numOps {
		select {
		case <-stop:
			// Save metrics if not already saved by background goroutine
			if !metricsSaved.Load() {
				fmt.Printf("Client %d interrupted during loop. Saving metrics...\n", myServerID)
				if err := clientPerfM.SaveToFile(); err != nil {
					log.Errorf("Client %d: failed to save metrics: %v", myServerID, err)
				} else {
					fmt.Printf("Client %d: ✓ Client metrics saved to ./eval/client%d_eval.csv\n", myServerID, myServerID)
				}
				metricsSaved.Store(true)
			}
			return
		default:
			// Decide batch size
			currentBatch := batchsize
			if !infinite && op+batchsize > numOps {
				currentBatch = numOps - op
			}

			// Send batch of operations
						sendBatchToLeader(myServerID, &op, currentBatch, conn, incrementClock,
							mongoDBQueries, jobQ, &clientPerfM, batchComposition, &conflictCounter)
		}
	}

	// No pipelined batches to wait for in sequential mode

	// --- 8. Close connection and save metrics ---
	conn.Close()

	// CRITICAL FIX: Save client metrics at end if not already saved
	if !metricsSaved.Load() {
		if err := clientPerfM.SaveToFile(); err != nil {
			log.Errorf("Client %d: failed to save metrics: %v", myServerID, err)
		} else {
			fmt.Printf("Client %d: ✓ Client metrics saved to ./eval/client%d_eval.csv\n", myServerID, myServerID)
		}
		metricsSaved.Store(true)
	}

	if numOps <= 0 {
		fmt.Printf("Client %d stopped after %d ops (infinite mode).\n", myServerID, op)
	} else {
		fmt.Printf("Client %d finished all %d ops.\n", myServerID, numOps)
	}
}

// sendBatchToLeader sends a batch of operations to the leader
func sendBatchToLeader(myServerID int, op *int, currentBatch int,
conn *rpc.Client, incrementClock func() int,
mongoDBQueries []mongodb.Query, jobQ map[int]chan struct{},
perfM *eval.PerfMeter, batchComposition string, conflictCounterPtr *int) {

    // Sanity check
    if currentBatch <= 0 {
        return
    }

    // Build per-op ObjIDs and ObjTypes (mixed-like batches).
    objIDs := make([]string, currentBatch)
    objTypes := make([]int, currentBatch)

    if batchComposition == "mixed" {
		// Generate mixed object types and IDs
		for b := 0; b < currentBatch; b++ {
			randVal := rand.Float64() * 100.0
			switch {
			case randVal < float64(hotObjRatio):
				objTypes[b] = HotObject
				hotID := (*op + b) % 10
				objIDs[b] = fmt.Sprintf("obj-HOT-%d", hotID)
			case randVal < float64(hotObjRatio+indepObjRatio):
				objTypes[b] = IndependentObject
				objIDs[b] = fmt.Sprintf("obj-indep-c%d-%d", myServerID, *op+b)
			default:
				objTypes[b] = CommonObject
				commonObjID := (*op + b) / 10
				objIDs[b] = fmt.Sprintf("obj-common-%d", commonObjID)
			}
		}
	} else {
		// OBJECT-SPECIFIC: All ops in batch target the same object type, but can have different object IDs
		var objType int
		randVal := rand.Float64() * 100.0
		if randVal < float64(hotObjRatio) {
			objType = HotObject
		} else if randVal < float64(hotObjRatio+indepObjRatio) {
			objType = IndependentObject
		} else {
			objType = CommonObject
		}

		// Generate different object IDs within the same type for each operation in the batch
		for b := 0; b < currentBatch; b++ {
			objTypes[b] = objType
			switch objType {
			case HotObject:
				objIDs[b] = fmt.Sprintf("obj-HOT-%d", (*op+b)%10)
			case IndependentObject:
				objIDs[b] = fmt.Sprintf("obj-indep-c%d-%d", myServerID, *op+b)
			case CommonObject:
				objIDs[b] = fmt.Sprintf("obj-common-%d", (*op+b)/10)
			}
		}
	}

    // Increment client logical clock
    CClock := incrementClock()

    // Build the client command, include per-op metadata (ObjIDs/ObjTypes).
    // Keep ObjID/ObjType populated with the first element for compatibility.
    cmd := &ClientArgs{
        ClientID:    myServerID,
        ClientClock: CClock,
        ObjID:       objIDs[0],
        ObjType:     objTypes[0],
        ObjIDs:      objIDs,
        ObjTypes:    objTypes,
        Type:        evalType,
    }

    // Fill the batch payload
    switch evalType {
    case PlainMsg:
        batch := make([][]byte, currentBatch)
        for b := 0; b < currentBatch; b++ {
            batch[b] = genRandomBytes(msgsize)
        }
        cmd.CmdPlain = batch

    case MongoDB:
        // Guard against empty mongoDBQueries to avoid panic
        if len(mongoDBQueries) == 0 {
            log.Warnf("Client %d: no MongoDB queries loaded; skipping batch", myServerID)
            return
        }
        batch := make([]mongodb.Query, currentBatch)
        for b := 0; b < currentBatch; b++ {
            batch[b] = mongoDBQueries[(*op+b)%len(mongoDBQueries)]
        }
        cmd.CmdMongo = batch
    }

	// SEQUENTIAL: wait for previous batch (per original behavior)
	stack := make(chan struct{}, 1)
	jobQ[cmd.ClientClock] = stack
	sequentialWaitStart := time.Now()
	if prev, ok := jobQ[cmd.ClientClock-1]; ok && cmd.ClientClock > 1 {
		<-prev
		// Cleanup to avoid unbounded growth in long-running/infinite runs
		delete(jobQ, cmd.ClientClock-1)
	}
	sequentialWaitTime := time.Since(sequentialWaitStart)

	reply := &ClientReply{}
	log.Debugf("[LATENCY-BREAKDOWN] Client %d | Batch %d | Starting RPC call | SequentialWait: %v ms", 
		myServerID, cmd.ClientClock, sequentialWaitTime.Milliseconds())
	
	
	perfM.RecordStarter(cmd.ClientClock)
	rpcStartTime := time.Now()
	
	err := conn.Call("CabService.ClientRequestService", cmd, reply)
	
	rpcLatency := time.Since(rpcStartTime)

	if err != nil {
		if errRec := perfM.RecordFinisher(cmd.ClientClock); errRec != nil {
			// ignore
		}
		log.Warnf("[Client %d] Batch %d failed: %v | RPC time: %v ms", myServerID, cmd.ClientClock, err, rpcLatency.Milliseconds())
	} else {
		perfM.RecordFinisher(cmd.ClientClock)
		log.Debugf("[LATENCY-BREAKDOWN] Client %d | Batch %d | RPC completed | NetworkRoundTrip: %v ms", 
			myServerID, cmd.ClientClock, rpcLatency.Milliseconds())
	}
	
	// Signal next batch only AFTER measurement is complete
	stack <- struct{}{}

    // Advance the operation counter
    *op += currentBatch

	slowCount, conflictCount := 0, 0
	for _, objType := range objTypes {
		switch objType {
		case HotObject:
			conflictCount++
		default: // IndependentObject or CommonObject
			slowCount++
		}
	}

	// Record per-operation path metrics: conflicts for hot, slow path for indep/common
	if err == nil {
		if reply.Success {
			// Cabinet only has slow path - indep and common objects use slow path
			for i := 0; i < slowCount; i++ {
				perfM.IncSlowPath(CClock)
			}
			// Hot objects are conflicts (resolved via slow path)
			for i := 0; i < conflictCount; i++ {
				perfM.IncConflict(CClock)
			}
			
			// Update global commit counters
			if slowCount > 0 {
				perfM.AddSlowCommits(slowCount)
			}
			if conflictCount > 0 {
				perfM.AddConflictCommits(conflictCount)
			}
		}
	}

	// Increment conflict counter for hot object commits
	if conflictCount > 0 {
		if conflictCounterPtr != nil {
			*conflictCounterPtr += conflictCount
		}
	}

	// Log batch composition and conflict count with full latency breakdown
	conflicts := 0
	if conflictCounterPtr != nil {
		conflicts = *conflictCounterPtr
	}
	
	// Format path based on batch composition
	var pathStr string
	if batchComposition == "mixed" {
		// Mixed mode: show breakdown of different types
		pathStr = fmt.Sprintf("MIXED(SLOW:%d,CONFLICT:%d)", slowCount, conflictCount)
	} else {
		// Object-specific mode: all operations are same type
		if conflictCount > 0 && slowCount == 0 {
			pathStr = fmt.Sprintf("HOT:%d", conflictCount)
		} else if slowCount > 0 && conflictCount == 0 {
			pathStr = fmt.Sprintf("SLOW:%d", slowCount)
		} else if conflictCount > 0 && slowCount > 0 {
			// Shouldn't happen in object-specific, but log it for debugging
			pathStr = fmt.Sprintf("MIXED(SLOW:%d,CONFLICT:%d)", slowCount, conflictCount)
		} else {
			pathStr = "UNKNOWN"
		}
	}
	
	log.Infof("[LATENCY-BREAKDOWN] Client %d | Batch %d | size=%d | LeaderClock=%d | %s | SequentialWait=%dms | NetworkRoundTrip=%dms | Conflicts=%d",
		myServerID, *op, currentBatch, reply.LeaderClock, pathStr,
		sequentialWaitTime.Milliseconds(), rpcLatency.Milliseconds(),conflicts)
}

// Helper to print eval type
func evalTypeName(et int) string {
	switch et {
	case PlainMsg:
		return "Plain Message"
	case MongoDB:
		return "MongoDB (YCSB)"
	default:
		return "Unknown"
	}
}

// Helper to print object type
func getObjTypeName(ot int) string {
	switch ot {
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