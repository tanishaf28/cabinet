#!/bin/bash
# ================================================================
# HETERO-5 NETEM SINGLE DELAY RUN + TIMELINE (Raft): one steady-state
# run at INDEP_RATIO=90, BATCHSIZE=1, under a fixed server-side-only
# netem delay profile (DELAY_MS +-JITTER_MS), producing a tps_timeline
# CSV (ENABLE_TIMESERIES=true). No ratio sweep -- single case only.
#
# Adapted from run_hetero5_ratio_delay_5c_b100_cab.sh's trailing
# timeline case, standalone.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ${SSH_KEY}"

RESULT_ROOT="${REPO_ROOT}/results/hetero5_delay_b1_r90_single_raft"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

DELAY_MS="${DELAY_MS:-5}"
JITTER_MS="${JITTER_MS:-5}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
DELAY_APPLIED=false
CLUSTER_ACTIVE=false

SERVER_IPS=(
    "192.168.73.59"
    "192.168.73.243"
    "192.168.73.192"
    "192.168.73.134"
    "192.168.73.132"
)

BASE_ENV=(
    "NUM_SERVERS=5" "NUM_CLIENTS=5" "THRESHOLD=2" "OPS=0"
    "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
    "INDEP_RATIO=90" "NUM_OBJECTS=1000"
    "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
    "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
    "ENABLE_TIMESERIES=true"
)

mkdir -p "$RUN_DIR"

remote_exec() {
    local host=$1; shift
    ssh ${SSH_OPTS} "$USER@$host" "$*"
}

detect_interface() {
    local host=$1
    remote_exec "$host" "ip route show default 2>/dev/null | awk '{print \$5; exit}'"
}

apply_server_only_delay() {
    local delay_ms=$1
    local jitter_ms=$2
    echo "  [netem] Applying ${delay_ms}ms ±${jitter_ms}ms to server links only..."
    for ip in "${SERVER_IPS[@]}"; do
        local iface; iface=$(detect_interface "$ip")
        [ -z "$iface" ] && echo "  Warning: no interface on $ip" && continue
        remote_exec "$ip" \
            "sudo tc qdisc del dev '$iface' root 2>/dev/null || true; \
             sudo tc qdisc add dev '$iface' root netem delay ${delay_ms}ms ${jitter_ms}ms distribution normal" \
            || true
    done
    sleep 1
}

remove_server_delay() {
    echo "  [netem] Removing server-side delay..."
    for ip in "${SERVER_IPS[@]}"; do
        local iface; iface=$(detect_interface "$ip")
        [ -z "$iface" ] && continue
        remote_exec "$ip" "sudo tc qdisc del dev '$iface' root 2>/dev/null || true" || true
    done
    sleep 1
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
    find "${EVAL_DIR}" -mindepth 2 -maxdepth 2 -name "tps_timeline_*.csv" -exec cp {} "${dest_dir}/" \; 2>/dev/null || true

    echo "  Archived results to: $dest_dir"
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
    if [ "$DELAY_APPLIED" = true ]; then
        remove_server_delay || true
    fi
}
trap cleanup EXIT INT

echo "================================================================"
echo " HETERO-5 NETEM SINGLE DELAY RUN (Raft): ${DELAY_MS}ms ±${JITTER_MS}ms, indep=90, batch=1"
echo "================================================================"
echo "Result archive: $RUN_DIR"

rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

apply_server_only_delay "$DELAY_MS" "$JITTER_MS"
DELAY_APPLIED=true

start_cluster
echo "  Running for ${RUNTIME_SECONDS}s..."
sleep "$RUNTIME_SECONDS"
stop_cluster

archive_results "delay_${DELAY_MS}ms_jitter_${JITTER_MS}ms_indep90_b1"

remove_server_delay
DELAY_APPLIED=false

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft --size 5

echo ""
echo "=================================================="
echo " Hetero-5 netem single delay run complete (Raft)"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
