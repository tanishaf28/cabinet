#!/bin/bash
# ================================================================
# MAX-INFLIGHT EVALUATION RUNNER (Cabinet) — 10-client pool
#
# Sweeps server-side MAX_INFLIGHT (Cabinet's -max-inflight is a server
# flag, not a client one -- see start_cluster_hetero.sh's start_server)
# across cluster sizes n=3,5,7,11 against the dedicated 10-VM client pool
# (config/cluster_hetero_{n}n_10c.conf), mirroring WOC's
# run_hetero_maxinflight_eval.sh / this repo's
# run_hetero_ratio_sweep_10c_cab.sh.
#
# THRESHOLD stays fixed at 1 across all cluster sizes (Cabinet's quorum
# tolerance isn't tied to n the way Raft's is) -- see
# run_hetero_maxinflight_eval_raft.sh for the Raft-mode counterpart.
#
# For a fixed 5-server/5-client run: CLUSTER_SIZES=5 CLIENT_COUNT=5 bash
# run_hetero_maxinflight_eval_cab.sh
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"

RESULT_ROOT="${REPO_ROOT}/results/hetero_maxinflight_eval_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

CLUSTER_ACTIVE=false

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
CLIENT_COUNT="${CLIENT_COUNT:-10}"

ALL_CLUSTER_SIZES=(3 5 7 11)
if [ -n "${CLUSTER_SIZES:-}" ]; then
    read -r -a ALL_CLUSTER_SIZES <<< "$CLUSTER_SIZES"
fi

MAX_INFLIGHT_VALUES=(1 2 3 4 5 10 15 20 25 30 35)
if [ -n "${MAX_INFLIGHT_VALUES_OVERRIDE:-}" ]; then
    read -r -a MAX_INFLIGHT_VALUES <<< "$MAX_INFLIGHT_VALUES_OVERRIDE"
fi

declare -A CONFIG_10C_FOR_N=(
    [3]="${REPO_ROOT}/config/cluster_hetero_3n_10c.conf"
    [5]="${REPO_ROOT}/config/cluster_hetero_5n_10c.conf"
    [7]="${REPO_ROOT}/config/cluster_hetero_7n_10c.conf"
    [11]="${REPO_ROOT}/config/cluster_hetero_11n_10c.conf"
)

mkdir -p "$RUN_DIR"

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_hetero_maxinflight_eval_cab.sh

Sweeps server-side MAX_INFLIGHT over 1,2,3,4,5,10,15,20,25,30,35 with
INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 fixed, across cluster sizes
n=3,5,7,11, against a dedicated 10-VM client pool
(config/cluster_hetero_{n}n_10c.conf). THRESHOLD fixed at 1 (Cabinet
quorum semantics).

For a fixed 5-server/5-client run: CLUSTER_SIZES=5 CLIENT_COUNT=5 bash
run_hetero_maxinflight_eval_cab.sh

Environment overrides:
  RUNTIME_SECONDS=30          wall-clock seconds per run
  CLIENT_COUNT=10             client count -- a number, or "match" to run
                               clients=servers for each size
  CLUSTER_SIZES="3 5 7 11"    override the cluster-size sweep
  MAX_INFLIGHT_VALUES_OVERRIDE="1 5 10"   override the MAX_INFLIGHT sweep

Results: results/hetero_maxinflight_eval_cab/<timestamp>/n<N>/<label>/
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
echo "║   MAX-INFLIGHT SWEEP, 10-CLIENT POOL (Cabinet)                 ║"
echo "║         Cluster sizes: n = 3, 5, 7, 11 (heterogeneous)         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

for NUM_SERVERS in "${ALL_CLUSTER_SIZES[@]}"; do
    THRESHOLD=1
    CONFIG_PATH="${CONFIG_10C_FOR_N[$NUM_SERVERS]:-}"
    if [ -z "$CONFIG_PATH" ]; then
        echo "ERROR: no 10-client config mapped for cluster size n=${NUM_SERVERS}"
        exit 1
    fi

    if [ "$CLIENT_COUNT" = "match" ]; then
        CURRENT_CLIENT_COUNT=$NUM_SERVERS
    else
        CURRENT_CLIENT_COUNT=$CLIENT_COUNT
    fi

    echo ""
    echo "════════════════ Cluster size n=${NUM_SERVERS} (t=${THRESHOLD}, clients=${CURRENT_CLIENT_COUNT}) ════════════════"

    for max_inflight in "${MAX_INFLIGHT_VALUES[@]}"; do
        BASE_ENV=(
            "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${CURRENT_CLIENT_COUNT}" "THRESHOLD=${THRESHOLD}" "OPS=0"
            "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
            "CONFIG_PATH=${CONFIG_PATH}"
            "INDEP_RATIO=90" "NUM_OBJECTS=1000"
            "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
            "LOG_LEVEL=info" "ENABLE_PRIORITY=true" "RATIO_STEP=0.001"
            "MAX_INFLIGHT=${max_inflight}"
        )
        run_case "n${NUM_SERVERS}/maxinflight_${max_inflight}" "$RUNTIME_SECONDS"
    done
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system cabinet

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Max-inflight sweep (10-client pool, Cabinet) complete          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
