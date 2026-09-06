#!/bin/bash
# ================================================================
# HETERO-5 NETEM I2D SWEEP (RAFT): independent-ratio sweep
# (100 -> 0) under a single fixed server-side-only netem delay
# profile.
#
# Delay is applied ONCE before the first case and removed ONCE after
# the last case (not toggled per case) -- mirrors
# run_hetero_netem_cab.sh's apply_uniform_delay/remove_all_delay, but
# server-only (CLIENT_IPS are never touched), looped across
# INDEP_RATIO test cases the same way eval1 in
# run_hetero_plainmsg_cab.sh sweeps INDEP_RATIO for the plain
# (non-netem) workload.
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

RESULT_ROOT="${REPO_ROOT}/results/hetero_netem_i2d_sweep"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

DELAY_MS="${DELAY_MS:-10}"
JITTER_MS="${JITTER_MS:-5}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
DELAY_APPLIED=false
CLUSTER_ACTIVE=false

# Same sweep points as eval1 in run_hetero_plainmsg_cab.sh, 100 (all
# independent) -> 0 (all dependent).
INDEP_RATIOS=(100 90 80 60 40 20 10 0)

# Fixed at NUM_SERVERS=5 (config/cluster_hetero_5n_2s_3w.conf, same IPs
# as run_hetero_netem_raft.sh) -- THRESHOLD=2 (floor((n-1)/2)) since
# Raft's majority threshold scales with cluster size.
SERVER_IPS=(
    "192.168.73.59"
    "192.168.73.243"
    "192.168.73.27"
    "192.168.73.157"
    "192.168.73.78"
)

CLIENT_IPS=(
    "192.168.73.218"
    "192.168.73.219"
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

# apply_server_only_delay: delay+jitter on SERVER_IPS only. CLIENT_IPS
# are never touched, isolating the consensus protocol's behavior from
# client-link effects.
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

    echo "  Archived results to: $dest_dir"
}

run_case() {
    local indep=$1
    local case_num=$2

    echo ""
    echo "--- Case ${case_num}/${#INDEP_RATIOS[@]}: INDEP_RATIO=${indep} ---"

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    BASE_ENV=(
        "NUM_SERVERS=5" "NUM_CLIENTS=2" "THRESHOLD=2" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "INDEP_RATIO=${indep}" "NUM_OBJECTS=1000"
        "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
        "LOG_LEVEL=info" "ENABLE_PRIORITY=false" "RATIO_STEP=0.001"
    )

    start_cluster
    echo "  Running for ${RUNTIME_SECONDS}s..."
    sleep "$RUNTIME_SECONDS"
    stop_cluster

    archive_results "indep_${indep}"
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
echo " HETERO-5 NETEM I2D SWEEP (Raft): ${DELAY_MS}ms ±${JITTER_MS}ms (server-side only)"
echo "================================================================"
echo "Result archive: $RUN_DIR"
echo "Test cases (INDEP_RATIO): ${INDEP_RATIOS[*]}"

apply_server_only_delay "$DELAY_MS" "$JITTER_MS"
DELAY_APPLIED=true

case_num=1
for indep in "${INDEP_RATIOS[@]}"; do
    run_case "$indep" "$case_num"
    case_num=$((case_num + 1))
done

remove_server_delay
DELAY_APPLIED=false

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system raft --size 5

echo ""
echo "=================================================="
echo " Hetero-5 netem i2d sweep complete (Raft)"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
