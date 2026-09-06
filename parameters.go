package main

import (
	"flag"
)

const (
	Localhost = iota
	Distributed
)

const (
	PlainMsg = iota
	MongoDB
	// MongoConfirm marks a best-effort, fire-and-forget broadcast the
	// leader sends to followers AFTER a MongoDB round actually reaches
	// quorum. Followers never write to their local MongoDB on the initial
	// MongoDB proposal (see conJobMongoDB) - unlike PlainMsg, where a
	// follower's vote never touches any value at all (only the leader's
	// mystate.UpdateObjectCommit, gated behind the quorum check, is
	// authoritative), MongoDB writes are a real external side effect with
	// no cheap undo, and followers are the only replicas holding the actual
	// MongoDB data (the leader never initializes mongoDbFollower - see
	// conns.go). Applying before the leader's quorum decision is known has
	// no correctness story if the round times out, since Cabinet has no
	// FallBack/revert mechanism. MongoConfirm is the "now write it for
	// real" signal (see conJobMongoConfirm).
	MongoConfirm
)

// Object types for workload characterization
const (
	IndependentObject = iota
	DependentObject
)

var numOfServers int
var threshold int
var quorum int
var myServerID int
var configPath string
var production bool
var logLevel string
var mode int
var evalType int

var batchsize int
var msgsize int

// Server-side batching: the leader accumulates commands arriving from
// multiple concurrent clients for up to batchWindowUs microseconds (or until
// maxBatch requests have queued, whichever comes first) and commits them
// together in one consensus round, instead of one round per client RPC. This
// is independent of batchsize (client-side pre-packing). batchWindowUs=0 or
// maxBatch=1 disables server-side batching entirely (today's behavior).
var batchWindowUs int
var maxBatch int

var ratioTryStep float64
var enablePriority bool

// Mongo DB input parameters
var mongoLoadType string
var mongoClientNum int

// crash test parameters
var crashTime int
var crashMode int
var crashTarget int // replica ID to kill alone when crashMode == 4

// suffix of files
var suffix string

// role-based parameters
var role int
var numOps int
var batchMode string
var maxInflight int

// object distribution parameters
var indepRatio float64 // % of independent objects; drives the object registry split (see objectmap.go)
var numObjects int     // total size of the fixed object pool independent/dependent types are drawn from

// readRatio is the % of client ops that are reads (0 = all writes). Cabinet
// only ever answers reads via the same priority-quorum confirmation writes
// use (see consensus_with_clients.go's handleRead) -- there is no fast/local
// read mode here, unlike woc, because followers never hold a committed
// object value to answer from (only the leader calls UpdateObjectCommit).
var readRatio float64

// Add batchComposition as a configurable parameter
var (
	batchComposition string // Defines the batch composition mode: "mixed" or "object-specific"
)

func loadCommandLineInputs() {
	flag.IntVar(&numOfServers, "n", 5, "# of servers")

	flag.IntVar(&threshold, "t", 1, "# of quorum tolerated")
	flag.IntVar(&batchsize, "b", 1, "batch size")
	flag.IntVar(&batchWindowUs, "batchwindowus", 0, "server-side batch accumulation window in microseconds (0 = disabled)")
	flag.IntVar(&maxBatch, "maxbatch", 1, "max requests merged into one consensus round (1 = disabled)")
	flag.IntVar(&myServerID, "id", 0, "this server ID")
	flag.StringVar(&configPath, "path", "./config/cluster_localhost.conf", "config file path")

	// Production mode stores log on disk at ./logs/
	flag.BoolVar(&production, "pd", false, "production mode?")
	flag.StringVar(&logLevel, "log", "debug", "trace, debug, info, warn, error, fatal, panic")
	flag.IntVar(&mode, "mode", 0, "0 -> localhost; 1 -> distributed")
	flag.IntVar(&evalType, "et", 0, "0 -> plain msg; 1 -> tpcc; 2 -> mongodb")

	flag.Float64Var(&ratioTryStep, "rstep", 0.001, "rate for trying qualified ratio")

	flag.BoolVar(&enablePriority, "ep", true, "true -> cabinet; false -> raft")

	// Plain message input parameters
	flag.IntVar(&msgsize, "ms", 512, "message size")

	// MongoDB input parameters
	flag.StringVar(&mongoLoadType, "mload", "a", "mongodb load type")
	flag.IntVar(&mongoClientNum, "mcli", 16, "# of mongodb clients")

	// crash test parameters
	flag.IntVar(&crashTime, "ct", 20, "# of rounds before crash")
	flag.IntVar(&crashMode, "cm", 0, "0 -> no crash; 1 -> strong machines; 2 -> weak machines; 3 -> random machines; 4 -> single explicit replica (see -crashtarget)")
	flag.IntVar(&crashTarget, "crashtarget", -1, "replica ID to kill alone when -cm=4")

	// suffix of files
	flag.StringVar(&suffix, "suffix", "cab", "suffix of files")

	// role-based parameters
	flag.IntVar(&role, "role", 0, "0 -> server; 1 -> client")
	flag.IntVar(&numOps, "ops", 100, "number of operations to send (0 for infinite)")
	flag.StringVar(&batchMode, "bmode", "single", "batch mode: single or round-robin")
	flag.IntVar(&maxInflight, "max-inflight", 1, "maximum concurrent in-flight client batches")

	// object distribution parameters
	flag.Float64Var(&indepRatio, "indep", 90, "percentage of independent objects")
	flag.IntVar(&numObjects, "numobjects", 1000, "size of the fixed object pool independent/dependent types are drawn from")

	// read parameters
	flag.Float64Var(&readRatio, "readratio", 0, "percentage of operations that are reads (0 = all writes); reads are always quorum-confirmed, there is no fast mode")

	// batch composition parameter
	flag.StringVar(&batchComposition, "bcomp", "object-specific", "batch composition mode: mixed or object-specific")

	flag.Parse()
	// Must run after flag.Parse(): quorum = threshold + 1 needs -t's actual
	// command-line value, not the value threshold happened to hold (its
	// just-registered default) at the point this file's flag.IntVar calls
	// run. Every current script hardcodes -t=1 (matching the old default),
	// which is why this was silently masked rather than visibly broken.
	quorum = threshold + 1
	if maxInflight < 1 {
		maxInflight = 1
	}
	if maxBatch < 1 {
		maxBatch = 1
	}
	if batchWindowUs < 0 {
		batchWindowUs = 0
	}
	log.Debugf("CommandLine parameters:\n - numOfServers:%v\n - myServerID:%v\n", numOfServers, myServerID)
}

