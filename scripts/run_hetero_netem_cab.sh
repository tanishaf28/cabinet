#!/bin/bash
# ================================================================
# HETEROGENEOUS NETWORK-DELAY EVAL (CABINET)
# D1: uniform delay sweep {0,5,10}ms. D4: bursty calm/spike cycling.
#
# Trimmed from the old 7-point (0/5/10/20/50/100/200ms) scaled+fixed sweep
# down to a single {0,5,10}ms+burst run at fixed MAX_INFLIGHT=5, and
# switched delay injection from all-nodes to SERVER-egress-only, so this
# matches WOC's/EPaxos's netem evals point-for-point and scope-for-scope
# (all 4 systems' netem numbers are now directly comparable; previously
# Cabinet/Raft's numbers included client-egress delay that WOC/EPaxos's
# didn't).
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
REMOTE_DIR="/home/ubuntu/cabinet"

RESULT_ROOT="${REPO_ROOT}/results/hetero_netem"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

CONFIG_PATH="${REPO_ROOT}/config/cluster_hetero_5n_10c.conf"
mapfile -t ALL_POOL_IPS < <(awk 'NF >= 2 {print $2}' "$CONFIG_PATH")
SERVER_IPS=("${ALL_POOL_IPS[@]:0:5}")
NUM_CLIENTS="${NUM_CLIENTS:-2}"
CLIENT_IPS=("${ALL_POOL_IPS[@]:5:NUM_CLIENTS}")

CLUSTER_ACTIVE=false
RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
INDEP_RATIO_FIXED="${INDEP_RATIO_FIXED:-90}"

