#!/bin/bash
# ================================================================
# HETERO-5 NETEM RATIO SWEEP + TIMELINE (RAFT): independent-ratio
# sweep (100 -> 0) under a fixed server-side-only netem delay profile,
# with a 5-client pool and BATCHSIZE=1000, followed by a single
# INDEP_RATIO=90 timeline run (ENABLE_TIMESERIES=true).
#
# Adapted from run_hetero5_netem_i2d_raft.sh: NUM_CLIENTS 2->5 (cabinet's
# start_cluster_hetero.sh already defaults NUM_SERVERS=5 to the
# 10-client-pool config, so no CONFIG_PATH override needed), BATCHSIZE
# 1->1000, JITTER_MS 5->10 (+-10ms), plus a trailing timeline-only case.
#
# Delay is applied ONCE before the first case and removed ONCE after the
# very last case (sweep + timeline), not toggled per case.
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

RESULT_ROOT="${REPO_ROOT}/results/hetero5_ratio_delay_5c_b1000_raft"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

DELAY_MS="${DELAY_MS:-10}"
JITTER_MS="${JITTER_MS:-10}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
DELAY_APPLIED=false
CLUSTER_ACTIVE=false

# Same sweep points as eval1 in run_hetero_plainmsg_cab.sh, 100 (all
# independent) -> 0 (all dependent).
INDEP_RATIOS=(100 90 80 60 40 20 10 0)

SERVER_IPS=(
    "192.168.73.59"
    "192.168.73.243"
    "192.168.73.192"
    "192.168.73.134"
    "192.168.73.132"
)

BASE_ENV=()

mkdir -p "$RUN_DIR"

# ================================================================
# HELPERS
# ================================================================

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
    # Also flatten per-client tps_timeline_*.csv into dest_dir itself (only
    # produced when ENABLE_TIMESERIES=true) -- plot_timeseries.py globs the
    # case dir directly, not nested client* subfolders.
    find "${EVAL_DIR}" -mindepth 2 -maxdepth 2 -name "tps_timeline_*.csv" -exec cp {} "${dest_dir}/" \; 2>/dev/null || true

    echo "  Archived results to: $dest_dir"
}

run_case() {
    local indep=$1
    local label=$2
    local extra_timeseries=${3:-false}

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    BASE_ENV=(
        "NUM_SERVERS=5" "NUM_CLIENTS=5" "THRESHOLD=2" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1000" "MSG_SIZE=512" "MODE=1"
        "INDEP_RATIO=${indep}" "NUM_OBJECTS=1000"
        "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
        "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
        "ENABLE_TIMESERIES=${extra_timeseries}"
    )

    start_cluster
    echo "  Running for ${RUNTIME_SECONDS}s..."
    sleep "$RUNTIME_SECONDS"
    stop_cluster

    archive_results "$label"
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
echo " HETERO-5 NETEM RATIO SWEEP + TIMELINE (Raft): ${DELAY_MS}ms ±${JITTER_MS}ms, 5 clients, batch=1000"
echo "================================================================"
echo "Result archive: $RUN_DIR"
echo "Sweep test cases (INDEP_RATIO): ${INDEP_RATIOS[*]}"

apply_server_only_delay "$DELAY_MS" "$JITTER_MS"
DELAY_APPLIED=true

case_num=1
for indep in "${INDEP_RATIOS[@]}"; do
    echo ""
    echo "--- Sweep case ${case_num}/${#INDEP_RATIOS[@]}: INDEP_RATIO=${indep} ---"
    run_case "$indep" "indep_${indep}"
    case_num=$((case_num + 1))
done

echo ""
echo "--- Timeline case: INDEP_RATIO=90 (ENABLE_TIMESERIES=true) ---"
run_case "90" "indep_90_timeline" true

remove_server_delay
DELAY_APPLIED=false

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft --size 5

echo ""
echo "=================================================="
echo " Hetero-5 netem ratio sweep + timeline complete (Raft)"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
