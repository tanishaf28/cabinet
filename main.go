package main

import (
	"cabinet/eval"
	"cabinet/mongodb"
	"cabinet/smr"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/sirupsen/logrus"
)

var log = logrus.New()

var mypriority = smr.NewServerPriority(0, 0)
var mystate = smr.NewServerState()
var pManager smr.PriorityManager

var perfM eval.PerfMeter
var globalClockCounter int64 // Global counter for RPC arrivals
var serverMetricsSaved atomic.Bool

// Mongo DB variables
var mongoDbFollower *mongodb.MongoFollower

// Create Cabinet alias
type serverID = int
type prioClock = int
type priority = float64

func init() {
	fmt.Println("program starts ...")
	loadCommandLineInputs()
	setLogger(logLevel)

	mystate.SetMyServerID(myServerID)
	// KNOWN LIMITATION: server 0 is a permanently fixed leader -- there is no
	// election protocol anywhere in this codebase (unlike WOC's
	// StartElection/HandleVoteRequest in consensus.go). Clients hard-dial
	// server 0 with no retry/failover (client.go's rpc.Dial + log.Fatalf),
	// and non-leader servers never accept client requests. If server 0
	// crashes, the cluster stops accepting writes permanently until it is
	// manually restarted. Fixing this requires designing and building
	// Raft-style leader election (vote RPCs, term tracking, follower-to-
	// follower connectivity, client-side leader discovery) from scratch --
	// deliberately out of scope for the follower-crash resilience fixes in
	// this file/primary.go/consensus_with_clients.go.
	mystate.SetLeaderID(0)

	pManager.Init(numOfServers, quorum, 1, ratioTryStep, enablePriority)

	if role == 0 {
		fileName := fmt.Sprintf("s%d_n%d_f%d_b%d_%s", myServerID, numOfServers, quorum, batchsize, suffix)
		perfM.Init(1, batchsize, fileName)
		log.Infof("Server %d: perfM initialized", myServerID)
	}
}

func main() {
	mypriority.SetMajority(pManager.GetMajority())
	pscheme := pManager.GetPriorityScheme()

	fmt.Println("information board")
	fmt.Printf("priority scheme: %v\n", pscheme)
	fmt.Printf("majority: %v\n", mypriority.GetMajority())

	switch role {
	case 0: // SERVER
		runServerRole(pscheme)
	case 1: // CLIENT
		runClientRole()
	default:
		log.Fatalf("Invalid role specified: %d. Must be 0 (server) or 1 (client)", role)
	}
}

// warmObjectPool initializes the fixed numObjects pool (see objectmap.go) and
// pre-creates each object's state entry so first-touch map allocation doesn't
// land inside the timed run. Unlike the old preloadCabinetObjects, the pool
// is a fixed, deterministic size (-numobjects/-indep), not derived from
// per-run heuristics (numOps, client ranges, etc).
func warmObjectPool() {
	start := time.Now()

	InitObjectRegistry()
	for i := 0; i < numObjects; i++ {
		meta := ObjectByIndex(i)
		mystate.AddObject(meta.ID, meta.Type, numOfServers)
	}

	log.Infof("Object pool ready: %d objects (indep=%.1f%%) in %v", numObjects, indepRatio, time.Since(start))
}

// ------------------ SERVER ROLE ------------------
func runServerRole(pscheme []float64) {
	saveServerMetricsOnce := func(reason string) {
		if !serverMetricsSaved.CompareAndSwap(false, true) {
			return
		}
		fmt.Printf("Server %d %s. Saving metrics...\n", myServerID, reason)
		if err := perfM.SaveToFile(); err != nil {
			log.Errorf("Server %d: failed to save metrics: %v", myServerID, err)
		} else {
			fmt.Printf("Server %d: metrics saved under ./eval/server%d/\n", myServerID, myServerID)
		}
	}

	if myServerID == 0 {
		if len(pscheme) > 0 {
			if err := mypriority.UpdatePriority(0, pscheme[0]); err != nil {
				log.Fatalf("failed to initialize leader priority: %v", err)
			}
		}

		// Start RPC server for client connections
		go startLeaderRPCServer()

		establishRPCs()
		log.Infof("establishRPCs() was successful.")

		warmObjectPool()

		// Graceful shutdown: coordinate with consensus loop
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
		go func() {
			sig := <-stop
			fmt.Printf("Server %d received signal (%v). Initiating graceful shutdown...\n", myServerID, sig)
			shutdownInProgress.Store(true)
			shutdownOnce.Do(func() { close(shutdownSignal) })
		}()

		startSyncCabInstanceWithClients()
		// Consensus loop returned: flush metrics and exit main.
		saveServerMetricsOnce("shutdown")

	} else {
		// Graceful shutdown for followers as well
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
		go func() {
			sig := <-stop
			fmt.Printf("Server %d received signal (%v). Shutting down...\n", myServerID, sig)
			shutdownInProgress.Store(true)
			shutdownOnce.Do(func() { close(followerStop) })
		}()

		runFollower()
		saveServerMetricsOnce("shutdown")
	}
}

// ------------------ CLIENT ROLE ------------------
func runClientRole() {
	fmt.Printf("Starting in client mode | ClientID: %d | NumOps: %d | BatchMode: %s | BatchComposition: %s\n",
		myServerID, numOps, batchMode, batchComposition)
	RunClient(myServerID, configPath, numOps, batchMode, batchComposition)
}
