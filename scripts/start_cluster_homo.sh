#!/bin/bash
# ================================================================
# Cabinet Cloud Cluster Launcher - HOMOGENEOUS CLUSTER
# ================================================================

set -euo pipefail
trap 'echo " Script interrupted. Exiting..."; exit 1' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

USER="ubuntu"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
REMOTE_DIR="/home/ubuntu/cabinet"
BINARY="cabinet"
CONFIG_PATH="${CONFIG_PATH:-${REPO_ROOT}/config/cluster_homo.conf}"
LOG_DIR="${REMOTE_DIR}/logs"
EVAL_DIR="${REMOTE_DIR}/eval"

# All vars overridable via env (used by run_homo_plainmsg_evals.sh)
NUM_SERVERS="${NUM_SERVERS:-5}"
NUM_CLIENTS="${NUM_CLIENTS:-2}"
THRESHOLD="${THRESHOLD:-1}"
OPS="${OPS:-0}"
EVAL_TYPE="${EVAL_TYPE:-0}"
BATCHSIZE="${BATCHSIZE:-1}"
MSG_SIZE="${MSG_SIZE:-512}"
MODE="${MODE:-1}"
INDEP_RATIO="${INDEP_RATIO:-90}"
NUM_OBJECTS="${NUM_OBJECTS:-1000}"
BATCH_MODE="${BATCH_MODE:-single}"
BATCH_COMPOSITION="${BATCH_COMPOSITION:-object-specific}"
RATIO_STEP="${RATIO_STEP:-0.001}"
LOG_LEVEL="${LOG_LEVEL:-info}"
ENABLE_PRIORITY="${ENABLE_PRIORITY:-true}"
MAX_INFLIGHT="${MAX_INFLIGHT:-5}"
READ_RATIO="${READ_RATIO:-0}"

# The homogeneous pool (config/cluster_homo.conf) is one flat IP list:
# the first NUM_SERVERS entries are servers, the rest are clients.
mapfile -t ALL_IPS < <(awk 'NF >= 2 { print $2 }' "$CONFIG_PATH")
if [ "${#ALL_IPS[@]}" -lt "$NUM_SERVERS" ]; then
    echo " ERROR: ${CONFIG_PATH} does not contain enough IPs for ${NUM_SERVERS} servers"
    exit 1
fi
SERVER_IPS=("${ALL_IPS[@]:0:NUM_SERVERS}")
CLIENT_POOL_IPS=("${ALL_IPS[@]:NUM_SERVERS}")
if [ "${#CLIENT_POOL_IPS[@]}" -eq 0 ]; then
    echo " ERROR: ${CONFIG_PATH} does not contain any client IPs" >&2
    exit 1
fi
# Cycle through the client portion of the pool (rather than a plain slice)
# so NUM_CLIENTS > available client IPs (e.g. a 50-client scaling sweep, or
# matched mode at n=11) packs extra client processes onto already-used VMs
# instead of erroring out or coming up short.
CLIENT_HOST_IPS=()
for ((k = 0; k < NUM_CLIENTS; k++)); do
    CLIENT_HOST_IPS+=("${CLIENT_POOL_IPS[$((k % ${#CLIENT_POOL_IPS[@]}))]}")
done

CLIENTS_PER_VM=1

copy_binary() {
    local target_ip=$1
    echo " Copying binary to $target_ip..."
    scp -i "$SSH_KEY" "${SCRIPT_DIR}/${BINARY}" "$USER@$target_ip:$REMOTE_DIR/"
}

copy_config() {
    local target_ip=$1
    ssh -i "$SSH_KEY" "$USER@$target_ip" "mkdir -p '${REMOTE_DIR}/config'"
    scp -i "$SSH_KEY" "$CONFIG_PATH" "$USER@$target_ip:${REMOTE_DIR}/config/"
}

start_server() {
    local server_id=$1
    local server_ip=$2
    echo " Starting Server ${server_id} on ${server_ip} ..."

    ssh -i "$SSH_KEY" "$USER@$server_ip" bash <<EOF
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
    -mode=${MODE} \\
    -log=${LOG_LEVEL} \\
    -max-inflight=${MAX_INFLIGHT} \\
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

    ssh -i "$SSH_KEY" "$USER@$client_ip" bash <<EOF
set -e
cd "${REMOTE_DIR}"
mkdir -p "${LOG_DIR}/client${client_id}" "${EVAL_DIR}/client${client_id}"
ENABLE_TIMESERIES="${ENABLE_TIMESERIES:-false}" TPS_TIMELINE_INTERVAL_MS="${TPS_TIMELINE_INTERVAL_MS:-500}" nohup ./${BINARY} \\
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

echo "=============================================="
echo "Building Cabinet binary locally..."
echo "=============================================="
(cd "$REPO_ROOT" && go build -o "${SCRIPT_DIR}/${BINARY}")
echo " Build complete."

echo "=============================================="
echo "Copying binary and config to all nodes..."
echo "=============================================="
for ip in "${SERVER_IPS[@]}" "${CLIENT_HOST_IPS[@]}"; do
    copy_binary "$ip"
    copy_config "$ip"
done

echo "=============================================="
echo "Starting all servers (Homogeneous Cluster)..."
echo "=============================================="
for i in "${!SERVER_IPS[@]}"; do
    start_server "$i" "${SERVER_IPS[$i]}"
    sleep 1
done

echo "Waiting 15 seconds for cluster stabilization..."
sleep 15

echo "=============================================="
echo "Starting ${NUM_CLIENTS} clients (${CLIENTS_PER_VM} per VM)..."
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
echo " Cabinet homogeneous cluster launched successfully!"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Cluster Type: HOMOGENEOUS"
echo "  Servers: ${NUM_SERVERS} (IDs 0-$((NUM_SERVERS-1)))"
echo "  Clients: ${NUM_CLIENTS} (IDs ${NUM_SERVERS}-$((NUM_SERVERS+NUM_CLIENTS-1)))"
echo "  Config   : $(basename "$CONFIG_PATH")"
echo ""
echo "Monitor logs:"
echo "  ssh -i $SSH_KEY ubuntu@${SERVER_IPS[0]} 'tail -f ${LOG_DIR}/server0/output.log'"
echo "  ssh -i $SSH_KEY ubuntu@${CLIENT_HOST_IPS[0]} 'tail -f ${LOG_DIR}/client${NUM_SERVERS}/output.log'"
echo ""
echo "Stop all processes:"
echo "  ./stop_cluster_homo.sh"
echo "=============================================="
