#!/bin/bash
# ================================================================
# HETEROGENEOUS NETWORK-DELAY EVAL (RAFT)
# D1: uniform delay sweep. D4: bursty calm/spike cycling.
# Extracted out of run_hetero_plainmsg_cab.sh's old eval4/eval4s
# blocks, which now only cover indep/batch/msgsize/read sweeps
# (see run_hetero_plainmsg_cab.sh).
#
# Selectors: scaled (default, max-inflight scaled per delay) | fixed
# (max-inflight pinned at 5, isolates delay as the only variable).
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

SERVER_IPS=(
    "192.168.73.59"
    "192.168.73.243"
    "192.168.73.192"
    "192.168.73.134"
    "192.168.73.132"
)

CLIENT_IPS=(
    "192.168.73.218"
    "192.168.73.219"
)

CLUSTER_ACTIVE=false
RUNTIME_SECONDS="${RUNTIME_SECONDS:-45}"
SELECTOR="${1:-scaled}"

BASE_ENV=(
    "NUM_SERVERS=5" "NUM_CLIENTS=2" "THRESHOLD=2" "OPS=0"
    "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
    "INDEP_RATIO=90" "NUM_OBJECTS=1000"
    "PIPELINE_MODE=true" "MAX_INFLIGHT=5"
    "ENABLE_TIMESERIES=true"
    "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "SERVER_BATCHING=false"
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

cache_all_interfaces() {
    echo "  [iface] Caching network interfaces..."
    _CACHED_SERVER_IFACES=()
    _CACHED_CLIENT_IFACES=()
    for ip in "${SERVER_IPS[@]}"; do
        local iface; iface=$(detect_interface "$ip")
        _CACHED_SERVER_IFACES+=("$iface")
    done
    for ip in "${CLIENT_IPS[@]}"; do
        local iface; iface=$(detect_interface "$ip")
        _CACHED_CLIENT_IFACES+=("$iface")
    done
}

apply_uniform_delay() {
    local delay_ms=$1
    local jitter_ms=$2
    if [ "$delay_ms" -eq 0 ]; then
        remove_all_delay; return 0
    fi
    echo "  [netem D1] ${delay_ms}ms ±${jitter_ms}ms on all nodes..."
    for ip in "${SERVER_IPS[@]}" "${CLIENT_IPS[@]}"; do
        local iface; iface=$(detect_interface "$ip")
        [ -z "$iface" ] && continue
        remote_exec "$ip" \
            "sudo tc qdisc del dev '$iface' root 2>/dev/null || true; \
             sudo tc qdisc add dev '$iface' root netem delay ${delay_ms}ms ${jitter_ms}ms distribution normal" \
            || true
    done
    sleep 1
}

remove_all_delay() {
    echo "  [netem] Removing all impairments..."
    local use_cache=false
    if declare -p _CACHED_SERVER_IFACES _CACHED_CLIENT_IFACES >/dev/null 2>&1 && \
       [ "${#_CACHED_SERVER_IFACES[@]}" -eq "${#SERVER_IPS[@]}" ] && \
       [ "${#_CACHED_CLIENT_IFACES[@]}" -eq "${#CLIENT_IPS[@]}" ]; then
        use_cache=true
    fi

    local all_ips=("${SERVER_IPS[@]}" "${CLIENT_IPS[@]}")

    if [ "$use_cache" = true ]; then
        local all_ifaces=("${_CACHED_SERVER_IFACES[@]}" "${_CACHED_CLIENT_IFACES[@]}")
        for idx in "${!all_ips[@]}"; do
            local ip="${all_ips[$idx]}"
            local iface="${all_ifaces[$idx]}"
            [ -z "$iface" ] && continue
            ssh -i "$SSH_KEY" "$USER@$ip" \
                "sudo tc qdisc del dev '$iface' root 2>/dev/null || true" || true &
        done
        wait
    else
        for ip in "${all_ips[@]}"; do
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
    echo "Running (sampled): $label  [D1 ${delay_ms}ms ±${jitter_ms}ms]"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    apply_uniform_delay "$delay_ms" "$jitter_ms"
    start_cluster_with_timeseries
    inject_event "delay_${delay_ms}ms"

    sleep "$RUNTIME_SECONDS"

    remove_all_delay
    stop_cluster
    archive_results "$label"
}

run_d4_case_sampled() {
    local label=$1
    local calm_duration="${2:-10}"
    local burst_duration="${3:-5}"
    local runtime_override="${4:-$RUNTIME_SECONDS}"

    echo ""
    echo "=================================================="
    echo "Running (sampled): $label  [D4 ${calm_duration}s calm / ${burst_duration}s burst]"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    cache_all_interfaces
    remove_all_delay
    start_cluster_with_timeseries
    inject_event "calm_start"

    local elapsed=0
    local cycle=0

    while [ "$elapsed" -lt "$runtime_override" ]; do
        inject_event "calm_c${cycle}"
        for i in "${!SERVER_IPS[@]}"; do
            ssh -i "$SSH_KEY" "$USER@${SERVER_IPS[$i]}" \
                "sudo tc qdisc del dev '${_CACHED_SERVER_IFACES[$i]}' root 2>/dev/null || true" || true &
        done
        for i in "${!CLIENT_IPS[@]}"; do
            ssh -i "$SSH_KEY" "$USER@${CLIENT_IPS[$i]}" \
                "sudo tc qdisc del dev '${_CACHED_CLIENT_IFACES[$i]}' root 2>/dev/null || true" || true &
        done
        wait

        local calm_sleep=$(( calm_duration < (runtime_override - elapsed) ? calm_duration : (runtime_override - elapsed) ))
        sleep "$calm_sleep"
        elapsed=$(( elapsed + calm_sleep ))
        [ "$elapsed" -ge "$runtime_override" ] && break

        inject_event "burst_c${cycle}"
        for i in "${!SERVER_IPS[@]}"; do
            ssh -i "$SSH_KEY" "$USER@${SERVER_IPS[$i]}" \
                "sudo tc qdisc del dev '${_CACHED_SERVER_IFACES[$i]}' root 2>/dev/null || true; \
                 sudo tc qdisc add dev '${_CACHED_SERVER_IFACES[$i]}' root netem delay 1000ms 100ms distribution normal" \
                || true &
        done
        for i in "${!CLIENT_IPS[@]}"; do
            ssh -i "$SSH_KEY" "$USER@${CLIENT_IPS[$i]}" \
                "sudo tc qdisc del dev '${_CACHED_CLIENT_IFACES[$i]}' root 2>/dev/null || true; \
                 sudo tc qdisc add dev '${_CACHED_CLIENT_IFACES[$i]}' root netem delay 1000ms 100ms distribution normal" \
                || true &
        done
        wait

        local burst_sleep=$(( burst_duration < (runtime_override - elapsed) ? burst_duration : (runtime_override - elapsed) ))
        sleep "$burst_sleep"
        elapsed=$(( elapsed + burst_sleep ))
        cycle=$(( cycle + 1 ))
    done

    inject_event "post_burst"
    remove_all_delay
    stop_cluster
    archive_results "$label"
}

cleanup() {
    remove_all_delay || true
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

case "$SELECTOR" in
    scaled|fixed) ;;
    *)
        echo "ERROR: unknown selector '${SELECTOR}'. Usage: bash run_hetero_netem_cab.sh [scaled|fixed]"
        exit 1 ;;
