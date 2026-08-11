#!/bin/bash
# ================================================================
# HOMOGENEOUS PLAIN-MSG EVALUATION RUNNER (RAFT)
# Runs the homogeneous Cabinet cluster across cluster sizes
# n = 3, 5, 7, 11 (sliced from config/cluster_homo.conf) and the core
# workload sweeps:
#   eval1  Independent/Dependent ratio sweep
#   eval2  Batch size sweep
#   eval3  Message size sweep
#   eval4  Read ratio sweep (-readratio, quorum-confirmed reads only)
#
# THRESHOLD (-t, quorum fault-tolerance) scales with cluster size as
# floor((n-1)/2): 1/2/3/5 for n=3/5/7/11.
#
# Homogeneous counterpart of run_hetero_plainmsg_raft.sh. Same
# sweeps, same eval-runner shape, just launched against
# config/cluster_homo.conf via scripts/start_cluster_homo.sh
# instead of the heterogeneous launcher.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_homo.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_homo.sh"

RESULT_ROOT="${REPO_ROOT}/results/homo_plainmsg"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

CLUSTER_ACTIVE=false

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
EVAL_ONLY="${1:-all}"
# A number, or the literal string "match" to run clients=servers for each
# size in the sweep (client VMs are cycled/reused if a size needs more
# clients than config/cluster_homo.conf's pool has -- see
# start_cluster_homo.sh).
CLIENT_COUNT="${CLIENT_COUNT:-2}"

SERVER_COUNTS=(3 5 7 11)

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
Usage: bash run_homo_plainmsg_raft.sh [selector]

Selectors (default: all):
  eval1   Independent/Dependent ratio sweep
  eval2   Batch size sweep (1 10 50 100 500 1000 2000)
  eval3   Message size sweep (64 512 1024 2048 4096)
  eval4   Read ratio sweep (-readratio 0,25,50,75,100, quorum reads only)

Each eval runs across cluster sizes n = 3, 5, 7, 11 (homogeneous, sliced
from config/cluster_homo.conf). THRESHOLD scales as floor((n-1)/2).

Environment overrides:
  RUNTIME_SECONDS=30
  CLIENT_COUNT=2   client count per size -- a number, or "match" to run
                   clients=servers for each size

Results: results/homo_plainmsg/<timestamp>/n<N>/<label>/
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
echo "║      HOMOGENEOUS PLAIN-MSG EVALUATION RUNNER (Raft)        ║"
echo "║         Cluster sizes: n = 3, 5, 7, 11                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Result archive: $RUN_DIR"
echo ""

for NUM_SERVERS in "${SERVER_COUNTS[@]}"; do
    THRESHOLD=$(( (NUM_SERVERS - 1) / 2 ))
    if [ "$CLIENT_COUNT" = "match" ]; then
        CURRENT_CLIENT_COUNT=$NUM_SERVERS
    else
        CURRENT_CLIENT_COUNT=$CLIENT_COUNT
    fi

    echo ""
    echo "════════════════ Cluster size n=${NUM_SERVERS} (t=${THRESHOLD}, clients=${CURRENT_CLIENT_COUNT}) ════════════════"

    # ============================================================
    # EVAL 1: Independent/Dependent ratio sweep
    # ============================================================
    if [[ "$EVAL_ONLY" == "all" || "$EVAL_ONLY" == "eval1" ]]; then
        echo "── EVAL 1: Independent/Dependent ratio sweep ───────────────────"
        for indep in 100 90 80 60 40 20 10 0; do
            BASE_ENV=(
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${CURRENT_CLIENT_COUNT}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
                "INDEP_RATIO=${indep}" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
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
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${CURRENT_CLIENT_COUNT}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=${batch_size}" "MSG_SIZE=512" "MODE=1"
                "INDEP_RATIO=90" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
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
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${CURRENT_CLIENT_COUNT}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=${msg_size}" "MODE=1"
                "INDEP_RATIO=90" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
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
                "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${CURRENT_CLIENT_COUNT}" "THRESHOLD=${THRESHOLD}" "OPS=0"
                "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
                "INDEP_RATIO=90" "NUM_OBJECTS=1000"
                "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
                "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
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
