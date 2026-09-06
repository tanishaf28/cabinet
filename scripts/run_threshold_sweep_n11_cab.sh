#!/bin/bash
# ================================================================
# Plain-msg Failure-Threshold Sweep, n=11 (Cabinet)
#
# Sweeps THRESHOLD (t) at the fixed 11-node heterogeneous cluster
# (config/cluster_hetero_11n_10c.conf, plain-msg/-et=0), with
# INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 held fixed throughout - only t
# changes. t ranges 1..5 (floor((11-1)/2) = 5, Cabinet has a real per-run
# weighted threshold, so this side of the comparison sweeps it -- see
# run_threshold_sweep_n11_raft.sh for Raft's counterpart, which has no
# tunable per-run threshold and instead runs once at its natural majority).
#
# Plain-msg counterpart of run_mongodb_threshold_sweep_n11_cab.sh -- same
# t range/fixed params, against the plain-msg cluster
# (start_cluster_hetero.sh) instead of the MongoDB one.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"
CONFIG_PATH="${REPO_ROOT}/config/cluster_hetero_11n_10c.conf"

RESULT_ROOT="${REPO_ROOT}/results/threshold_sweep_n11_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

NUM_SERVERS=11
MAX_T=$(( (NUM_SERVERS - 1) / 2 ))
NUM_CLIENTS="${NUM_CLIENTS:-2}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
INDEP_RATIO_FIXED="${INDEP_RATIO_FIXED:-90}"
CLUSTER_ACTIVE=false

mkdir -p "$RUN_DIR"

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_threshold_sweep_n11_cab.sh

Sweeps failure threshold t=1..5 at the fixed n=11 heterogeneous cluster,
with INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 fixed, against the Cabinet
plain-msg cluster (start_cluster_hetero.sh, -et=0, ENABLE_PRIORITY=true).

Environment overrides:
  RUNTIME_SECONDS=30           wall-clock seconds per run
  NUM_CLIENTS=10                 client count (10-VM pool)
  INDEP_RATIO_FIXED=90          fixed indep ratio for every case

Results: results/threshold_sweep_n11_cab/<timestamp>/<label>/
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
echo "║      CABINET PLAIN-MSG THRESHOLD SWEEP, n=11 (t=1..5)            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

for ((t = 1; t <= MAX_T; t++)); do
    echo "════════════════ t=${t} (n=${NUM_SERVERS}, clients=${NUM_CLIENTS}) ════════════════"
    BASE_ENV=(
        "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${NUM_CLIENTS}" "CONFIG_PATH=${CONFIG_PATH}" "THRESHOLD=${t}" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "INDEP_RATIO=${INDEP_RATIO_FIXED}" "NUM_OBJECTS=1000"
        "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
        "LOG_LEVEL=info" "ENABLE_PRIORITY=true" "RATIO_STEP=0.001"
    )
    run_case "n11_plain_t${t}" "$RUNTIME_SECONDS"
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system cabinet --size "$NUM_SERVERS"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Cabinet plain-msg threshold sweep (n=11) complete             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
