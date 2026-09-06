#!/bin/bash
# ================================================================
# Plain-msg Failure-Threshold BASELINE, n=11 (Raft)
#
# Raft's counterpart to run_threshold_sweep_n11_cab.sh. Raft has no
# tunable per-run weighted threshold in any meaningful sense (it's plain
# majority), so this does NOT sweep t. It runs ONCE at n=11, THRESHOLD=5
# (floor((11-1)/2), Raft's natural majority), with INDEP_RATIO=90,
# BATCHSIZE=1, MSG_SIZE=512 fixed (same fixed values as the Cabinet
# sweep), producing Raft's single fixed comparison point to plot alongside
# Cabinet's swept-t=1..5 points at the same n=11. Labeled
# "n11_plain_baseline" (not "_t<t>", since nothing is swept).
#
# Plain-msg counterpart of run_mongodb_threshold_sweep_n11_raft.sh -- same
# reasoning, against the plain-msg cluster (start_cluster_hetero.sh)
# instead of the MongoDB one.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"
CONFIG_PATH="${REPO_ROOT}/config/cluster_hetero_11n_10c.conf"

RESULT_ROOT="${REPO_ROOT}/results/threshold_sweep_n11_raft"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

NUM_SERVERS=11
T=$(( (NUM_SERVERS - 1) / 2 ))
NUM_CLIENTS="${NUM_CLIENTS:-2}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
INDEP_RATIO_FIXED="${INDEP_RATIO_FIXED:-90}"
CLUSTER_ACTIVE=false

mkdir -p "$RUN_DIR"

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_threshold_sweep_n11_raft.sh

Runs ONE case at n=11, THRESHOLD=5 (Raft's natural majority - no per-run
threshold sweep, since Raft has no tunable weighted threshold), with
INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 fixed, against the Raft
plain-msg cluster (start_cluster_hetero.sh, -et=0, ENABLE_PRIORITY=false).
Labeled "n11_plain_baseline" to plot alongside Cabinet's swept-t points at
the same n (see run_threshold_sweep_n11_cab.sh).

Environment overrides:
  RUNTIME_SECONDS=30           wall-clock seconds
  NUM_CLIENTS=10                 client count (10-VM pool)
  INDEP_RATIO_FIXED=90          fixed indep ratio

Results: results/threshold_sweep_n11_raft/<timestamp>/<label>/
EOF
    exit 0
fi

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

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       RAFT PLAIN-MSG THRESHOLD BASELINE, n=11 (t=5, fixed)       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""
echo "n=${NUM_SERVERS}, majority t=${T}, single fixed case"

BASE_ENV=(
    "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${NUM_CLIENTS}" "CONFIG_PATH=${CONFIG_PATH}" "THRESHOLD=${T}" "OPS=0"
    "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
    "INDEP_RATIO=${INDEP_RATIO_FIXED}" "NUM_OBJECTS=1000"
    "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
    "LOG_LEVEL=info" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
)
run_case "n11_plain_baseline" "$RUNTIME_SECONDS"

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft --size "$NUM_SERVERS"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Raft plain-msg threshold baseline (n=11) complete             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
