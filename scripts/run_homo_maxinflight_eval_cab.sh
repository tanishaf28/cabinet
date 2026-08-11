#!/bin/bash
# ================================================================
# MAX-INFLIGHT EVALUATION RUNNER (HOMOGENEOUS CABINET) — fixed 5/5
#
# Fixed 5-server/5-client cluster (config/cluster_homo.conf). Sweeps
# server-side MAX_INFLIGHT (Cabinet's -max-inflight is a server flag, not
# a client one -- see start_cluster_homo.sh's start_server). Homogeneous
# counterpart of run_hetero_maxinflight_eval_cab.sh.
#
# THRESHOLD (-t) stays fixed at 1 — Cabinet's quorum tolerance isn't tied
# to n the way Raft's majority threshold is. See
# run_homo_maxinflight_eval_raft.sh for the Raft counterpart.
#
# Fixed across the sweep: INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_homo.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_homo.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"

RESULT_ROOT="${REPO_ROOT}/results/homo_maxinflight_eval_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"
CLUSTER_ACTIVE=false

NUM_SERVERS=5
NUM_CLIENTS="${NUM_CLIENTS:-5}"
THRESHOLD=1
CONFIG_PATH="${REPO_ROOT}/config/cluster_homo.conf"

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
MAX_INFLIGHT_VALUES=(1 2 3 4 5 10 15 20 25 30 35)
if [ -n "${MAX_INFLIGHT_VALUES_OVERRIDE:-}" ]; then
    read -r -a MAX_INFLIGHT_VALUES <<< "$MAX_INFLIGHT_VALUES_OVERRIDE"
fi

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_homo_maxinflight_eval_cab.sh

Sweeps server-side MAX_INFLIGHT over 1,2,3,4,5,10,15,20,25,30,35 against a
fixed 5-server/5-client homogeneous Cabinet cluster
(config/cluster_homo.conf). INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512
fixed, THRESHOLD=1 fixed.

Environment overrides:
  RUNTIME_SECONDS=30   wall-clock seconds per run
  NUM_CLIENTS=5
  MAX_INFLIGHT_VALUES_OVERRIDE="1 5 10"   override the MAX_INFLIGHT sweep

Results archived under: results/homo_maxinflight_eval_cab/<timestamp>/<label>/
EOF
    exit 0
fi

mkdir -p "$RUN_DIR"

cleanup_all_nodes() {
    echo "=================================================="
    echo " Pre-sweep cleanup: purging stale Cabinet processes..."
    echo "=================================================="
    local all_ips=()
    mapfile -t all_ips < <(awk 'NF >= 2 {print $2}' "$CONFIG_PATH" | sort -u)
    for ip in "${all_ips[@]}"; do
        ssh -i "$SSH_KEY" "$USER@$ip" "pkill -9 cabinet 2>/dev/null" &
    done
    wait
}

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
    ls -1 "$dest_dir"/*.csv 2>/dev/null | sed 's|.*/|    |' || echo "  (no CSVs found)"
}

run_case() {
    local label=$1
    local runtime=$2

    echo ""
    echo "=================================================="
    echo "Running: $label"
    echo "  n=${NUM_SERVERS}  clients=${NUM_CLIENTS}  runtime=${runtime}s"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    start_cluster
    sleep "$runtime"
    stop_cluster
    archive_results "$label"

    echo "  Cooling down to release TCP ports..."
    sleep 5
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║      MAX-INFLIGHT EVALUATION RUNNER (HOMOGENEOUS CABINET)       ║"
echo "║              Fixed 5 servers / 5 clients                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

cleanup_all_nodes

for max_inflight in "${MAX_INFLIGHT_VALUES[@]}"; do
    BASE_ENV=(
        "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${NUM_CLIENTS}" "THRESHOLD=${THRESHOLD}" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "CONFIG_PATH=${CONFIG_PATH}"
        "INDEP_RATIO=90" "NUM_OBJECTS=1000"
        "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
        "LOG_LEVEL=info" "ENABLE_PRIORITY=true" "RATIO_STEP=0.001"
        "MAX_INFLIGHT=${max_inflight}"
    )
    run_case "maxinflight_${max_inflight}" "$RUNTIME_SECONDS"
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system cabinet

echo ""
echo "=================================================="
echo " Max-inflight sweep complete (homogeneous Cabinet)"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
