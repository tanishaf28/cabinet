#!/bin/bash
# ================================================================
# HETERO-5 RATIO SWEEP (Raft): NUM_SERVERS=5, NUM_CLIENTS=5,
# BATCHSIZE=1. Sweeps INDEP_RATIO over the standard
# 100/90/80/60/40/20/10/0 points used across the repo's other sweep
# scripts. No netem delay, no crash injection -- plain steady-state per
# case. Mirrors epaxos's/woc's run_ratio_sweep_b1_5c5s.sh, ported to
# Cabinet's own start_cluster_hetero.sh/BASE_ENV idiom (same shape as
# run_hetero_batchsize_sweep_10c_raft.sh). THRESHOLD scales as
# floor((n-1)/2)=2 at n=5 (Raft majority semantics) -- see
# run_ratio_sweep_b1_5c5s_cab.sh for Cabinet's counterpart (t=1, fixed).
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"
CONFIG_PATH="${REPO_ROOT}/config/cluster_hetero_5n_10c.conf"

RESULT_ROOT="${REPO_ROOT}/results/hetero5_ratio_sweep_b1_5c5s_raft"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
CLUSTER_ACTIVE=false

TEST_CASES=(100.0 90.0 80.0 60.0 40.0 20.0 10.0 0.0)

mkdir -p "$RUN_DIR"

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

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

echo "================================================================"
echo " HETERO-5 RATIO SWEEP (Raft): batch=1, 5s/5c"
echo "================================================================"
echo "Result archive: $RUN_DIR"
echo "Sweep test cases (INDEP_RATIO): ${TEST_CASES[*]}"

case_num=1
for indep in "${TEST_CASES[@]}"; do
    echo ""
    echo "--- Sweep case ${case_num}/${#TEST_CASES[@]}: INDEP_RATIO=${indep} ---"
    BASE_ENV=(
        "NUM_SERVERS=5" "NUM_CLIENTS=5" "CONFIG_PATH=${CONFIG_PATH}" "THRESHOLD=2" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "INDEP_RATIO=${indep}" "NUM_OBJECTS=1000"
        "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
        "LOG_LEVEL=info" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
    )
    run_case "indep_${indep}" "$RUNTIME_SECONDS"
    case_num=$((case_num + 1))
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft --size 5

echo ""
echo "=================================================="
echo " Hetero-5 ratio sweep complete (Raft)"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
