#!/bin/bash
# ================================================================
# Cabinet/Raft MongoDB Cluster Launcher - HETEROGENEOUS, SELECTABLE SIZE
#
# Generalizes start_mongodb_hetero_5n.sh (fixed n=5) to NUM_SERVERS in
# {3,5,7,11}, for the MongoDB ratio sweep and the new MongoDB
# failure-threshold sweep, which both need to run at every cluster size,
# matching how the PlainMsg size-sweep scripts
# (run_hetero_ratio_sweep_10c_cab.sh/_raft.sh et al.) select cluster size.
# Server/client IPs are read from the chosen config file instead of being
# hardcoded, so this one script covers every size.
#
# Config file per size (facts confirmed against the actual files in
# config/, byte-identical to woc/epaxos for n=3/7/11):
#   n=3  -> cluster_hetero_3n_2s_1w.conf   (3 servers + 2-IP client pool)
#   n=5  -> cluster_hetero_5n_2s_3w.conf   (5 servers + 5-IP client pool;
#           this is Cabinet's OWN copy and is the confirmed-correct n=5
#           heterogeneous tier hardware -- same file
#           start_mongodb_hetero_5n.sh already uses. Unlike woc/epaxos's
#           copies of this filename, Cabinet's is intentional/correct.)
#   n=7  -> cluster_hetero_7n_3s_4w.conf   (7 servers + 2-IP client pool)
#   n=11 -> cluster_hetero_11n_4s_7w.conf  (11 servers + 2-IP client pool)
#
# Same binary serves both Cabinet (-ep=true) and Raft (-ep=false); pass
# ENABLE_PRIORITY=false to run as Raft (mirrors start_cluster_hetero.sh's
# cab/raft convention). THRESHOLD defaults to 1 (Cabinet's fixed quorum
# tolerance) but is fully overridable -- Raft callers should pass
# THRESHOLD=$(( (NUM_SERVERS - 1) / 2 )) themselves (see
# run_hetero_ratio_sweep_10c_raft.sh for that convention); this script
# does not hardcode either.
#
# -max-inflight is a real CLI flag (parameters.go), not an env var, and
# is passed to BOTH server and client launches below.
#
# ENABLE_TIMESERIES/TPS_TIMELINE_INTERVAL_MS are read via os.Getenv
# directly in client.go (timeseriesEnabled()/timeseriesInterval()), so
# they're passed as env-var prefixes on the CLIENT launch only, exactly
# like start_cluster_hetero.sh and start_mongodb_hetero_5n.sh already do.
# ================================================================

set -euo pipefail
trap 'echo " Script interrupted. Exiting..."; exit 1' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

USER="ubuntu"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
REMOTE_DIR="/home/ubuntu/cabinet"
BINARY="cabinet"
LOG_DIR="${REMOTE_DIR}/logs"
EVAL_DIR="${REMOTE_DIR}/eval"

WORKLOAD="${1:-a}"
if [[ ! "$WORKLOAD" =~ ^[a-f]$ ]]; then
    echo "ERROR: workload must be one of: a b c d e f"
    exit 1
fi

MONGODB_PORT=27017

# ---------------------------------------------------------------
# CLUSTER SIZE -> CONFIG FILE SELECTION
# ---------------------------------------------------------------
NUM_SERVERS="${NUM_SERVERS:-5}"
case "$NUM_SERVERS" in
    3)  DEFAULT_HETERO_CONFIG="cluster_hetero_3n_2s_1w.conf" ;;
    5)  DEFAULT_HETERO_CONFIG="cluster_hetero_5n_2s_3w.conf" ;;
    7)  DEFAULT_HETERO_CONFIG="cluster_hetero_7n_3s_4w.conf" ;;
    11) DEFAULT_HETERO_CONFIG="cluster_hetero_11n_4s_7w.conf" ;;
    *)
        echo " ERROR: no heterogeneous config for NUM_SERVERS=${NUM_SERVERS}. Supported sizes: 3, 5, 7, 11." >&2
        exit 1
        ;;
esac
CONFIG_PATH="${CONFIG_PATH:-${REPO_ROOT}/config/${DEFAULT_HETERO_CONFIG}}"

# Each cluster_hetero_<N>n_*.conf is a flat "id ip port port" list: the
# first NUM_SERVERS lines are servers (fixed strong/weak order), the rest
# are the client VM pool.
mapfile -t ALL_IPS < <(awk 'NF >= 2 { print $2 }' "$CONFIG_PATH")
if [ "${#ALL_IPS[@]}" -lt "$NUM_SERVERS" ]; then
    echo " ERROR: ${CONFIG_PATH} does not contain enough IPs for ${NUM_SERVERS} servers" >&2
    exit 1
