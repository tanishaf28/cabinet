#!/bin/bash
# ================================================================
# Cabinet MongoDB Workload Sweep, HETEROGENEOUS 5-NODE (2s+3w) cluster.
#
# Sweeps YCSB WORKLOAD over a,b,c,d,e,f with INDEP_RATIO fixed at 90/10
# and BATCHSIZE=1, against the MongoDB-backed cluster
# (start_mongodb_hetero_5n.sh, -et=1, ENABLE_PRIORITY=true => Cabinet,
# standalone mongod per node). Mirrors run_mongodb_ratio_sweep_5n_cab.sh
# but sweeps the orthogonal workload-type dimension instead of ratio.
#
# ENABLE_TIMESERIES=true throughout (tps_timeline_*.csv collected into each
# case's own result dir and plot_timeseries.py run automatically at the
# end -- same pattern as run_mongodb_delay_eval_5n_cab.sh). Also switched
# cleanup from stop_cluster_hetero.sh to stop_mongodb_hetero_nsel.sh:
# stop_cluster_hetero.sh never kills mongod, leaving orphaned mongod
# processes/lock files on the server nodes after every run (see
# stop_mongodb_hetero_nsel.sh's own header for the full story).
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_mongodb_hetero_5n.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_mongodb_hetero_nsel.sh"
SSH_KEY="/home/ubuntu/.ssh/tani.pem"
USER="ubuntu"
RESULT_ROOT="${SCRIPT_DIR}/results/mongodb_workload_sweep_5n_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
CLUSTER_ACTIVE=false

# Must match config/cluster_hetero_5n_2s_3w.conf's first 7 IPs (5 servers
# + 2 clients) -- only used here for the pre-sweep stale-process purge.
ALL_NODE_IPS=(
"192.168.73.59" "192.168.73.243" "192.168.73.117" "192.168.73.16" "192.168.73.94"
"192.168.73.159" "192.168.73.84" "192.168.73.218" "192.168.73.219" "192.168.73.25"
)

RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
INDEP_RATIO_FIXED="${INDEP_RATIO_FIXED:-90}"
WORKLOADS=(a b c d e f)

if ! [[ "$RUNTIME_SECONDS" =~ ^[0-9]+$ ]] || [ "$RUNTIME_SECONDS" -lt 1 ]; then
    echo "WARNING: RUNTIME_SECONDS=${RUNTIME_SECONDS} is invalid. Using 60."
    RUNTIME_SECONDS=60
fi

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_mongodb_workload_sweep_5n_cab.sh

Sweeps YCSB WORKLOAD over a,b,c,d,e,f with INDEP_RATIO fixed (default 90)
and BATCHSIZE=1, against the heterogeneous 5-node Cabinet MongoDB cluster
(start_mongodb_hetero_5n.sh, -et=1, ENABLE_PRIORITY=true). Runs with
ENABLE_TIMESERIES=true and auto-generates timeseries plots at the end.

Environment overrides:
  RUNTIME_SECONDS=60      wall-clock seconds per run
  INDEP_RATIO_FIXED=90    fixed INDEP_RATIO for every workload case
  TPS_TIMELINE_INTERVAL_MS=500  timeseries sampling interval

Results archived under: results/mongodb_workload_sweep_5n_cab/<timestamp>/<label>/
EOF
    exit 0
fi

mkdir -p "$RUN_DIR"
touch "${RUN_DIR}/.run_start_marker"
# Pre-create the archive marker so even case #1 of the sweep only
# picks up CSVs written during this run, not every historical
# merged_*.csv ever produced (archive_latest_result's -newer filter
# is a no-op until this file exists).
touch "${RUN_DIR}/.last_archive_ts"

cleanup_all_nodes() {
    echo "=================================================="
    echo " Pre-sweep cleanup: purging stale cabinet/mongod processes..."
    echo "=================================================="
    for ip in "${ALL_NODE_IPS[@]}"; do
        ssh -o ConnectTimeout=5 -i "$SSH_KEY" "$USER@$ip" \
            "pkill -9 -x cabinet 2>/dev/null; pkill -9 -x mongod 2>/dev/null" &
    done
    wait
}

