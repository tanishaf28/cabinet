#!/bin/bash
# ================================================================
# Cabinet Cloud Cluster Launcher (Updated for current .go parameters)
# ================================================================

set -e
trap 'echo " Script interrupted. Exiting..."; exit 1' INT

# -----------------------------
# CONFIGURATION
# -----------------------------
USER="ubuntu"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
REMOTE_DIR="/home/ubuntu/cabinet"
BINARY="cabinet"
CONFIG_PATH="./config/cluster_localhost.conf"
LOG_DIR="/home/ubuntu/cabinet/logs"
EVAL_DIR="/home/ubuntu/cabinet/eval"

# -----------------------------
# CABINET PARAMETERS
# -----------------------------
NUM_SERVERS=5
NUM_CLIENTS=2
THRESHOLD=1
OPS=0                  # Infinite mode
EVAL_TYPE=0            # 0=plain msg
BATCHSIZE=10
MSG_SIZE=512
LOG_LEVEL="info"
ENABLE_PRIORITY="true"
RATIO_STEP=0.001

# Object ratios
HOT_RATIO=0
INDEP_RATIO=50
COMMON_RATIO=50
BATCH_MODE="single"   # single or round-robin
BATCH_COMPOSITION="object-specific"
MODE=1  # 0=localhost, 1=distributed

# -----------------------------
# IP LIST
# -----------------------------
SERVER_IPS=(
"192.168.228.176" "192.168.228.57" "192.168.228.200" "192.168.228.113" "192.168.228.54"
)
CLIENT_IPS=(
"192.168.228.207" "192.168.228.150"
)

# -----------------------------
# COPY BINARY TO REMOTE VM
# -----------------------------
copy_binary() {
    local SERVER_IP=$1
    echo " Copying binary to $SERVER_IP ..."
    scp -i $SSH_KEY "$BINARY" $USER@$SERVER_IP:$REMOTE_DIR/
}

# -----------------------------
# START SERVER FUNCTION
# -----------------------------
start_server() {
    local SERVER_ID=$1
    local SERVER_IP=$2
    echo " Starting Server $SERVER_ID on $SERVER_IP ..."

    ssh -i $SSH_KEY $USER@$SERVER_IP "
        cd $REMOTE_DIR
        mkdir -p ${LOG_DIR}/server${SERVER_ID} ${EVAL_DIR}
        nohup ./$BINARY \
            -id=${SERVER_ID} \
            -n=${NUM_SERVERS} \
            -t=${THRESHOLD} \
            -path=${CONFIG_PATH} \
            -pd=true \
            -role=0 \
            -ops=${OPS} \
            -b=${BATCHSIZE} \
            -hot=${HOT_RATIO} \
            -indep=${INDEP_RATIO} \
            -common=${COMMON_RATIO} \
            -bmode=${BATCH_MODE} \
            -bcomp=${BATCH_COMPOSITION} \
            -et=${EVAL_TYPE} \
            -ms=${MSG_SIZE} \
            -mode=${MODE} \
            -log=${LOG_LEVEL} \
            -ep=${ENABLE_PRIORITY} \
            -rstep=${RATIO_STEP} \
            > ${LOG_DIR}/server${SERVER_ID}/output.log 2>&1 &
    "
}

# -----------------------------
# START CLIENT FUNCTION
# -----------------------------
start_client() {
    local CLIENT_ID=$1
    local CLIENT_IP=$2
    echo " Starting Client $CLIENT_ID on $CLIENT_IP ..."

    ssh -i $SSH_KEY $USER@$CLIENT_IP "
        cd $REMOTE_DIR
        mkdir -p ${LOG_DIR}/client${CLIENT_ID} ${EVAL_DIR}
        nohup ./$BINARY \
            -id=${CLIENT_ID} \
            -n=${NUM_SERVERS} \
            -t=${THRESHOLD} \
            -path=${CONFIG_PATH} \
            -ops=${OPS} \
            -et=${EVAL_TYPE} \
            -pd=true \
            -role=1 \
            -b=${BATCHSIZE} \
            -hot=${HOT_RATIO} \
            -indep=${INDEP_RATIO} \
            -common=${COMMON_RATIO} \
            -bmode=${BATCH_MODE} \
            -bcomp=${BATCH_COMPOSITION} \
            -ms=${MSG_SIZE} \
            -mode=${MODE} \
            -log=${LOG_LEVEL} \
            -ep=${ENABLE_PRIORITY} \
            -rstep=${RATIO_STEP} \
            > ${LOG_DIR}/client${CLIENT_ID}/output.log 2>&1 &
    "
}

# -----------------------------
# BUILD CABINET BINARY LOCALLY
# -----------------------------
echo "=============================================="
echo "Building Cabinet binary..."
echo "=============================================="
cd ${REMOTE_DIR}
go build -o "$BINARY"
echo " Build complete."

# -----------------------------
# COPY BINARY TO ALL VMS
# -----------------------------
echo "=============================================="
echo "Copying binary to all remote servers and clients..."
echo "=============================================="
for ip in "${SERVER_IPS[@]}" "${CLIENT_IPS[@]}"; do
    copy_binary $ip
done

# -----------------------------
# START SERVERS
# -----------------------------
echo "=============================================="
echo "Starting all servers..."
echo "=============================================="
for i in "${!SERVER_IPS[@]}"; do
    start_server $i "${SERVER_IPS[$i]}"
    if [ $i -eq 0 ]; then
        echo " Waiting 3 seconds for leader to initialize..."
        sleep 3
    else
        sleep 1
    fi
done

echo "Waiting 15 seconds for servers to stabilize..."
sleep 15

# -----------------------------
# START CLIENTS
# -----------------------------
echo "=============================================="
echo "Starting all clients..."
echo "=============================================="
for i in "${!CLIENT_IPS[@]}"; do
    client_id=$((${#SERVER_IPS[@]} + i))
    start_client $client_id "${CLIENT_IPS[$i]}"
    sleep 1
done

echo "=============================================="
echo " Cabinet cluster startup commands sent successfully!"
echo "=============================================="
echo "Monitor logs via SSH on each VM:"
echo "  tail -f /home/ubuntu/cabinet/logs/server0/output.log"
echo "  tail -f /home/ubuntu/cabinet/logs/client5/output.log"
echo ""
echo "To stop all processes:"
echo "  pkill -f cabinet"
echo "=============================================="

