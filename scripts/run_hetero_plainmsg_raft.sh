#!/bin/bash
# ================================================================
# HETEROGENEOUS PLAIN-MSG EVALUATION RUNNER (RAFT)
# Runs the heterogeneous Cabinet cluster across cluster sizes
# n = 3, 5, 7, 11 (config/cluster_hetero_<n>n_*.conf) and the core
# workload sweeps:
#   eval1  Independent/Dependent ratio sweep
#   eval2  Batch size sweep
#   eval3  Message size sweep
#   eval4  Read ratio sweep (-readratio, quorum-confirmed reads only)
#
# THRESHOLD (-t, quorum fault-tolerance) scales with cluster size as
# floor((n-1)/2): 1/2/3/5 for n=3/5/7/11.
#
# Max-inflight, crash/fault-injection, and network-delay sweeps live
# in their own dedicated scripts now (run_hetero_maxinflight_raft.sh,
# run_hetero_crash_raft.sh, run_hetero_netem_raft.sh) — mirroring woc's
# split between run_plainmsg_evals.sh and its dedicated
# run_hetero5_crash_eval.sh / run_hetero_maxinflight_eval.sh.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"

RESULT_ROOT="${REPO_ROOT}/results/hetero_plainmsg"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

CLUSTER_ACTIVE=false

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
EVAL_ONLY="${1:-all}"

# Client scaling mode (same semantics as WOC/EPaxos run scripts):
#   SCALE_CLIENTS=false (default) — FIXED_CLIENT_COUNT clients (fixed load, isolates quorum overhead)
#   SCALE_CLIENTS=true  — clients = min(N,10) (all N clients pile on leader, shows bottleneck)
SCALE_CLIENTS="${SCALE_CLIENTS:-false}"
FIXED_CLIENT_COUNT="${FIXED_CLIENT_COUNT:-2}"

SERVER_COUNTS=(3 5 7 11)
if [ -n "${CLUSTER_SIZES:-}" ]; then
    read -r -a SERVER_COUNTS <<< "$CLUSTER_SIZES"
fi

BASE_ENV=()

mkdir -p "$RUN_DIR"

# ================================================================
# HELPERS
# ================================================================

start_cluster() {
    CLUSTER_ACTIVE=true
    env "${BASE_ENV[@]}" bash "$START_SCRIPT"
}

stop_cluster() {
    env "${BASE_ENV[@]}" bash "$STOP_SCRIPT"
    CLUSTER_ACTIVE=false
}