fi
SERVER_IPS=("${ALL_IPS[@]:0:NUM_SERVERS}")
CLIENT_POOL_IPS=("${ALL_IPS[@]:NUM_SERVERS}")
if [ "${#CLIENT_POOL_IPS[@]}" -eq 0 ]; then
    echo " ERROR: ${CONFIG_PATH} does not contain any client IPs" >&2
    exit 1
fi
DEFAULT_NUM_CLIENTS="${#CLIENT_POOL_IPS[@]}"

# All vars overridable via env (mirrors start_cluster_hetero.sh /
# start_mongodb_hetero_5n.sh)
NUM_CLIENTS="${NUM_CLIENTS:-$DEFAULT_NUM_CLIENTS}"
THRESHOLD="${THRESHOLD:-1}"
OPS="${OPS:-0}"
EVAL_TYPE=1                            # 1 = MongoDB
BATCHSIZE="${BATCHSIZE:-1}"
MSG_SIZE="${MSG_SIZE:-512}"
MODE="${MODE:-1}"
INDEP_RATIO="${INDEP_RATIO:-90}"
NUM_OBJECTS="${NUM_OBJECTS:-1000}"
BATCH_MODE="${BATCH_MODE:-single}"
BATCH_COMPOSITION="${BATCH_COMPOSITION:-object-specific}"
RATIO_STEP="${RATIO_STEP:-0.001}"
LOG_LEVEL="${LOG_LEVEL:-info}"
ENABLE_PRIORITY="${ENABLE_PRIORITY:-true}"   # true=Cabinet, false=Raft
MAX_INFLIGHT="${MAX_INFLIGHT:-5}"
READ_RATIO="${READ_RATIO:-0}"
MONGO_CLIENT_NUM="${MONGO_CLIENT_NUM:-16}"
ENABLE_TIMESERIES="${ENABLE_TIMESERIES:-false}"
TPS_TIMELINE_INTERVAL_MS="${TPS_TIMELINE_INTERVAL_MS:-500}"

# Cycle through the client portion of the pool (rather than a plain slice)
# so NUM_CLIENTS > available client IPs (small pools at n=7/11) packs
# extra client processes onto already-used VMs instead of erroring out or
# coming up short. Mirrors start_cluster_hetero.sh.
CLIENT_HOST_IPS=()
for ((k = 0; k < NUM_CLIENTS; k++)); do
    CLIENT_HOST_IPS+=("${CLIENT_POOL_IPS[$((k % ${#CLIENT_POOL_IPS[@]}))]}")
done

CLIENTS_PER_VM=1

copy_binary() {
    local target_ip=$1
    echo " Copying binary to $target_ip..."
    scp -o ConnectTimeout=10 -i "$SSH_KEY" "${SCRIPT_DIR}/${BINARY}" "$USER@$target_ip:$REMOTE_DIR/"
}

copy_config() {
    local target_ip=$1
    ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$target_ip" "mkdir -p '${REMOTE_DIR}/config'"
    scp -o ConnectTimeout=10 -i "$SSH_KEY" "$CONFIG_PATH" "$USER@$target_ip:${REMOTE_DIR}/config/"
}

