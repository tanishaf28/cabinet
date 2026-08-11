#!/bin/bash
# ================================================================
# CLIENT SCALING EVALUATION RUNNER (HETEROGENEOUS RAFT)
#
# Fixed 5-server cluster. Sweeps total client count from a handful up to
# 50, with up to 2 client processes packed per client VM (matching
# config/cluster_hetero_55n_5s_50w.conf, which has 5 server slots + 50
# client slots across 25 VMs, 2 consecutive ids per VM). Mirrors EPaxos's
# run_hetero_client_scaling_eval.sh, reusing start_cluster_hetero.sh /
# stop_cluster_hetero.sh like the other dedicated-knob runners
# (run_hetero_plainmsg_raft.sh, run_hetero_crash_raft.sh).
#
# THRESHOLD (-t, quorum fault-tolerance) scales with cluster size as
# floor((n-1)/2) — 2 for n=5. See run_hetero_client_scaling_eval_cab.sh
# for the Cabinet counterpart (THRESHOLD fixed at 1).
#
# Fixed across the sweep: INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"

RESULT_ROOT="${REPO_ROOT}/results/hetero_client_scaling_eval"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"
CLUSTER_ACTIVE=false

NUM_SERVERS=5
THRESHOLD=$(( (NUM_SERVERS - 1) / 2 ))
CONFIG_PATH="${REPO_ROOT}/config/cluster_hetero_55n_5s_50w.conf"

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
CLIENT_COUNTS=(1 2 3 4 5 10 15 20 25 30 35 40 45 50)

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_hetero_client_scaling_eval_raft.sh

Sweeps total client count over 1,2,3,4,5,10,15,20,25,30,35,40,45,50 against a
fixed 5-server heterogeneous Raft cluster, packing up to 2 client
processes per client VM. INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 fixed,
THRESHOLD=floor((n-1)/2)=2 fixed.

Environment overrides:
  RUNTIME_SECONDS=30   wall-clock seconds per run

Results archived under: results/hetero_client_scaling_eval/<timestamp>/<label>/
EOF
    exit 0
fi

mkdir -p "$RUN_DIR"

cleanup_all_nodes() {
    echo "=================================================="
    echo " Pre-sweep cleanup: purging stale Raft processes..."
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
    # Also grab raw client dirs in case merge failed
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
    echo "  n=${NUM_SERVERS}  clients=${CURRENT_CLIENT_COUNT}  runtime=${runtime}s"
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
echo "║      CLIENT SCALING EVALUATION RUNNER (HETEROGENEOUS RAFT)      ║"
echo "║     5 servers fixed, clients swept 2..50 (2 per client VM)      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

cleanup_all_nodes

for client_count in "${CLIENT_COUNTS[@]}"; do
    CURRENT_CLIENT_COUNT="$client_count"
    BASE_ENV=(
        "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=${client_count}" "THRESHOLD=${THRESHOLD}" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "CONFIG_PATH=${CONFIG_PATH}"
        "INDEP_RATIO=90" "NUM_OBJECTS=1000"
        "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
        "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
        "MAX_INFLIGHT=5"
    )
    run_case "clients_${client_count}" "$RUNTIME_SECONDS"
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft

echo ""
echo "=================================================="
echo " Client scaling evaluation sweep complete (Raft)"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