BASE_ENV=(
    "NUM_SERVERS=5" "NUM_CLIENTS=${NUM_CLIENTS}" "THRESHOLD=1" "OPS=0"
    "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
    "INDEP_RATIO=${INDEP_RATIO_FIXED}" "NUM_OBJECTS=1000"
    "PIPELINE_MODE=true" "MAX_INFLIGHT=5"
    "ENABLE_TIMESERIES=true"
    "LOG_LEVEL=info" "ENABLE_PRIORITY=true" "SERVER_BATCHING=false"
    "CONFIG_PATH=${CONFIG_PATH}"
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

cache_server_ifaces() {
    echo "  [iface] Caching server network interfaces..."
    _CACHED_SERVER_IFACES=()
    for ip in "${SERVER_IPS[@]}"; do
        local iface; iface=$(detect_interface "$ip")
        _CACHED_SERVER_IFACES+=("$iface")
    done
}

# apply_server_only_delay: SERVER_IPS only, never a CLIENT_IPS interface.
apply_server_only_delay() {
    local delay_ms=$1
    local jitter_ms=$2
    if [ "$delay_ms" -eq 0 ]; then
        remove_server_delay; return 0
    fi
    echo "  [netem D1] ${delay_ms}ms ±${jitter_ms}ms on server links only..."
    # netem rejects "distribution normal" at jitter=0ms, failing the qdisc
    # add outright -- the `|| true` below swallows it, leaving NO delay
    # applied. Omit jitter/distribution entirely when jitter_ms=0.
    local netem_clause="delay ${delay_ms}ms"
    [ "$jitter_ms" -gt 0 ] && netem_clause="delay ${delay_ms}ms ${jitter_ms}ms distribution normal"
    for ip in "${SERVER_IPS[@]}"; do
        local iface; iface=$(detect_interface "$ip")
        [ -z "$iface" ] && continue
        remote_exec "$ip" \
            "sudo tc qdisc del dev '$iface' root 2>/dev/null || true; \
             sudo tc qdisc add dev '$iface' root netem ${netem_clause}" \
            || true
    done
    sleep 1
}

remove_server_delay() {
    echo "  [netem] Removing server-side delay..."
    local use_cache=false
    if declare -p _CACHED_SERVER_IFACES >/dev/null 2>&1 && \
       [ "${#_CACHED_SERVER_IFACES[@]}" -eq "${#SERVER_IPS[@]}" ]; then
        use_cache=true
    fi

    if [ "$use_cache" = true ]; then
        for idx in "${!SERVER_IPS[@]}"; do
            local ip="${SERVER_IPS[$idx]}"
            local iface="${_CACHED_SERVER_IFACES[$idx]}"
            [ -z "$iface" ] && continue
            ssh -i "$SSH_KEY" "$USER@$ip" \
                "sudo tc qdisc del dev '$iface' root 2>/dev/null || true" || true &
        done
        wait
    else
        for ip in "${SERVER_IPS[@]}"; do
            local iface; iface=$(detect_interface "$ip")
            [ -z "$iface" ] && continue
            remote_exec "$ip" "sudo tc qdisc del dev '$iface' root 2>/dev/null || true" || true
        done
    fi
    sleep 1
}

start_cluster_with_timeseries() {
    CLUSTER_ACTIVE=true
    env "ENABLE_TIMESERIES=true" "${BASE_ENV[@]}" bash "$START_SCRIPT"
}

stop_cluster() {
    # stop_cluster_hetero.sh reads CLIENT_COUNT (default 2), not NUM_CLIENTS
    # -- BASE_ENV only carries NUM_CLIENTS, so without this the stop/collect
    # phase silently falls back to 2 clients regardless of how many were
    # actually started, dropping every client beyond the 2nd from both the
    # graceful-stop pass and the eval-directory collection.
    env "${BASE_ENV[@]}" CLIENT_COUNT="${NUM_CLIENTS}" bash "$STOP_SCRIPT"
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

inject_event() {
    local label=$1
    local num_servers="${NUM_SERVERS:-${#SERVER_IPS[@]}}"

    echo "  [event] ${label}"

    for i in "${!CLIENT_IPS[@]}"; do
        local cid=$(( num_servers + i ))
        local event_path="${REMOTE_DIR}/eval/client${cid}/.event"
        timeout 8s ssh ${SSH_OPTS} "$USER@${CLIENT_IPS[$i]}" \
            "mkdir -p '${REMOTE_DIR}/eval/client${cid}' && printf '%s\n' '${label}' > '${event_path}'" \
            >/dev/null 2>&1 || echo "  [event] warning: timeout writing event on ${CLIENT_IPS[$i]}" &
    done
    wait
}

run_d1_case_sampled() {
    local label=$1
    local delay_ms=$2
    local jitter_ms=$3

    echo ""
    echo "=================================================="
    echo "Running (sampled): $label  [D1 ${delay_ms}ms ±${jitter_ms}ms, server-only]"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    apply_server_only_delay "$delay_ms" "$jitter_ms"
    start_cluster_with_timeseries
    inject_event "delay_${delay_ms}ms"

    sleep "$RUNTIME_SECONDS"

    remove_server_delay
    stop_cluster
    archive_results "$label"
}

run_d4_case_sampled() {
    local label=$1
    local calm_duration="${2:-10}"
    local burst_duration="${3:-5}"
    local burst_delay_ms="${4:-1000}"
    local burst_jitter_ms="${5:-100}"
    # See apply_server_only_delay's comment: netem rejects jitter=0ms with
    # "distribution normal", which fails the qdisc add silently.
    local burst_netem_clause="delay ${burst_delay_ms}ms"
    [ "$burst_jitter_ms" -gt 0 ] && burst_netem_clause="delay ${burst_delay_ms}ms ${burst_jitter_ms}ms distribution normal"

    echo ""
    echo "=================================================="
    echo "Running (sampled): $label  [D4 ${calm_duration}s calm / ${burst_duration}s burst @ ${burst_delay_ms}ms±${burst_jitter_ms}ms, server-only]"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    cache_server_ifaces
    remove_server_delay
    start_cluster_with_timeseries
    inject_event "calm_start"

    local elapsed=0
    local cycle=0

    while [ "$elapsed" -lt "$RUNTIME_SECONDS" ]; do
        inject_event "calm_c${cycle}"
        for i in "${!SERVER_IPS[@]}"; do
            ssh -i "$SSH_KEY" "$USER@${SERVER_IPS[$i]}" \
                "sudo tc qdisc del dev '${_CACHED_SERVER_IFACES[$i]}' root 2>/dev/null || true" || true &
        done
        wait

        local calm_sleep=$(( calm_duration < (RUNTIME_SECONDS - elapsed) ? calm_duration : (RUNTIME_SECONDS - elapsed) ))
        sleep "$calm_sleep"
        elapsed=$(( elapsed + calm_sleep ))
        [ "$elapsed" -ge "$RUNTIME_SECONDS" ] && break

        inject_event "burst_c${cycle}"
        for i in "${!SERVER_IPS[@]}"; do
            ssh -i "$SSH_KEY" "$USER@${SERVER_IPS[$i]}" \
                "sudo tc qdisc del dev '${_CACHED_SERVER_IFACES[$i]}' root 2>/dev/null || true; \
                 sudo tc qdisc add dev '${_CACHED_SERVER_IFACES[$i]}' root netem ${burst_netem_clause}" \
                || true &
        done
        wait

        local burst_sleep=$(( burst_duration < (RUNTIME_SECONDS - elapsed) ? burst_duration : (RUNTIME_SECONDS - elapsed) ))
        sleep "$burst_sleep"
        elapsed=$(( elapsed + burst_sleep ))
        cycle=$(( cycle + 1 ))
    done

    inject_event "post_burst"
    remove_server_delay
    stop_cluster
    archive_results "$label"
}

cleanup() {
    remove_server_delay || true
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  HETEROGENEOUS NETWORK-DELAY EVAL (Cabinet): {0,5,10}ms + burst ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

echo "── D1: Uniform delays, server-only (fixed MAX_INFLIGHT=5) ───────"
D1_DELAYS=(0 5 10)
if [ -n "${DELAY_CASES:-}" ]; then
    read -r -a D1_DELAYS <<< "$DELAY_CASES"
fi
for delay_ms in "${D1_DELAYS[@]}"; do
    jitter_ms=0
    [ "$delay_ms" -ne 0 ] && jitter_ms=$(( delay_ms / 5 ))
    run_d1_case_sampled "D1_${delay_ms}ms" "$delay_ms" "$jitter_ms"
done

if [ "${SKIP_BURST:-false}" != "true" ]; then
    echo "── D4: Bursting, server-only (fixed MAX_INFLIGHT=5, 15s calm / 10s spike) ──"
    run_d4_case_sampled "D4_burst_${BURST_DELAY_MS:-1000}ms" 15 10 "${BURST_DELAY_MS:-1000}" "${BURST_JITTER_MS:-100}"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Network-delay eval complete                                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
