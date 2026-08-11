#!/bin/bash

# ============================================
# Cabinet Quick Start Script
# ============================================
# Minimal configuration for quick testing
# 3 servers, 2 clients, 100 operations
# ============================================

echo "🚀 Cabinet Quick Start"
echo "======================"
echo ""

# Kill any existing processes
pkill -f "./cabinet" > /dev/null 2>&1 || true
sleep 1

# Clean old logs
rm -rf ./logs
mkdir -p ./logs

# Build
echo "Building..."
go build -o ./cabinet
if [ $? -ne 0 ]; then
    echo " Build failed"
    exit 1
fi
echo " Build complete"
echo ""

# Configuration
NUM_SERVERS=3
NUM_CLIENTS=2
OPS=100
BATCHSIZE=50
LOG_LEVEL="info"
# -hot/-common were removed from parameters.go (only -indep remains, plus
# -numobjects/-readratio) - flag.Parse() fatally errors on unrecognized
# flags, so this script wouldn't run at all with the old values.
INDEP_RATIO=90

echo "Starting ${NUM_SERVERS} servers and ${NUM_CLIENTS} clients..."
echo ""

# Start servers
for ((i=0; i<NUM_SERVERS; i++)); do
    mkdir -p "./logs/server${i}"
    ./cabinet \
        -id=${i} \
        -n=${NUM_SERVERS} \
        -t=1 \
        -path="./config/cluster_localhost.conf" \
        -pd=true \
        -role=0 \
        -b=${BATCHSIZE} \
        -et=0 \
        -ms=512 \
        -mode=0 \
        -log="${LOG_LEVEL}" \
        -ep=true \
        > "./logs/server${i}/output.log" 2>&1 &
    
    if [ $i -eq 0 ]; then
        echo " Leader started (Server 0)"
        sleep 2
    else
        echo " Follower started (Server ${i})"
        sleep 1
    fi
done

echo ""
echo "Waiting for connections..."
sleep 10

# Start clients
for ((i=0; i<NUM_CLIENTS; i++)); do
    client_id=$((NUM_SERVERS + i))
    mkdir -p "./logs/client${client_id}"
    ./cabinet \
        -id=${client_id} \
        -n=${NUM_SERVERS} \
        -t=1 \
        -path="./config/cluster_localhost.conf" \
        -ops=${OPS} \
        -pd=true \
        -role=1 \
        -b=${BATCHSIZE} \
        -indep=${INDEP_RATIO} \
        -et=0 \
        -ms=512 \
        -mode=0 \
        -log="${LOG_LEVEL}" \
        > "./logs/client${client_id}/output.log" 2>&1 &
    
    echo "✅ Client ${client_id} started"
    sleep 0.5
done

echo ""
echo "🎯 Running ${OPS} operations per client..."
echo ""
echo "Monitor with: tail -f ./logs/server0/output.log"
echo ""

# Wait for clients to finish
wait

echo ""
echo "✅ Complete!"
echo ""
echo "📊 View results:"
echo "  cat ./eval/*.csv"
echo ""
echo "📋 View logs:"
echo "  tail ./logs/server0/output.log"
echo ""

# Cleanup
sleep 2
pkill -f "./cabinet" > /dev/null 2>&1 || true