archive_results() {
    local label=$1
    local dest_dir="${RUN_DIR}/${label}"
    mkdir -p "$dest_dir"

    local merged_dir="${EVAL_DIR}/merged"
    if [ -d "$merged_dir" ]; then
        cp "$merged_dir"/*.csv "$dest_dir/" 2>/dev/null || true
    fi
    # Also grab raw client dirs in case merge failed
    cp -r "${EVAL_DIR}"/client* "$dest_dir/" 2>/dev/null || true

    echo "  Archived results to: $dest_dir"
}

run_case() {
    local label=$1
    local runtime=$2

    echo ""
    echo "=================================================="
    echo "Running: $label  [${runtime}s]"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    start_cluster
    sleep "$runtime"
    stop_cluster
    archive_results "$label"
}

# ================================================================
# CLEANUP TRAP
# ================================================================
cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

# ================================================================
# ARGUMENT PARSING
# ================================================================
if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_hetero_plainmsg_raft.sh [selector]

Selectors (default: all):
  eval1   Independent/Dependent ratio sweep
  eval2   Batch size sweep (1 10 50 100 500 1000 2000)
  eval3   Message size sweep (64 512 1024 2048 4096)
  eval4   Read ratio sweep (-readratio 0,25,50,75,100, quorum reads only)

Each eval runs across cluster sizes n = 3, 5, 7, 11 (heterogeneous,
config/cluster_hetero_<n>n_*.conf). THRESHOLD scales as floor((n-1)/2).

Environment overrides:
  RUNTIME_SECONDS=30
  CLUSTER_SIZES="3 5 7 11"    override the cluster-size sweep (e.g. "5")
  SCALE_CLIENTS=false|true    fixed FIXED_CLIENT_COUNT clients vs min(N,10) pinned clients
  FIXED_CLIENT_COUNT=2        client count when SCALE_CLIENTS=false

Other sweeps now live in dedicated scripts:
  run_hetero_maxinflight_raft.sh   client max-inflight sweep
  run_hetero_crash_raft.sh         fault injection (leader/follower/f-of-n)
  run_hetero_netem_raft.sh         network delay (D1 uniform + D4 burst)

Results: results/hetero_plainmsg/<timestamp>/n<N>/<label>/
EOF
    exit 0
fi

[[ "$EVAL_ONLY" == --* ]] && EVAL_ONLY="${EVAL_ONLY#--}"

case "$EVAL_ONLY" in
    all|eval1|eval2|eval3|eval4) ;;
    *)
        echo "ERROR: unknown selector '${EVAL_ONLY}'. Run with --help."
        exit 1 ;;
esac

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║      HETEROGENEOUS PLAIN-MSG EVALUATION RUNNER (Raft)         ║"
echo "║         Cluster sizes: n = 3, 5, 7, 11 + 2 clients            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Result archive: $RUN_DIR"
echo ""

for NUM_SERVERS in "${SERVER_COUNTS[@]}"; do
    THRESHOLD=$(( (NUM_SERVERS - 1) / 2 ))
    if [ "${SCALE_CLIENTS}" = "true" ]; then
        NUM_CLIENTS_FOR_RUN=$(( NUM_SERVERS < 10 ? NUM_SERVERS : 10 ))
    else
        NUM_CLIENTS_FOR_RUN=${FIXED_CLIENT_COUNT}
    fi

    echo ""
    echo "════════════════ Cluster size n=${NUM_SERVERS} (t=${THRESHOLD}) ════════════════"

    # ============================================================
    # EVAL 1: Independent/Dependent ratio sweep
    # ============================================================
    if [[ "$EVAL_ONLY" == "all" || "$EVAL_ONLY" == "eval1" ]]; then
        echo "── EVAL 1: Independent/Dependent ratio sweep ───────────────────"
        for indep in 100 90 80 60 40 20 10 0; do
            BASE_ENV=(
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${NUM_CLIENTS_FOR_RUN}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
                "INDEP_RATIO=${indep}" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=info" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
            )
            run_case "n${NUM_SERVERS}/eval1_indep_${indep}" "$RUNTIME_SECONDS"
        done
    fi

    # ============================================================
    # EVAL 2: batch size sweep
    # ============================================================
    if [[ "$EVAL_ONLY" == "all" || "$EVAL_ONLY" == "eval2" ]]; then
        echo "── EVAL 2: Batch size sweep ─────────────────────────────────────"
        for batch_size in 1 10 50 100 500 1000 2000; do
            BASE_ENV=(
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${NUM_CLIENTS_FOR_RUN}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=${batch_size}" "MSG_SIZE=512" "MODE=1"
                "INDEP_RATIO=90" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=info" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
            )
            run_case "n${NUM_SERVERS}/eval2_batch_${batch_size}" "$RUNTIME_SECONDS"
        done
    fi

    # ============================================================
    # EVAL 3: message size sweep
    # ============================================================
    if [[ "$EVAL_ONLY" == "all" || "$EVAL_ONLY" == "eval3" ]]; then
        echo "── EVAL 3: Message size sweep ───────────────────────────────────"
        for msg_size in 64 512 1024 2048 4096; do
            BASE_ENV=(
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${NUM_CLIENTS_FOR_RUN}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=${msg_size}" "MODE=1"
                "INDEP_RATIO=90" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=info" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
            )
            run_case "n${NUM_SERVERS}/eval3_msgsize_${msg_size}" "$RUNTIME_SECONDS"
        done
    fi

    # ============================================================
    # EVAL 4: read ratio sweep
    # ============================================================
    if [[ "$EVAL_ONLY" == "all" || "$EVAL_ONLY" == "eval4" ]]; then
        echo "── EVAL 4: Read ratio sweep ─────────────────────────────────────"
        for read_ratio in 0 25 50 75 100; do
            BASE_ENV=(
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${NUM_CLIENTS_FOR_RUN}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
                "INDEP_RATIO=90" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=info" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
                "READ_RATIO=${read_ratio}"
            )
            run_case "n${NUM_SERVERS}/eval4_readratio_${read_ratio}" "$RUNTIME_SECONDS"
        done
    fi
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  All evaluations complete                                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
