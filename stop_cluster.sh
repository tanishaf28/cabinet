#!/bin/bash
# ================================================================
# Cabinet Cloud Cluster Stopper
# ================================================================
# Stops all Cabinet servers and clients across all VMs
# ================================================================

USER="ubuntu"
REMOTE_DIR="/home/ubuntu/cabinet"
LOG_DIR="~/cabinet/logs"

NODES=(
"192.168.228.176"
"192.168.228.57"
"192.168.228.200"
"192.168.228.113"
"192.168.228.54"
"192.168.228.207"
"192.168.228.150"
"192.168.228.100"
"192.168.228.55"
"192.168.228.77"
"192.168.228.144"
"192.168.228.28"
"192.168.228.143"
"192.168.228.118"
"192.168.228.84"
)

echo "=================================================="
echo " Stopping Cabinet Cloud Cluster"
echo "=================================================="

for ip in "${NODES[@]}"; do
    echo "→ Stopping Cabinet on ${ip}..."
    ssh -o StrictHostKeyChecking=no ${USER}@${ip} "bash -s" <<EOF
pkill -f cabinet || true
rm -f ${LOG_DIR}/*/pid.txt 2>/dev/null || true
EOF
    echo " Node ${ip} stopped."
done

echo ""
echo "=================================================="
echo " All Cabinet Nodes Stopped Successfully"
echo "=================================================="

