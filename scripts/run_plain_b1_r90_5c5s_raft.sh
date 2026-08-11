#!/bin/bash
# ================================================================
# HETERO-5 PLAIN STEADY-STATE RUN (Raft): NUM_SERVERS=5, NUM_CLIENTS=5,
# BATCHSIZE=1, MAX_INFLIGHT=5, INDEP_RATIO=90. No netem delay, no crash --
# single steady-state observation window, for meters.go's per-run summary
# (P50/P95/P99; note cabinet/raft have no fast/slow path latency split,
# only slow-path/conflict op counts).
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"

RESULT_ROOT="${REPO_ROOT}/results/hetero5_plain_b1_r90_5c5s_raft"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
CLUSTER_ACTIVE=false

BASE_ENV=(
    "NUM_SERVERS=5" "NUM_CLIENTS=5" "THRESHOLD=2" "OPS=0"
    "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
    "INDEP_RATIO=90" "NUM_OBJECTS=1000"
    "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
    "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
    "ENABLE_TIMESERIES=true"
)

mkdir -p "$RUN_DIR"
MARKER="${RUN_DIR}/.run_start_marker"
touch "$MARKER"

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
        find "$merged_dir" -maxdepth 1 -name "*.csv" -newer "$MARKER" -exec cp {} "$dest_dir/" \; 2>/dev/null || true
    fi
    # -newer "$MARKER": client*/server* dirs get repopulated from the
    # remote hosts' own eval dirs on stop, which themselves accumulate
    # every eval CSV ever produced there (never cleaned) -- copying the
    # whole tree pulls in weeks of unrelated history, not just this run.
    find "${EVAL_DIR}" -mindepth 2 -maxdepth 2 -name "*.csv" -newer "$MARKER" -exec cp {} "${dest_dir}/" \; 2>/dev/null || true

    echo "  Archived results to: $dest_dir"
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

echo "================================================================"
echo " HETERO-5 PLAIN STEADY-STATE RUN (Raft): indep=90, batch=1, maxinflight=5, 5s/5c"
echo "================================================================"
echo "Result archive: $RUN_DIR"

rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

start_cluster
echo "  Running for ${RUNTIME_SECONDS}s..."
sleep "$RUNTIME_SECONDS"
stop_cluster

archive_results "plain_indep90_b1_5c5s"

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft --size 5

echo ""
echo "=================================================="
echo " Hetero-5 plain steady-state run complete (Raft)"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
