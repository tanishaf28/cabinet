#!/bin/bash
# ================================================================
# EVAL 6 (Cabinet): Batch Size Sweep x Cluster Size, 10-client pool
#
# Same sweep as run_hetero_plainmsg_cab.sh's eval2 (BATCHSIZE over
# 1,10,50,100,500,1000,2000, indep=90, msgsize=512), across cluster sizes
# n=3,5,7,11 -- but against the dedicated 10-VM client pool
# (config/cluster_hetero_{n}n_10c.conf) instead of the existing 2-client
# heterogeneous configs, mirroring WOC's eval_6_batchsize_size_sweep.sh /
# epaxos's run_hetero_batchsize_sweep_10c.sh.
#
# Added alongside, not replacing, run_hetero_plainmsg_cab.sh's eval2 --
# that script and its 2-client configs are untouched. THRESHOLD stays
# fixed at 1 across all cluster sizes (Cabinet's quorum tolerance isn't
# tied to n the way Raft's is) -- see run_hetero_batchsize_sweep_10c_raft.sh
# for the Raft-mode counterpart.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"

RESULT_ROOT="${REPO_ROOT}/results/hetero_batchsize_sweep_10c_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

CLUSTER_ACTIVE=false

RUNTIME_SECONDS="${RUNTIME_SECONDS:-40}"
# A number, or the literal string "match" to run clients=servers for each
# size in the sweep (client VMs are cycled/reused when a size needs more
# clients than the 10-VM pool has, e.g. n=11 matched -- see
# start_cluster_hetero.sh).
CLIENT_COUNT="${CLIENT_COUNT:-2}"

ALL_CLUSTER_SIZES=(3 5 7 11)
if [ -n "${CLUSTER_SIZES:-}" ]; then
    read -r -a ALL_CLUSTER_SIZES <<< "$CLUSTER_SIZES"
fi

TEST_CASES=(1 10 50 100 500 1000 2000)
if [ -n "${BATCH_CASES:-}" ]; then
    read -r -a TEST_CASES <<< "$BATCH_CASES"
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
Usage: bash run_hetero_batchsize_sweep_10c_cab.sh

Sweeps BATCHSIZE over 1,10,50,100,500,1000,2000 (matches WOC's
eval_6_batchsize_size_sweep.sh / this repo's run_hetero_plainmsg_cab.sh
eval2) with INDEP_RATIO=90, MSG_SIZE=512 fixed, across cluster sizes
n=3,5,7,11, against a dedicated 10-VM client pool
(config/cluster_hetero_{n}n_10c.conf). THRESHOLD fixed at 1 (Cabinet
quorum semantics).

Environment overrides:
  RUNTIME_SECONDS=30          wall-clock seconds per run
  CLIENT_COUNT=10             client count -- a number, or "match" to run
                               clients=servers for each size
  CLUSTER_SIZES="3 5 7 11"    override the cluster-size sweep

Results: results/hetero_batchsize_sweep_10c_cab/<timestamp>/n<N>/<label>/
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
echo "║  BATCH SIZE SWEEP x CLUSTER SIZE, 10-CLIENT POOL (Cabinet)     ║"
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

    for batch_size in "${TEST_CASES[@]}"; do
        BASE_ENV=(
            "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${CURRENT_CLIENT_COUNT}" "THRESHOLD=${THRESHOLD}" "OPS=0"
            "EVAL_TYPE=0" "BATCHSIZE=${batch_size}" "MSG_SIZE=512" "MODE=1"
            "CONFIG_PATH=${CONFIG_PATH}"
            "INDEP_RATIO=${INDEP_RATIO_FIXED:-90}" "NUM_OBJECTS=1000"
            "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
            "LOG_LEVEL=info" "ENABLE_PRIORITY=true" "RATIO_STEP=0.001"
            "BATCHWINDOWUS=${BATCHWINDOWUS:-0}" "MAXBATCH=${MAXBATCH:-1}"
        )
        run_case "n${NUM_SERVERS}/batch_${batch_size}" "$RUNTIME_SECONDS"
    done
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system cabinet

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Batch size sweep (10-client pool, Cabinet) complete           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
