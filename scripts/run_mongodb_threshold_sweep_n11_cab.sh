#!/bin/bash
# ================================================================
# EVAL: MongoDB Failure-Threshold Sweep, n=11 (Cabinet)
#
# Sweeps THRESHOLD (t) at the fixed 11-node heterogeneous cluster, with
# INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 held fixed throughout - only t
# changes. t ranges 1..5 (floor((11-1)/2) = 5, Cabinet has a real per-run
# weighted threshold, so this side of the comparison sweeps it -- see
# run_mongodb_threshold_sweep_n11_raft.sh for Raft's counterpart, which has
# no tunable per-run threshold and instead runs once at its natural
# majority).
#
# Uses stop_mongodb_hetero_nsel.sh (not stop_cluster_hetero.sh) for
# cleanup -- stop_cluster_hetero.sh never kills mongod, which leaves
# orphaned mongod processes/lock files on the server nodes after every run.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_mongodb_hetero_nsel.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_mongodb_hetero_nsel.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"
RESULT_ROOT="${SCRIPT_DIR}/results/mongodb_threshold_sweep_n11_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
CLUSTER_ACTIVE=false
NUM_SERVERS=11
MAX_T=$(( (NUM_SERVERS - 1) / 2 ))

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
WORKLOAD="${WORKLOAD:-a}"
INDEP_RATIO_FIXED="${INDEP_RATIO_FIXED:-90}"

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_mongodb_threshold_sweep_n11_cab.sh

Sweeps failure threshold t=1..5 at the fixed n=11 heterogeneous cluster,
with INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 fixed, against the Cabinet
MongoDB cluster (start_mongodb_hetero_nsel.sh, -et=1, ENABLE_PRIORITY=true).

Environment overrides:
  RUNTIME_SECONDS=30           wall-clock seconds per run
  WORKLOAD=a                   YCSB workload letter (a-f)
  INDEP_RATIO_FIXED=90         fixed indep ratio for every case

Results archived under: results/mongodb_threshold_sweep_n11_cab/<timestamp>/<label>/
EOF
    exit 0
fi

mkdir -p "$RUN_DIR"
touch "${RUN_DIR}/.run_start_marker"
touch "${RUN_DIR}/.last_archive_ts"

cleanup_all_nodes() {
    echo "=================================================="
    echo " Pre-sweep cleanup: purging stale cabinet/mongod processes..."
    echo "=================================================="
    mapfile -t all_ips < <(awk 'NF >= 2 { print $2 }' "${REPO_ROOT}/config/cluster_hetero_11n_4s_7w.conf")
    for ip in "${all_ips[@]}"; do
        ssh -o ConnectTimeout=5 -i "$SSH_KEY" "$USER@$ip" "pkill -9 -x cabinet 2>/dev/null; pkill -9 -x mongod 2>/dev/null" &
    done
    wait
}

archive_latest_result() {
    local label=$1
    local dest_dir="${RUN_DIR}/${label}/merged"
    mkdir -p "$dest_dir"
    local marker="${RUN_DIR}/.last_archive_ts"
    local find_args=()
    if [ -f "$marker" ]; then
        find_args=(-newer "$marker")
    fi

    local merged_dir="${SCRIPT_DIR}/eval/merged"
    if [ -d "$merged_dir" ]; then
        find "$merged_dir" -maxdepth 1 -name "*.csv" "${find_args[@]}" \
            -exec cp {} "$dest_dir/" \; 2>/dev/null || true
        if [ -z "$(ls "$dest_dir"/*.csv 2>/dev/null)" ]; then
            cp "$merged_dir"/*.csv "$dest_dir/" 2>/dev/null || true
        fi
    fi
    touch "$marker"
    echo "  Archived results to: $dest_dir"
}

run_case() {
    local label=$1
    local t=$2

    echo ""
    echo "=================================================="
    echo "Running: $label"
    echo "  n=${NUM_SERVERS}  t=${t}  indep=${INDEP_RATIO_FIXED}  workload=${WORKLOAD}  runtime=${RUNTIME_SECONDS}s"
    echo "=================================================="

    CLUSTER_ACTIVE=true
    NUM_SERVERS="$NUM_SERVERS" THRESHOLD="$t" INDEP_RATIO="$INDEP_RATIO_FIXED" BATCHSIZE=1 MSG_SIZE=512 \
        NUM_OBJECTS=1000 READ_RATIO=0 ENABLE_PRIORITY=true \
        bash "$START_SCRIPT" "$WORKLOAD"
    sleep "$RUNTIME_SECONDS"
    NUM_SERVERS="$NUM_SERVERS" bash "$STOP_SCRIPT"
    CLUSTER_ACTIVE=false
    archive_latest_result "$label"

    echo "  Cooling down to release TCP ports..."
    sleep 5
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        NUM_SERVERS="$NUM_SERVERS" bash "$STOP_SCRIPT" || true
    fi
}
trap cleanup EXIT

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       CABINET MONGODB THRESHOLD SWEEP, n=11 (t=1..5)             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

cleanup_all_nodes

for ((t = 1; t <= MAX_T; t++)); do
    run_case "n11_mongo_t${t}" "$t"
done

echo ""
echo "Extracting throughput/latency summary..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system cabinet

echo ""
echo "=================================================="
echo " Cabinet MongoDB threshold sweep (n=11) complete"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
echo "Summary CSV: $RUN_DIR/extracted_metrics.csv"
