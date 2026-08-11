#!/bin/bash
# ================================================================
# HETEROGENEOUS CRASH/FAULT-INJECTION EVAL (CABINET)
# Follower crashes at replica 2, 3, 4 on the fixed 5-server heterogeneous
# cluster. Extracted out of run_hetero_plainmsg_cab.sh's old eval_crash
# block, which now only covers indep/batch/msgsize/read sweeps (see
# run_hetero_plainmsg_cab.sh).
#
#   ./run_hetero_crash_cab.sh [replica2|replica3|replica4|leader|all] [batchsize] [indep_ratio]
#
# Defaults to running all three follower cases. NUM_CLIENTS=5,
# BATCHSIZE=100 (default), MSG_SIZE=512, RUNTIME_SECONDS=60, and the
# 5-host CLIENT_IPS list are shared byte-for-byte with woc's, epaxos's,
# and raft's own crash-eval drivers so all four protocols' crash evals
# run under identical offered load and are comparable. THRESHOLD=1 is
# Cabinet's own tunable priority-quorum default (Raft/EPaxos use t=2's
# fixed majority-quorum equivalent; CORA uses t=2 too) - see those
# scripts' own headers for why.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

TARGET="${1:-all}"
BATCHSIZE_OVERRIDE="${2:-100}"
INDEP_RATIO_OVERRIDE="${3:-90}"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ${SSH_KEY}"
BINARY_NAME="cabinet"
REMOTE_DIR="/home/ubuntu/cabinet"

RESULT_ROOT="${SCRIPT_DIR}/results/hetero5_crash_eval"
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

# Must match the client slice start_cluster_hetero.sh assigns for
# NUM_CLIENTS=5 (config pool order after the 5 server IPs) -- same list
# used by woc/epaxos/raft's crash scripts so all 4 protocols' crash evals
# run on identical client VMs.
CLIENT_IPS=(
    "192.168.73.159"
    "192.168.73.84"
    "192.168.73.218"
    "192.168.73.219"
    "192.168.73.25"
)

CLUSTER_ACTIVE=false
RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
CRASH_TRIGGER_SECONDS="${CRASH_TRIGGER_SECONDS:-10}"

BASE_ENV=(
    "NUM_SERVERS=5" "NUM_CLIENTS=5" "THRESHOLD=1" "OPS=0"
    "EVAL_TYPE=0" "BATCHSIZE=${BATCHSIZE_OVERRIDE}" "MSG_SIZE=512" "MODE=1"
    "INDEP_RATIO=${INDEP_RATIO_OVERRIDE}" "NUM_OBJECTS=1000"
    "PIPELINE_MODE=true" "MAX_INFLIGHT=5"
    "ENABLE_TIMESERIES=true"
    "LOG_LEVEL=info" "ENABLE_PRIORITY=true" "SERVER_BATCHING=false"
)

mkdir -p "$RUN_DIR"

remote_exec() {
    local host=$1; shift
    ssh ${SSH_OPTS} "$USER@$host" "$*"
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

# Kill Cabinet process on a given node.
kill_cabinet_on_node() {
    local ip=$1
    local label=${2:-cabinet}

    if remote_exec "$ip" "pgrep -x ${BINARY_NAME} >/dev/null 2>&1"; then
        echo "  Killing ${label} on ${ip}..."
        remote_exec "$ip" "pkill -TERM -x ${BINARY_NAME} 2>/dev/null || true" || true
        sleep 2
        if remote_exec "$ip" "pgrep -x ${BINARY_NAME} >/dev/null 2>&1"; then
            remote_exec "$ip" "pkill -KILL -x ${BINARY_NAME} 2>/dev/null || true" || true
            sleep 1
        fi
        echo "  Confirmed ${label} stopped on ${ip}"
    else
        echo "  Note: ${label} was not running on ${ip}"
    fi
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

run_crash_case_sampled() {
    local label=$1
    local node_spec=$2

    echo ""
    echo "=================================================="
    echo "Running (sampled): $label  [crash: ${node_spec} at t=${CRASH_TRIGGER_SECONDS}s]"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    start_cluster_with_timeseries
    inject_event "stable"
    echo "  [crash] Waiting ${CRASH_TRIGGER_SECONDS}s before fault injection..."
    sleep "$CRASH_TRIGGER_SECONDS"

    local kind="${node_spec%%:*}"
    local arg="${node_spec#*:}"

    case "$kind" in
        no_failure)
            inject_event "no_failure_baseline"
            ;;
        leader)
            inject_event "crash_leader"
            kill_cabinet_on_node "${SERVER_IPS[0]}" "leader"
            ;;
        follower)
            inject_event "crash_follower${arg}"
            kill_cabinet_on_node "${SERVER_IPS[$arg]}" "server${arg}"
            ;;
        f_of_n)
            local available=()
            for i in "${!SERVER_IPS[@]}"; do
                [ "$i" -eq 0 ] && continue
                available+=("$i")
            done
            local k=0
            while [ $k -lt "$arg" ] && [ "${#available[@]}" -gt 0 ]; do
                local pick=$(( RANDOM % ${#available[@]} ))
                local fid="${available[$pick]}"
                kill_cabinet_on_node "${SERVER_IPS[$fid]}" "server${fid}" &
                available=("${available[@]:0:$pick}" "${available[@]:$(( pick+1 ))}")
                k=$((k + 1))
            done
            wait
            inject_event "crash_f${arg}"
            ;;
        *)
            echo "  ERROR: unknown crash spec '$node_spec'"
            return 1 ;;
    esac

    inject_event "post_crash"
    echo "  [crash] Observing ${RUNTIME_SECONDS}s after fault..."
    sleep "$RUNTIME_SECONDS"

    stop_cluster
    archive_results "$label"
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

run_case() {
    case "$1" in
        replica2) run_crash_case_sampled "case_replica2" "follower:2" ;;
        replica3) run_crash_case_sampled "case_replica3" "follower:3" ;;
        replica4) run_crash_case_sampled "case_replica4" "follower:4" ;;
        leader)   run_crash_case_sampled "case_leader" "leader" ;;
        *) echo "Usage: $0 [replica2|replica3|replica4|leader|all] [batchsize] [indep_ratio]"; exit 1 ;;
    esac
}

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  HETEROGENEOUS CRASH/FAULT-INJECTION EVAL (Cabinet)              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Target: ${TARGET}  |  Batch: ${BATCHSIZE_OVERRIDE}  |  Indep ratio: ${INDEP_RATIO_OVERRIDE}"
echo "Result archive: $RUN_DIR"
echo ""

if [ "$TARGET" = "all" ]; then
    run_case replica2
    run_case replica3
    run_case replica4
else
    run_case "$TARGET"
fi

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --size 5 --system cabinet

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Crash eval complete                                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