sync_workload_data() {
    local target_ip=$1
    echo " Syncing YCSB workload files to $target_ip ..."
    ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$target_ip" "mkdir -p '${REMOTE_DIR}/ycsb/workData'"
    scp -o ConnectTimeout=10 -i "$SSH_KEY" "${REPO_ROOT}/ycsb/workData"/*.dat "$USER@$target_ip:${REMOTE_DIR}/ycsb/workData/"
}

setup_mongodb() {
    local target_ip=$1
    local node_id=$2
    echo " Setting up MongoDB on $target_ip (Node $node_id) ..."
    ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$target_ip" bash -s <<EOF
set -e
MONGODB_PORT=27017
REMOTE_DIR="$REMOTE_DIR"

pkill -x mongod 2>/dev/null || true
sleep 1

rm -rf \$REMOTE_DIR/mongodb_data/* \$REMOTE_DIR/mongodb_data/.[!.]* \$REMOTE_DIR/mongodb_data/..?* 2>/dev/null || true
rm -f \$REMOTE_DIR/mongodb_data/mongod.lock \$REMOTE_DIR/mongodb_data/WiredTiger.lock \$REMOTE_DIR/logs/mongod.log 2>/dev/null || true
mkdir -p \$REMOTE_DIR/mongodb_data \$REMOTE_DIR/logs

mongod --port \$MONGODB_PORT \
    --dbpath \$REMOTE_DIR/mongodb_data \
    --bind_ip 0.0.0.0 \
    --logpath \$REMOTE_DIR/logs/mongod.log \
    --logappend \
    --fork --pidfilepath \$REMOTE_DIR/mongodb_data/mongod.pid

sleep 2
echo "MongoDB started on \$MONGODB_PORT"
EOF
}

wait_for_mongo_ready() {
    local target_ip=$1
    local node_label=$2
    local attempt

    for attempt in $(seq 1 30); do
        if ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$target_ip" "mongosh --quiet --eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1"; then
            return 0
        fi
        sleep 1
    done

    echo "  Warning: MongoDB readiness timed out on ${node_label} (${target_ip})"
    return 1
}

start_server() {
    local server_id=$1
    local server_ip=$2
    echo " Starting Server ${server_id} on ${server_ip} ..."

    ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$server_ip" bash <<EOF
set -e
cd "${REMOTE_DIR}"
mkdir -p "${LOG_DIR}/server${server_id}" "${EVAL_DIR}"
nohup ./${BINARY} \\
    -id=${server_id} \\
    -n=${NUM_SERVERS} \\
    -t=${THRESHOLD} \\
    -path=${CONFIG_PATH} \\
    -pd=true \\
    -role=0 \\
    -ops=${OPS} \\
    -b=${BATCHSIZE} \\
    -indep=${INDEP_RATIO} \\
    -numobjects=${NUM_OBJECTS} \\
    -bmode=${BATCH_MODE} \\
    -bcomp=${BATCH_COMPOSITION} \\
    -et=${EVAL_TYPE} \\
    -ms=${MSG_SIZE} \\
    -mload=${WORKLOAD} \\
    -mcli=${MONGO_CLIENT_NUM} \\
    -mode=${MODE} \\
    -log=${LOG_LEVEL} \\
    -max-inflight=${MAX_INFLIGHT} \
    -ep=${ENABLE_PRIORITY} \\
    -rstep=${RATIO_STEP} \\
    > "${LOG_DIR}/server${server_id}/output.log" 2>&1 &
echo "Server ${server_id} launched (PID \$!)"
EOF
}

start_client() {
    local client_id=$1
    local client_ip=$2
    echo " Starting Client ${client_id} on ${client_ip} ..."

    ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$client_ip" bash <<EOF
set -e
cd "${REMOTE_DIR}"
mkdir -p "${LOG_DIR}/client${client_id}" "${EVAL_DIR}/client${client_id}"
ENABLE_TIMESERIES="${ENABLE_TIMESERIES}" TPS_TIMELINE_INTERVAL_MS="${TPS_TIMELINE_INTERVAL_MS}" nohup ./${BINARY} \
    -id=${client_id} \\
    -n=${NUM_SERVERS} \\
    -t=${THRESHOLD} \\
    -path=${CONFIG_PATH} \\
    -ops=${OPS} \\
    -et=${EVAL_TYPE} \\
    -pd=true \\
    -role=1 \\
    -b=${BATCHSIZE} \\
    -indep=${INDEP_RATIO} \\
    -numobjects=${NUM_OBJECTS} \\
    -bmode=${BATCH_MODE} \\
    -bcomp=${BATCH_COMPOSITION} \\
    -ms=${MSG_SIZE} \\
    -mload=${WORKLOAD} \\
    -mcli=${MONGO_CLIENT_NUM} \\
    -mode=${MODE} \\
    -log=${LOG_LEVEL} \\
    -max-inflight=${MAX_INFLIGHT} \\
    -ep=${ENABLE_PRIORITY} \\
    -rstep=${RATIO_STEP} \\
    -readratio=${READ_RATIO} \\
    > "${LOG_DIR}/client${client_id}/output.log" 2>&1 &
echo "Client ${client_id} launched (PID \$!)"
EOF
}

READY_PATTERN="${READY_PATTERN:-majority:}"

wait_for_server_ready() {
    local server_id=$1
    local server_ip=$2
    local log_path="${LOG_DIR}/server${server_id}/output.log"
    local tries=0
    local max_tries=60

    # Followers (id != 0) call initMongoDB() -- which does a real MongoDB
    # load (recordcount=100000) -- *before* opening their RPC listener, so
    # "majority:" (printed at startup, before that load even begins) is
    # not a valid readiness signal for them. The leader (id 0) never
    # loads Mongo data itself, so "majority:" still works there.
    local pattern="$READY_PATTERN"
    if [ "$server_id" != "0" ]; then
        pattern="RPC server listening"
    fi

    echo " Waiting for Server ${server_id} on ${server_ip} (pattern: '${pattern}')..."
    while [ $tries -lt $max_tries ]; do
        if ! ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$server_ip" \
                "pgrep -x '${BINARY}' >/dev/null 2>&1" 2>/dev/null; then
            echo " ERROR: Server ${server_id} process exited before becoming ready."
            ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$server_ip" \
                "tail -n 50 '${log_path}' 2>/dev/null || echo '(no log)'"
            exit 1
        fi

        if ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$server_ip" \
                "test -f '${log_path}' && grep -q '${pattern}' '${log_path}'" \
                >/dev/null 2>&1; then
            echo " Server ${server_id} is ready."
            return 0
        fi

        sleep 1
        tries=$((tries + 1))
    done

    if ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$server_ip" \
            "pgrep -x '${BINARY}' >/dev/null 2>&1" 2>/dev/null; then
        echo " WARNING: Server ${server_id} ready pattern not seen after ${max_tries}s,"
        echo "          but process is running — proceeding (set READY_PATTERN/pattern to tune)."
        ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$server_ip" \
            "tail -n 10 '${log_path}' 2>/dev/null || echo '(no log)'"
        return 0
    fi

    echo " ERROR: Server ${server_id} process exited and pattern never matched."
    ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY" "$USER@$server_ip" \
        "tail -n 50 '${log_path}' 2>/dev/null || echo '(no log)'"
    exit 1
}

# ---------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------
echo "=============================================="
echo "Building Cabinet binary locally..."
echo "=============================================="
(cd "$REPO_ROOT" && go build -o "${SCRIPT_DIR}/${BINARY}")
echo " Build complete."

# ---------------------------------------------------------------
# DISTRIBUTE
# ---------------------------------------------------------------
echo "=============================================="
echo "Copying binary, config, and YCSB workload to all nodes..."
echo "=============================================="
for ip in "${SERVER_IPS[@]}" "${CLIENT_HOST_IPS[@]}"; do
    copy_binary "$ip"
    copy_config "$ip"
    sync_workload_data "$ip"
done

# ---------------------------------------------------------------
# MONGODB
# ---------------------------------------------------------------
echo "=============================================="
echo "Setting up standalone MongoDB on all servers..."
echo "=============================================="
for i in "${!SERVER_IPS[@]}"; do
    setup_mongodb "${SERVER_IPS[$i]}" "$i"
done
for i in "${!SERVER_IPS[@]}"; do
    wait_for_mongo_ready "${SERVER_IPS[$i]}" "server${i}" || true
done

# ---------------------------------------------------------------
# START SERVERS (followers first, then leader -- matches
# start_cluster_hetero.sh's proven startup choreography)
# ---------------------------------------------------------------
echo "=============================================="
echo "Starting follower servers (IDs 1 to $((NUM_SERVERS-1)))..."
echo "=============================================="
for i in $(seq 1 $((NUM_SERVERS - 1))); do
    start_server "$i" "${SERVER_IPS[$i]}"
    wait_for_server_ready "$i" "${SERVER_IPS[$i]}"
done

echo "=============================================="
echo "Starting leader server (ID 0)..."
echo "=============================================="
start_server 0 "${SERVER_IPS[0]}"
wait_for_server_ready 0 "${SERVER_IPS[0]}"

echo "Waiting 10 seconds for cluster to stabilize..."
sleep 10

# ---------------------------------------------------------------
# START CLIENTS
# ---------------------------------------------------------------
echo "=============================================="
echo "Starting ${NUM_CLIENTS} clients on MongoDB workload '$WORKLOAD'..."
echo "=============================================="
client_id="${NUM_SERVERS}"
for vm_ip in "${CLIENT_HOST_IPS[@]}"; do
    c=0
    while [ "$c" -lt "$CLIENTS_PER_VM" ]; do
        if [ "$client_id" -lt "$((NUM_SERVERS + NUM_CLIENTS))" ]; then
            start_client "$client_id" "$vm_ip"
            client_id=$((client_id + 1))
            sleep 1
        fi
        c=$((c + 1))
    done
done

echo "=============================================="
echo " Cabinet/Raft HETEROGENEOUS ${NUM_SERVERS}-NODE MONGODB CLUSTER STARTED"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Servers  : ${NUM_SERVERS} (IDs 0-$((NUM_SERVERS-1)))"
echo "  Clients  : ${NUM_CLIENTS} (IDs ${NUM_SERVERS}-$((NUM_SERVERS+NUM_CLIENTS-1)))"
echo "  Threshold: ${THRESHOLD}"
echo "  Mode     : $([ "$ENABLE_PRIORITY" = "true" ] && echo Cabinet || echo Raft)"
echo "  Config   : $(basename "$CONFIG_PATH")"
echo "  Workload : ${WORKLOAD}"
echo "  MongoDB  : standalone mongod per node (port ${MONGODB_PORT})"
echo ""
echo "Stop with: NUM_SERVERS=${NUM_SERVERS} NUM_CLIENTS=${NUM_CLIENTS} CONFIG_PATH=${CONFIG_PATH} bash ./stop_mongodb_hetero_nsel.sh"
echo "=============================================="
