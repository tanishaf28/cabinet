#!/bin/bash
# ================================================================
# Cabinet Cloud Cluster Stopper - HETEROGENEOUS CLUSTER (FIXED)
# ================================================================

set -euo pipefail

USER="ubuntu"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
BINARY_NAME="cabinet"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LOCAL_EVAL_DIR="${REPO_ROOT}/eval"
MERGED_DIR="${LOCAL_EVAL_DIR}/merged"
MERGE_SCRIPT="${REPO_ROOT}/merge_eval.py"
REMOTE_EVAL_DIR="/home/ubuntu/cabinet/eval"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ${SSH_KEY}"

# FIX: define NUM_SERVERS here so client IDs are derived correctly.
# If stop script is called standalone, this must match what start used.
NUM_SERVERS="${NUM_SERVERS:-5}"
NUM_CLIENTS="${NUM_CLIENTS:-2}"

# Must resolve to the same per-size config file start_cluster_hetero.sh used,
# so the IPs we SSH into to stop processes match the IPs that were started.
case "$NUM_SERVERS" in
    3)  DEFAULT_HETERO_CONFIG="cluster_hetero_3n_10c.conf" ;;
    5)  DEFAULT_HETERO_CONFIG="cluster_hetero_5n_10c.conf" ;;
    7)  DEFAULT_HETERO_CONFIG="cluster_hetero_7n_10c.conf" ;;
    11) DEFAULT_HETERO_CONFIG="cluster_hetero_11n_10c.conf" ;;
    *)
        echo " ERROR: no heterogeneous config for NUM_SERVERS=${NUM_SERVERS}. Supported sizes: 3, 5, 7, 11." >&2
        exit 1
        ;;
esac
CONFIG_PATH="${CONFIG_PATH:-${REPO_ROOT}/config/${DEFAULT_HETERO_CONFIG}}"

mapfile -t ALL_IPS < <(awk 'NF >= 2 { print $2 }' "$CONFIG_PATH")
if [ "${#ALL_IPS[@]}" -lt "$NUM_SERVERS" ]; then
    echo " ERROR: ${CONFIG_PATH} does not contain enough IPs for ${NUM_SERVERS} servers" >&2
    exit 1
fi
SERVER_IPS=("${ALL_IPS[@]:0:NUM_SERVERS}")
CLIENT_POOL_IPS=("${ALL_IPS[@]:NUM_SERVERS}")
CLIENT_IPS=()
if [ "${#CLIENT_POOL_IPS[@]}" -gt 0 ]; then
    # Mirrors start_cluster_hetero.sh: cycle through the client portion of
    # the pool so NUM_CLIENTS > available client IPs (matched mode at
    # n=11) maps each client_id back to the VM it was actually launched on.
    for ((k = 0; k < NUM_CLIENTS; k++)); do
        CLIENT_IPS+=("${CLIENT_POOL_IPS[$((k % ${#CLIENT_POOL_IPS[@]}))]}")
    done
fi

# FIX: derive client ID range from NUM_SERVERS instead of hardcoding 5
CLIENT_ID_START="${NUM_SERVERS}"
CLIENT_IDS_FILTER="${CLIENT_IDS_FILTER:-${CLIENT_ID_START}-$((CLIENT_ID_START + NUM_CLIENTS - 1))}"

# ---------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------
stop_on_node() {
    local ip=$1
    local role=$2

    echo ""
    echo "→ Stopping ${role} on ${ip}"

    if [ "$role" = "client" ]; then
        ssh ${SSH_OPTS} "$USER@$ip" \
            "pkill -INT -x ${BINARY_NAME} 2>/dev/null || true" || true
        echo "  Waiting up to 35s for client graceful shutdown..."
        local t=0
        while [ $t -lt 35 ]; do
            if ! ssh ${SSH_OPTS} "$USER@$ip" \
                    "pgrep -x ${BINARY_NAME} >/dev/null 2>&1" 2>/dev/null; then
                break
            fi
            sleep 1
            t=$((t + 1))
        done

        if ssh ${SSH_OPTS} "$USER@$ip" \
                "pgrep -x ${BINARY_NAME} >/dev/null 2>&1" 2>/dev/null; then
            echo "  Still running → Sending SIGTERM"
            ssh ${SSH_OPTS} "$USER@$ip" \
                "pkill -TERM -x ${BINARY_NAME} 2>/dev/null || true" || true
            sleep 5
        fi
    else
        ssh ${SSH_OPTS} "$USER@$ip" \
            "pkill -TERM -x ${BINARY_NAME} 2>/dev/null || true" || true
        echo "  Waiting up to 20s for server shutdown..."
        local t=0
        while [ $t -lt 20 ]; do
            if ! ssh ${SSH_OPTS} "$USER@$ip" \
                    "pgrep -x ${BINARY_NAME} >/dev/null 2>&1" 2>/dev/null; then
                break
            fi
            sleep 1
            t=$((t + 1))
        done
    fi

    # Force-kill if still running
    if ssh ${SSH_OPTS} "$USER@$ip" \
            "pgrep -x ${BINARY_NAME} >/dev/null 2>&1" 2>/dev/null; then
        echo "  Still running → SIGKILL"
        ssh ${SSH_OPTS} "$USER@$ip" \
            "pkill -9 -x ${BINARY_NAME} 2>/dev/null || true" || true
        sleep 1
    fi

    if ssh ${SSH_OPTS} "$USER@$ip" \
            "pgrep -x ${BINARY_NAME} >/dev/null 2>&1" 2>/dev/null; then
        echo "  WARNING: ${role} still active on ${ip}"
    else
        echo "   ${role} on ${ip} stopped"
    fi
}

