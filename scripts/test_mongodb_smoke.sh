#!/bin/bash
# ================================================================
# MongoDB Smoke Test (Cabinet)
#
# A fast, minimal sanity check that the whole MongoDB pipeline actually
# works end-to-end - NOT a performance eval. Run this before committing to
# any of the multi-hour ratio/threshold/batch/delay/workload sweeps, to
# catch fundamental breakage cheaply (wrong config path, mongod failing to
# start, Cabinet never connecting to Mongo, zero documents actually
# written, etc.) in under a minute instead of discovering it 20 cases into
# a sweep. Mirrors woc/scripts/test_mongodb_smoke.sh and
# epaxos/scripts/test_mongodb_smoke.sh.
#
# Runs in Cabinet mode (ENABLE_PRIORITY=true) by default - pass
# ENABLE_PRIORITY=false to smoke-test the Raft path instead (same binary,
# same MongoDB plumbing, only the consensus weighting differs, so a single
# script covers both; only the failure THRESHOLD default differs between
# the two, computed below).
#
# What it checks, beyond "the script didn't crash":
#   1. mongod is actually reachable on every server (mongosh ping).
#   2. Server logs free of MongoDB connection/apply error strings.
#   3. At least one document was actually written to each server's local
#      MongoDB (queried directly via mongosh, not inferred from client-
#      reported throughput).
#   4. Client(s) show logged batch activity (soft pre-check).
#   5. The merged client CSV actually has data rows, not just a header -
#      the authoritative check.
#
# Uses the smallest/fastest cluster (n=3) and a short runtime (15s) - this
# is deliberately not a real workload measurement.
# ================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_mongodb_hetero_nsel.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_mongodb_hetero_nsel.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"
REMOTE_DIR="/home/ubuntu/cabinet"

NUM_SERVERS=3
RUNTIME_SECONDS="${RUNTIME_SECONDS:-15}"
WORKLOAD="${WORKLOAD:-a}"
ENABLE_PRIORITY="${ENABLE_PRIORITY:-true}"
if [ "$ENABLE_PRIORITY" = "true" ]; then
    THRESHOLD="${THRESHOLD:-1}"
    MODE_LABEL="Cabinet"
else
    THRESHOLD="${THRESHOLD:-$(( (NUM_SERVERS - 1) / 2 ))}"
    MODE_LABEL="Raft"
fi
CLUSTER_ACTIVE=false
FAILURES=0

ssh_q() {
    local host=$1
    shift
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "$SSH_KEY" "$USER@$host" "$*"
}

fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "  [ OK ] $1"
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        echo ""
        echo "Cleaning up test cluster..."
        NUM_SERVERS="$NUM_SERVERS" bash "$STOP_SCRIPT" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║      CABINET MONGODB SMOKE TEST (${MODE_LABEL}, n=3, ~30s total)"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

echo "Starting minimal cluster (n=${NUM_SERVERS}, mode=${MODE_LABEL}, t=${THRESHOLD}, workload=${WORKLOAD}, runtime=${RUNTIME_SECONDS}s)..."
CLUSTER_ACTIVE=true
if ! NUM_SERVERS="$NUM_SERVERS" NUM_CLIENTS=2 THRESHOLD="$THRESHOLD" ENABLE_PRIORITY="$ENABLE_PRIORITY" \
    INDEP_RATIO=90 BATCHSIZE=1 NUM_OBJECTS=100 READ_RATIO=0 \
    bash "$START_SCRIPT" "$WORKLOAD"; then
    fail "start_mongodb_hetero_nsel.sh exited non-zero - cluster may not have come up at all"
fi

echo ""
echo "Letting the cluster run for ${RUNTIME_SECONDS}s..."
sleep "$RUNTIME_SECONDS"

echo ""
echo "=================================================="
echo " CHECK 1: mongod reachable on every server"
echo "=================================================="
mapfile -t SERVER_IPS < <(awk 'NF >= 2 { print $2 }' "${REPO_ROOT}/config/cluster_hetero_3n_2s_1w.conf" | head -n "$NUM_SERVERS")
for i in "${!SERVER_IPS[@]}"; do
    ip="${SERVER_IPS[$i]}"
    if ssh_q "$ip" "mongosh --quiet --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1"; then
        pass "server${i} (${ip}): mongod responds to ping"
    else
        fail "server${i} (${ip}): mongod did NOT respond to ping"
    fi
done