esac

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  HETEROGENEOUS NETWORK-DELAY EVAL (Raft) — ${SELECTOR}"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

if [ "$SELECTOR" = "scaled" ]; then
    echo "── D1: Uniform delays (max-inflight scaled per delay) ──────────"
    # Format: "delay_ms max_inflight" -- MAX_INFLIGHT scaled so it's never
    # the bottleneck: rule of thumb MAX_INFLIGHT = ceil(target_tps*latency_s)
    D1_CASES=(
        "0   10"
        "5   15"
        "10  20"
        "20  30"
        "50  60"
        "100 100"
        "200 150"
    )
    for entry in "${D1_CASES[@]}"; do
        delay_ms=$(echo $entry | awk '{print $1}')
        inflight=$(echo $entry | awk '{print $2}')
        jitter_ms=0
        [ "$delay_ms" -ne 0 ] && jitter_ms=$(( delay_ms / 5 ))
        BASE_ENV=(
            "NUM_SERVERS=5" "NUM_CLIENTS=2" "THRESHOLD=2" "OPS=0"
            "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
            "INDEP_RATIO=90" "NUM_OBJECTS=1000"
            "PIPELINE_MODE=true" "MAX_INFLIGHT=${inflight}"
            "ENABLE_TIMESERIES=true"
            "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "SERVER_BATCHING=false"
        )
        run_d1_case_sampled "D1_${delay_ms}ms" "$delay_ms" "$jitter_ms"
    done

    echo "── D4: Bursting (15s calm / 10s spike at 1000ms) ────────────────"
    BASE_ENV=(
        "NUM_SERVERS=5" "NUM_CLIENTS=2" "THRESHOLD=2" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "INDEP_RATIO=90" "NUM_OBJECTS=1000"
        "PIPELINE_MODE=true" "MAX_INFLIGHT=5"
        "ENABLE_TIMESERIES=true"
        "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "SERVER_BATCHING=false"
    )
    D4_RUNTIME=$(( RUNTIME_SECONDS < 90 ? 90 : RUNTIME_SECONDS ))
    run_d4_case_sampled "D4_burst" 15 10 "$D4_RUNTIME"
else
    echo "── D1: Uniform delays (fixed MAX_INFLIGHT=5) ────────────────────"
    D1_DELAYS=(0 5 10 20 50 100 200)
    for delay_ms in "${D1_DELAYS[@]}"; do
        jitter_ms=0
        [ "$delay_ms" -ne 0 ] && jitter_ms=$(( delay_ms / 5 ))
        BASE_ENV=(
            "NUM_SERVERS=5" "NUM_CLIENTS=2" "THRESHOLD=2" "OPS=0"
            "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
            "INDEP_RATIO=90" "NUM_OBJECTS=1000"
            "PIPELINE_MODE=true" "MAX_INFLIGHT=5"
            "ENABLE_TIMESERIES=true"
            "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "SERVER_BATCHING=false"
        )
        run_d1_case_sampled "D1_fixed_${delay_ms}ms" "$delay_ms" "$jitter_ms"
    done

    echo "── D4: Bursting (fixed MAX_INFLIGHT=5, 15s calm / 10s spike) ────"
    BASE_ENV=(
        "NUM_SERVERS=5" "NUM_CLIENTS=2" "THRESHOLD=2" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "INDEP_RATIO=90" "NUM_OBJECTS=1000"
        "PIPELINE_MODE=true" "MAX_INFLIGHT=5"
        "ENABLE_TIMESERIES=true"
        "LOG_LEVEL=debug" "ENABLE_PRIORITY=false" "SERVER_BATCHING=false"
    )
    D4_RUNTIME=$(( RUNTIME_SECONDS < 90 ? 90 : RUNTIME_SECONDS ))
    run_d4_case_sampled "D4_fixed_burst" 15 10 "$D4_RUNTIME"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Network-delay eval complete                                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
