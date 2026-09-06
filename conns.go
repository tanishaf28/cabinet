package main

import (
	"cabinet/config"
	"cabinet/mongodb"
	"encoding/gob"
	"fmt"
	"net"
	"net/rpc"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

// conns does not store the operating servers' information
// Specifically, the leader (serverID 0) is not included in conns.m.
// The leader's weight is handled separately via mypriority.GetPrioVal() as the seed for prioSum
// in startSyncCabInstanceWithClients, and its weight is always set to scheme[0] per Algorithm 1.
// This design ensures the leader's weight is properly accounted for in consensus while maintaining
// a clean separation between the leader's own state and the follower connections.
var conns = struct {
	sync.RWMutex
	m map[int]*ServerDock
}{
	m: make(map[int]*ServerDock),
}

type ServerDock struct {
	serverID   int
	addr       string
	txClient   *rpc.Client
	jobQMu     sync.RWMutex
	jobQ       map[prioClock]chan struct{}
	failMu     sync.Mutex
	failCount  int
}

// startLeaderRPCServer starts RPC server for the leader to accept client connections
func startLeaderRPCServer() {
	serverConfig := config.ParseClusterConfig(numOfServers, configPath)
	ipIndex := config.ServerIP
	rpcPortIndex := config.ServerRPCListenerPort

	myAddr := serverConfig[myServerID][ipIndex] + ":" + serverConfig[myServerID][rpcPortIndex]
	log.Infof("Leader starting RPC server on %s for client connections", myAddr)

	// Register the service explicitly under the name "CabService" to avoid
	// any ambiguity about the registered name used by the client calls.
	if err := rpc.RegisterName("CabService", NewCabService()); err != nil {
		log.Fatalf("rpc.RegisterName failed | error: %v", err)
		return
	}

	// Start listening
	listener, err := net.Listen("tcp", myAddr)
	if err != nil {
		log.Fatalf("Leader RPC Listen error: %v", err)
		return
	}

	log.Infof("Leader RPC server listening on %s", myAddr)

	// Use rpc.Accept to serve incoming connections with the default server.
	// This is the canonical accept loop for net/rpc.
	rpc.Accept(listener)
}

func runFollower() {
	serverConfig := config.ParseClusterConfig(numOfServers, configPath)
	ipIndex := config.ServerIP
	rpcPortIndex := config.ServerRPCListenerPort

	// Initialize follower's local priority from the configured scheme.
	pscheme := pManager.GetPriorityScheme()
	if myServerID >= 0 && myServerID < len(pscheme) {
		if err := mypriority.UpdatePriority(0, pscheme[myServerID]); err != nil {
			log.Fatalf("Follower %d: priority init failed: %v", myServerID, err)
			return
		}
	} else {
		log.Warnf("Follower %d: priority scheme missing entry (schemeLen=%d)", myServerID, len(pscheme))
	}

	myAddr := serverConfig[myServerID][ipIndex] + ":" + serverConfig[myServerID][rpcPortIndex]
	log.Debugf("config: serverID %d | addr: %s", myServerID, myAddr)

	switch evalType {
	case PlainMsg:
		// nothing needs to be done
	case MongoDB:
		go mongoDBCleanUp()
		if err := initMongoDB(); err != nil {
			log.Fatalf("Follower %d: MongoDB initialization failed: %v", myServerID, err)
		}
	}

	if err := rpc.RegisterName("CabService", NewCabService()); err != nil {
		log.Fatalf("rpc.RegisterName failed | error: %v", err)
		return
	}

	listener, err := net.Listen("tcp", myAddr)
	if err != nil {
		log.Fatalf("ListenTCP error: %v", err)
		return
	}

	log.Infof("Follower %d: RPC server listening on %s", myServerID, myAddr)

	acceptDone := make(chan struct{})
	go func() {
		defer close(acceptDone)
		rpc.Accept(listener)
	}()

	select {
	case <-followerStop:
		_ = listener.Close()
		<-acceptDone
		return
	case <-acceptDone:
		return
	}
}

// initMongoDB returns an error instead of just logging and returning, as it
// used to: its sole caller (runFollower) discarded the return entirely, so
// a failed connection left mongoDbFollower nil and the follower proceeded
// to register/accept RPCs anyway. Worse than that alone: with no nil check
// here, a nil mongoDbFollower (NewMongoFollower returns nil on a client
// construction failure - see mongodb/mgdb_follower.go) meant the very next
// line, ClearTable -> FollowerAPI, dereferenced a nil receiver and panicked
// the whole follower process.
//
// This matters more here than in a leaderless design: followers are the
// ONLY replicas that ever hold real MongoDB data in Cabinet (the leader
// deliberately never initializes mongoDbFollower - see MongoConfirm's doc
// comment in parameters.go), and conJobMongoConfirm's mongoDbFollower==nil
// guard treats "not initialized" as a legitimate no-op success, which is
// correct for the leader but indistinguishable from a follower whose own
// init silently failed. A follower with a broken init would silently no-op
// every MongoDB write forever, reporting success, with server-side metrics
// looking empty and no clear reason why - same symptom found and fixed in
// woc's initMongoDB.
func initMongoDB() error {
	gob.Register([]mongodb.Query{})

	// Use server ID as DB suffix in all modes to avoid collisions across replicas.
	mongoDbFollower = mongodb.NewMongoFollower(mongoClientNum, int(1), myServerID)

	if mongoDbFollower == nil {
		return fmt.Errorf("mongodb follower initialization failed")
	}

	queriesToLoad, err := mongodb.ReadQueryFromFile(mongodb.DataPath + "workload.dat")
	if err != nil {
		return fmt.Errorf("getting load data failed: %w", err)
	}

	err = mongoDbFollower.ClearTable("usertable")
	if err != nil {
		return fmt.Errorf("clean up table failed: %w", err)
	}

	log.Debugf("loading data to Mongo DB")
	_, _, err = mongoDbFollower.FollowerAPI(queriesToLoad)
	if err != nil {
		return fmt.Errorf("load data failed: %w", err)
	}

	log.Infof("mongo DB initialization done")
	return nil
}

// mongoDBCleanUp cleans up client connections to DB upon ctrl+C
func mongoDBCleanUp() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		log.Debugf("clean up MongoDb follower")
		err := mongoDbFollower.CleanUp()
		if err != nil {
			log.Errorf("clean up MongoDB follower failed | err: %v", err)
			return
		}
		log.Infof("clean up MongoDB follower succeeded")
	}()
}
