package main

import (
	"cabinet/eval"
	"cabinet/mongodb"
	"cabinet/smr"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/sirupsen/logrus"
)

var log = logrus.New()

var mypriority = smr.NewServerPriority(-1, 0)
var mystate = smr.NewServerState()
var pManager smr.PriorityManager

var perfM eval.PerfMeter
var globalClockCounter int64 // Global counter for RPC arrivals

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
	mystate.SetLeaderID(0)

	pManager.Init(numOfServers, quorum, 1, ratioTryStep, enablePriority)

	if role == 0 {
		fileName := fmt.Sprintf("s%d_n%d_f%d_b%d_%s", myServerID, numOfServers, quorum, batchsize, suffix)
		perfM.Init(1, batchsize, fileName)
		log.Infof("Server %d: perfM initialized", myServerID)
	}
}

func main() {
	mypriority.Majority = pManager.GetMajority()
	pscheme := pManager.GetPriorityScheme()

	fmt.Println("information board")
	fmt.Printf("priority scheme: %v\n", pscheme)
	fmt.Printf("majority: %v\n", mypriority.Majority)

	switch role {
	case 0: // SERVER
		runServerRole(pscheme)
	case 1: // CLIENT
		runClientRole()
	default:
		log.Fatalf("Invalid role specified: %d. Must be 0 (server) or 1 (client)", role)
	}
}

// ------------------ SERVER ROLE ------------------
func runServerRole(pscheme []float64) {
	if myServerID == 0 {
		mypriority.PrioVal = pscheme[0]

		// Start RPC server for client connections
		go startLeaderRPCServer()

		establishRPCs()
		log.Infof("establishRPCs() was successful.")

		// Graceful shutdown: save server metrics on SIGINT/SIGTERM
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
		go func() {
			<-stop
			fmt.Printf("Server %d interrupted. Saving metrics...\n", myServerID)
			if err := perfM.SaveToFile(); err != nil {
				log.Errorf("Server %d: failed to save metrics: %v", myServerID, err)
			} else {
				fmt.Printf("Server %d: metrics saved under ./eval/server%d/\n", myServerID, myServerID)
			}
			os.Exit(0)
		}()

		startSyncCabInstanceWithClients()

	} else {
		// Graceful shutdown for followers as well
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
		go func() {
			<-stop
			fmt.Printf("Server %d interrupted. Saving metrics...\n", myServerID)
			if err := perfM.SaveToFile(); err != nil {
				log.Errorf("Server %d: failed to save metrics: %v", myServerID, err)
			} else {
				fmt.Printf("Server %d: metrics saved under ./eval/server%d/\n", myServerID, myServerID)
			}
			os.Exit(0)
		}()

		runFollower()
	}
}

// ------------------ CLIENT ROLE ------------------
func runClientRole() {
	fmt.Printf("Starting in client mode | ClientID: %d | NumOps: %d | BatchMode: %s | BatchComposition: %s\n",
		myServerID, numOps, batchMode, batchComposition)
	RunClient(myServerID, configPath, numOps, batchMode, batchComposition)
}