archive_latest_result() {
    local label=$1
    local dest_dir="${RUN_DIR}/${label}"
    mkdir -p "$dest_dir"
    local marker="${RUN_DIR}/.last_archive_ts"
    local find_args=()
    if [ -f "$marker" ]; then
        find_args=(-newer "$marker")
    fi

    local merged_dir="${REPO_ROOT}/eval/merged"
    if [ -d "$merged_dir" ]; then
        find "$merged_dir" -maxdepth 1 -name "*.csv" "${find_args[@]}" \
            -exec cp {} "$dest_dir/" \; 2>/dev/null || true
        if [ -z "$(ls "$dest_dir"/*.csv 2>/dev/null)" ]; then
            cp "$merged_dir"/*.csv "$dest_dir/" 2>/dev/null || true
        fi
    fi

    # Timeseries CSVs go directly into dest_dir (not nested under any
    # subdir) -- this is the layout plot_timeseries.py's
    # find_timeline_csvs() scans for.
    local timeline_src="${REPO_ROOT}/eval"
    if [ -d "$timeline_src" ]; then
        find "$timeline_src" -name "tps_timeline_*.csv" "${find_args[@]}" \
            -exec cp {} "$dest_dir/" \; 2>/dev/null || true
    fi

    touch "$marker"
    echo "  Archived results to: $dest_dir"
    ls -1 "$dest_dir"/*.csv 2>/dev/null | sed 's|.*/|    |' || echo "  (no CSVs found)"
    if ls "$dest_dir"/tps_timeline_*.csv >/dev/null 2>&1; then
        echo "    timeseries: $(ls "$dest_dir"/tps_timeline_*.csv | wc -l) file(s)"
    else
        echo "    WARNING: no tps_timeline_*.csv collected for ${label}"
    fi
}

run_case() {
    local label=$1
    local workload=$2

    echo ""
    echo "=================================================="
    echo "Running: $label"
    echo "  n=5 (2s+3w)  workload=${workload}  indep=${INDEP_RATIO_FIXED}  runtime=${RUNTIME_SECONDS}s"
    echo "=================================================="

    CLUSTER_ACTIVE=true
    ENABLE_TIMESERIES=true TPS_TIMELINE_INTERVAL_MS="${TPS_TIMELINE_INTERVAL_MS:-500}" \
        INDEP_RATIO="$INDEP_RATIO_FIXED" BATCHSIZE=1 NUM_OBJECTS=1000 READ_RATIO=0 ENABLE_PRIORITY=true \
        bash "$START_SCRIPT" "$workload"
    sleep "$RUNTIME_SECONDS"
    NUM_SERVERS=5 NUM_CLIENTS=5 CONFIG_PATH="${REPO_ROOT}/config/cluster_hetero_5n_2s_3w.conf" bash "$STOP_SCRIPT"
    CLUSTER_ACTIVE=false
    archive_latest_result "$label"

    echo "  Cooling down to release TCP ports..."
    sleep 5
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        NUM_SERVERS=5 NUM_CLIENTS=5 CONFIG_PATH="${REPO_ROOT}/config/cluster_hetero_5n_2s_3w.conf" bash "$STOP_SCRIPT" || true
    fi
}
trap cleanup EXIT

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   CABINET MONGODB WORKLOAD SWEEP, HETEROGENEOUS 5-NODE         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Result archive: $RUN_DIR"
echo ""

cleanup_all_nodes

for workload in "${WORKLOADS[@]}"; do
    run_case "n5_cab_mongo_workload_${workload}" "$workload"
done

echo ""
echo "Extracting throughput/latency summary..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --size 5 --system cabinet

echo ""
echo "Generating timeseries plots..."
if python3 "${REPO_ROOT}/plot_timeseries.py" "$RUN_DIR"; then
    echo "  Plots written to: $RUN_DIR/plots/"
else
    echo "  WARNING: plot_timeseries.py failed or found no timeseries data - check tps_timeline_*.csv collection above."
fi

echo ""
echo "=================================================="
echo " Cabinet MongoDB workload sweep complete"
echo "=================================================="
echo "Results archived in: $RUN_DIR"
echo "Summary CSV: $RUN_DIR/extracted_metrics.csv"
echo "Timeseries plots: $RUN_DIR/plots/"