copy_eval_dir() {
    local ip=$1
    local remote_subdir=$2

    if ssh ${SSH_OPTS} "$USER@$ip" \
            "test -d '${REMOTE_EVAL_DIR}/${remote_subdir}'" >/dev/null 2>&1; then
        echo " Collecting ${USER}@${ip}:${REMOTE_EVAL_DIR}/${remote_subdir}"
        scp -q ${SSH_OPTS} -r \
            "$USER@$ip:${REMOTE_EVAL_DIR}/${remote_subdir}" \
            "${LOCAL_EVAL_DIR}/" 2>/dev/null || true
        # Source is now safely copied -- clear it so it doesn't keep
        # accumulating every historical case's CSVs forever.
        ssh ${SSH_OPTS} "$USER@$ip" \
            "rm -f '${REMOTE_EVAL_DIR}/${remote_subdir}'/*.csv" >/dev/null 2>&1 || true
    else
        echo " WARNING: Missing remote dir ${REMOTE_EVAL_DIR}/${remote_subdir} on ${ip}"
    fi
}

# ---------------------------------------------------------------
# STEP 1 — STOP CLIENTS (parallel)
# ---------------------------------------------------------------
echo "=================================================="
echo " Cabinet HETEROGENEOUS Cluster Shutdown"
echo " Clients then Servers"
echo "=================================================="

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " STEP 1: Stopping Clients (${#CLIENT_IPS[@]} nodes)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for ip in "${CLIENT_IPS[@]}"; do
    stop_on_node "$ip" client &
done
wait

echo ""
echo "Waiting 5 seconds for servers to flush metrics..."
sleep 5

# ---------------------------------------------------------------
# STEP 2 — STOP SERVERS (parallel)
# ---------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " STEP 2: Stopping Servers (${#SERVER_IPS[@]} nodes)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for ip in "${SERVER_IPS[@]}"; do
    stop_on_node "$ip" server &
done
wait

# ---------------------------------------------------------------
# VERIFICATION
# ---------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
any_left=false
verify_dir=$(mktemp -d)
for ip in "${SERVER_IPS[@]}" "${CLIENT_IPS[@]}"; do
    (
        if ssh ${SSH_OPTS} "$USER@$ip" \
                "pgrep -x ${BINARY_NAME} >/dev/null 2>&1" 2>/dev/null; then
            count=$(ssh ${SSH_OPTS} "$USER@$ip" \
                "pgrep -x ${BINARY_NAME} 2>/dev/null | wc -l" | tr -d ' \n' || echo 0)
            echo "$count" > "${verify_dir}/${ip}"
        fi
    ) &
done
wait
for f in "${verify_dir}"/*; do
    [ -f "$f" ] || continue
    ip=$(basename "$f")
    echo " ${ip}: $(cat "$f") process(es) STILL running"
    any_left=true
done
rm -rf "$verify_dir"

if [ "$any_left" = false ]; then
    echo " All Cabinet processes stopped."
else
    echo " Some processes remain — use manual pkill if needed."
fi

# ---------------------------------------------------------------
# COLLECT + MERGE EVAL CSVs
# ---------------------------------------------------------------
echo ""
echo "=================================================="
echo " Collecting and merging eval CSVs"
echo "=================================================="

mkdir -p "${LOCAL_EVAL_DIR}" "${MERGED_DIR}"
# Clean up previous run's collected dirs so merge isn't polluted
rm -rf "${LOCAL_EVAL_DIR}"/client* "${LOCAL_EVAL_DIR}"/server* 2>/dev/null || true

echo "→ Collecting client CSVs..."
# FIX: use NUM_SERVERS to compute the first client ID, not hardcoded 5
for idx in "${!CLIENT_IPS[@]}"; do
    client_id=$((CLIENT_ID_START + idx))
    copy_eval_dir "${CLIENT_IPS[$idx]}" "client${client_id}" &
done
wait

echo ""
echo "Client timeline CSV collection check:"
for idx in "${!CLIENT_IPS[@]}"; do
    client_id=$((CLIENT_ID_START + idx))
    if ls "${LOCAL_EVAL_DIR}/client${client_id}"/tps_timeline_*.csv >/dev/null 2>&1; then
        echo " client${client_id}: timeline CSV found"
    else
        echo " WARNING: client${client_id}: no timeline CSV found"
    fi
done

echo "→ Collecting server CSVs (leader only)..."
copy_eval_dir "${SERVER_IPS[0]}" "server0"

if [ ! -f "${MERGE_SCRIPT}" ]; then
    echo " WARNING: merge_eval.py not found at ${MERGE_SCRIPT} — skipping merge"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo " WARNING: python3 not available — skipping merge"
    exit 0
fi

echo "→ Running: python3 ${MERGE_SCRIPT} ${LOCAL_EVAL_DIR} ${MERGED_DIR}/ --ids ${CLIENT_IDS_FILTER}"
if python3 "${MERGE_SCRIPT}" "${LOCAL_EVAL_DIR}" "${MERGED_DIR}/" --ids "${CLIENT_IDS_FILTER}"; then
    echo " ✓ Client merge complete. Output in ${MERGED_DIR}/"
else
    echo " ✗ Client merge failed."
fi

echo "→ Running: python3 ${MERGE_SCRIPT} ${LOCAL_EVAL_DIR} ${MERGED_DIR}/ --servers --ids 0-$((NUM_SERVERS - 1))"
if python3 "${MERGE_SCRIPT}" "${LOCAL_EVAL_DIR}" "${MERGED_DIR}/" --servers --ids "0-$((NUM_SERVERS - 1))"; then
    echo " ✓ Server merge complete. Output in ${MERGED_DIR}/"
else
    echo " ✗ Server merge failed."
fi

echo ""
echo "=================================================="
echo " HETEROGENEOUS CLUSTER SHUTDOWN COMPLETE"
echo "=================================================="