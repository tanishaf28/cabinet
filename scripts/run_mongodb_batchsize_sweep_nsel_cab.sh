#!/bin/bash
# ================================================================
# EVAL: MongoDB Batch Size Sweep x Cluster Size (Cabinet)
#
# Sweeps BATCHSIZE over 1,10,50,100,500,1000,2000 (same points/format as
# run_hetero_batchsize_sweep_10c_cab.sh's plain-msg sweep) with
# INDEP_RATIO=90, MSG_SIZE=512 fixed, for each cluster size in
# CLUSTER_SIZES (default 3,5,7,11), against the MongoDB-backed cluster
# (start_mongodb_hetero_nsel.sh/stop_mongodb_hetero_nsel.sh, -et=1).
#
# THRESHOLD fixed at 1 across all cluster sizes -- Cabinet's quorum
# tolerance isn't tied to n the way Raft's is (same convention as
# run_mongodb_ratio_sweep_nsel_cab.sh). See the sibling
# run_mongodb_batchsize_sweep_nsel_raft.sh for the Raft-mode counterpart,
# which scales THRESHOLD as floor((n-1)/2).
#
# Uses stop_mongodb_hetero_nsel.sh (not stop_cluster_hetero.sh) for
# cleanup -- stop_cluster_hetero.sh never kills mongod, which leaves
# orphaned mongod processes/lock files on the server nodes after every
# run (see stop_mongodb_hetero_nsel.sh's own header for the full story).
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_mongodb_hetero_nsel.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_mongodb_hetero_nsel.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"
RESULT_ROOT="${SCRIPT_DIR}/results/mongodb_batchsize_sweep_nsel_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
CLUSTER_ACTIVE=false

ALL_CLUSTER_SIZES=(3 5 7 11)
if [ -n "${CLUSTER_SIZES:-}" ]; then
    read -r -a ALL_CLUSTER_SIZES <<< "$CLUSTER_SIZES"
fi

RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
WORKLOAD="${WORKLOAD:-a}"
TEST_CASES=(1 10 50 100 500 1000 2000)

# Heterogeneous config file per cluster size (must match
# start_mongodb_hetero_nsel.sh's own NUM_SERVERS -> config mapping) --
# only used here for the pre-sweep stale-process purge.
declare -A HETERO_CONFIG_FOR_N=(
    [3]="cluster_hetero_3n_2s_1w"
    [5]="cluster_hetero_5n_2s_3w"
    [7]="cluster_hetero_7n_3s_4w"
    [11]="cluster_hetero_11n_4s_7w"
)

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_mongodb_batchsize_sweep_nsel_cab.sh

Sweeps BATCHSIZE over 1,10,50,100,500,1000,2000 with INDEP_RATIO=90,
MSG_SIZE=512 fixed, across cluster sizes n=3,5,7,11, against the Cabinet
MongoDB cluster (start_mongodb_hetero_nsel.sh, -et=1, ENABLE_PRIORITY=true,
THRESHOLD=1 fixed).

Environment overrides:
  RUNTIME_SECONDS=30       wall-clock seconds per run
  WORKLOAD=a               YCSB workload letter (a-f)
  CLUSTER_SIZES="3 5 7 11" override the cluster-size sweep

Results archived under: results/mongodb_batchsize_sweep_nsel_cab/<timestamp>/n<size>/<label>/
EOF
    exit 0
fi

mkdir -p "$RUN_DIR"
touch "${RUN_DIR}/.run_start_marker"
touch "${RUN_DIR}/.last_archive_ts"

cleanup_all_nodes() {
    echo "=================================================="
    echo " Pre-sweep cleanup: purging stale cabinet/mongod processes (all sizes)..."
    echo "=================================================="
    local all_ips=()
    for f in "${HETERO_CONFIG_FOR_N[@]}"; do
        awk 'NF >= 2 { print $2 }' "${REPO_ROOT}/config/${f}.conf" 2>/dev/null
    done | sort -u > /tmp/mongobatch_cab_ip_pool.$$
    mapfile -t all_ips < /tmp/mongobatch_cab_ip_pool.$$
    rm -f /tmp/mongobatch_cab_ip_pool.$$
    for ip in "${all_ips[@]}"; do
        ssh -o ConnectTimeout=5 -i "$SSH_KEY" "$USER@$ip" "pkill -9 -x cabinet 2>/dev/null; pkill -9 -x mongod 2>/dev/null" &
    done
    wait
}

archive_latest_result() {
    local label=$1
    local dest_dir="${RUN_DIR}/n${CURRENT_N}/${label}/merged"
    mkdir -p "$dest_dir"
    local marker="${RUN_DIR}/.last_archive_ts"
    local find_args=()
    if [ -f "$marker" ]; then
        find_args=(-newer "$marker")
    fi

    # stop_mongodb_hetero_nsel.sh writes merged CSVs to REPO_ROOT/eval/merged
    # (LOCAL_EVAL_DIR="${REPO_ROOT}/eval"), not SCRIPT_DIR/eval/merged --
    # SCRIPT_DIR points at .../cabinet/scripts, one level too deep, so this
    # dir never existed and every case's archive silently copied nothing.
    local merged_dir="${REPO_ROOT}/eval/merged"
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
    local batch_size=$2

    echo ""
    echo "=================================================="
    echo "Running: $label"
    echo "  n=${CURRENT_N}  t=${THRESHOLD}  batch=${batch_size}  workload=${WORKLOAD}  runtime=${RUNTIME_SECONDS}s"
    echo "=================================================="

    CLUSTER_ACTIVE=true
    NUM_SERVERS="$CURRENT_N" THRESHOLD="$THRESHOLD" INDEP_RATIO=90 BATCHSIZE="$batch_size" MSG_SIZE=512 \
        NUM_OBJECTS=1000 READ_RATIO=0 ENABLE_PRIORITY=true \
        bash "$START_SCRIPT" "$WORKLOAD"
    sleep "$RUNTIME_SECONDS"
    NUM_SERVERS="$CURRENT_N" bash "$STOP_SCRIPT"
    CLUSTER_ACTIVE=false
    archive_latest_result "$label"

    echo "  Cooling down to release TCP ports..."
    sleep 5
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        NUM_SERVERS="$CURRENT_N" bash "$STOP_SCRIPT" || true
    fi
}
trap cleanup EXIT

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  CABINET MONGODB BATCH SIZE SWEEP x CLUSTER SIZE (n=3,5,7,11)    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

cleanup_all_nodes

for n in "${ALL_CLUSTER_SIZES[@]}"; do
    CURRENT_N="$n"
    THRESHOLD=1
    echo ""
    echo "=================================================="
    echo " Cluster size n=${CURRENT_N} (t=${THRESHOLD}, fixed)"
    echo "=================================================="
    for batch_size in "${TEST_CASES[@]}"; do
        run_case "n${n}_mongo_batch_${batch_size}" "$batch_size"
    done
done

echo ""
echo "Extracting throughput/latency summary..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system cabinet

echo ""
echo "=================================================="
echo " Cabinet MongoDB batch size sweep x cluster size complete"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
echo "Summary CSV: $RUN_DIR/extracted_metrics.csv"