echo ""
echo "=================================================="
echo " CHECK 2: server logs free of MongoDB connection/apply errors"
echo "=================================================="
for i in "${!SERVER_IPS[@]}"; do
    ip="${SERVER_IPS[$i]}"
    err_count=$(ssh_q "$ip" "grep -icE 'mongo.*(failed|not initialized)|(failed|error).*mongo' '${REMOTE_DIR}/logs/server_${i}.log' 2>/dev/null || true")
    err_count=$(echo "$err_count" | tr -d ' \n')
    if [ "${err_count:-0}" -eq 0 ] 2>/dev/null; then
        pass "server${i}: no MongoDB error strings in log"
    else
        fail "server${i}: found ${err_count} MongoDB error line(s) in ${REMOTE_DIR}/logs/server_${i}.log"
    fi
done

echo ""
echo "=================================================="
echo " CHECK 3: documents actually present in each server's local MongoDB"
echo "=================================================="
for i in "${!SERVER_IPS[@]}"; do
    ip="${SERVER_IPS[$i]}"
    # dbName convention from conns.go's initMongoDB: unlike WOC/EPaxos,
    # Cabinet ALWAYS suffixes the db name by server ID regardless of mode
    # ("Use server ID as DB suffix in all modes to avoid collisions across
    # replicas") - server 0 uses "ycsb", every other server uses
    # "ycsb<serverID>". Cosmetic difference from WOC/EPaxos's uniform
    # "ycsb" everywhere, not a correctness requirement either way: every
    # server here runs its own independent mongod on its own VM/disk (no
    # replica set anywhere in this architecture), so there's no actual
    # cross-server collision risk regardless of naming - each server never
    # sees another server's data either way.
    if [ "$i" -eq 0 ]; then
        dbname="ycsb"
    else
        dbname="ycsb${i}"
    fi
    count=$(ssh_q "$ip" "mongosh --quiet '${dbname}' --eval 'db.usertable.countDocuments({})' 2>/dev/null" | tr -dc '0-9')
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        pass "server${i} (db=${dbname}): usertable has ${count} document(s)"
    else
        fail "server${i} (db=${dbname}): usertable has 0 documents (or query failed)"
    fi
done

echo ""
echo "=================================================="
echo " CHECK 4: client(s) show logged batch activity"
echo "=================================================="
# Soft pre-check only - Cabinet's client success log format is
# "[LATENCY-BREAKDOWN] Client %d | Batch %d | size=..." (note: pipe, not a
# closing bracket, between "Client N" and "Batch" - different from
# WOC/EPaxos's "[Client N] Batch..."). CHECK 5 (merged CSV) is
# authoritative.
mapfile -t CLIENT_IPS < <(awk 'NF >= 2 { print $2 }' "${REPO_ROOT}/config/cluster_hetero_3n_2s_1w.conf" | tail -n +$((NUM_SERVERS + 1)))
for i in "${!CLIENT_IPS[@]}"; do
    ip="${CLIENT_IPS[$i]}"
    client_id=$((NUM_SERVERS + i))
    if ssh_q "$ip" "grep -Eq 'Client [0-9]+ \| Batch' '${REMOTE_DIR}/logs/client_${i}.log' 2>/dev/null"; then
        pass "client${client_id}: batch activity logged"
    else
        echo "  [WARN] client${client_id}: no batch log lines yet (normal for a short run) - deferring to CHECK 5"
    fi
done

echo ""
echo "Stopping cluster and collecting/merging results..."
NUM_SERVERS="$NUM_SERVERS" bash "$STOP_SCRIPT" >/dev/null 2>&1 || true
CLUSTER_ACTIVE=false

echo ""
echo "=================================================="
echo " CHECK 5: merged client CSV has nonzero data rows"
echo "=================================================="
merged_dir="${SCRIPT_DIR}/eval/merged"
found_data=false
if [ -d "$merged_dir" ]; then
    for f in "$merged_dir"/*.csv; do
        [ -e "$f" ] || continue
        lines=$(wc -l < "$f" | tr -d ' ')
        if [ "$lines" -gt 1 ]; then
            pass "$(basename "$f"): ${lines} lines (header + data)"
            found_data=true
        else
            echo "  [WARN] $(basename "$f"): only ${lines} line(s) (header only, no data rows)"
        fi
    done
fi
if [ "$found_data" = false ]; then
    fail "no merged CSV with actual data rows found in ${merged_dir}"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
if [ "$FAILURES" -eq 0 ]; then
    echo "║  RESULT: PASS - MongoDB pipeline looks functional                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    exit 0
else
    echo "║  RESULT: FAIL - ${FAILURES} check(s) failed, see above              ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    exit 1
fi
