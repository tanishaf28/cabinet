#!/bin/bash
# ================================================================
# EVAL 4 (Cabinet): Read Ratio Sweep, heterogeneous 5-node cluster
#
# Sweeps -readratio (% of ops that are reads) over 0/25/50/75/100 at a
# fixed INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 -- mirrors woc's
# scripts/eval_4_read_ratio.sh, but against Cabinet's own quorum read
# path (see consensus_with_clients.go's read branch) instead of woc's
# per-object fast/safe split: Cabinet has no fast-read mode, every read
# is answered by the leader only once the same priority quorum used for
# writes confirms it (ReadIndex-style) -- so there is no -readmode flag
# to cross this sweep with.
#
# Same fixed 5-node 2s+3w cluster / 2-client config as eval1-3 in
# run_hetero_plainmsg_cab.sh's own (non-extracted) eval4 block; this
# script just runs the read-ratio sweep on its own, the way
# run_hetero_ratio_sweep_10c_cab.sh does for the indep-ratio sweep.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

START_SCRIPT="${SCRIPT_DIR}/start_cluster_hetero.sh"
STOP_SCRIPT="${SCRIPT_DIR}/stop_cluster_hetero.sh"

RESULT_ROOT="${REPO_ROOT}/results/hetero_read_ratio_cab"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULT_ROOT}/${RUN_TS}"
EVAL_DIR="${REPO_ROOT}/eval"

CLUSTER_ACTIVE=false

NUM_SERVERS="${NUM_SERVERS:-5}"
THRESHOLD=1
RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
INDEP_RATIO="${INDEP_RATIO:-90}"
NUM_OBJECTS="${NUM_OBJECTS:-1000}"

TEST_CASES=(0 25 50 75 100)

mkdir -p "$RUN_DIR"

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: bash run_hetero_read_ratio_cab.sh

Sweeps -readratio over 0,25,50,75,100 against the fixed 5-server
heterogeneous cluster (config/cluster_hetero_5n_2s_3w.conf, 2 clients).
INDEP_RATIO=90, BATCHSIZE=1, MSG_SIZE=512 fixed. THRESHOLD fixed at 1
(Cabinet quorum semantics). Reads are always quorum-confirmed -- there
is no -readmode flag/sweep, unlike woc's eval_4_read_ratio.sh.

Environment overrides:
  RUNTIME_SECONDS=30   wall-clock seconds per test case
  INDEP_RATIO=90
  NUM_OBJECTS=1000

Results: results/hetero_read_ratio_cab/<timestamp>/<label>/
EOF
    exit 0
fi

start_cluster() {
    CLUSTER_ACTIVE=true
    env "${BASE_ENV[@]}" bash "$START_SCRIPT"
}

stop_cluster() {
    env "${BASE_ENV[@]}" bash "$STOP_SCRIPT"
    CLUSTER_ACTIVE=false
}

archive_results() {
    local label=$1
    local dest_dir="${RUN_DIR}/${label}"
    mkdir -p "$dest_dir"

    local merged_dir="${EVAL_DIR}/merged"
    if [ -d "$merged_dir" ]; then
        cp "$merged_dir"/*.csv "$dest_dir/" 2>/dev/null || true
    fi
    cp -r "${EVAL_DIR}"/client* "$dest_dir/" 2>/dev/null || true

    echo "  Archived results to: $dest_dir"
}

run_case() {
    local label=$1
    local runtime=$2

    echo ""
    echo "=================================================="
    echo "Running: $label  [${runtime}s]"
    echo "=================================================="

    rm -rf "${EVAL_DIR}"/client* "${EVAL_DIR}"/server* "${EVAL_DIR}"/merged 2>/dev/null || true

    start_cluster
    sleep "$runtime"
    stop_cluster
    archive_results "$label"
}

cleanup() {
    if [ "$CLUSTER_ACTIVE" = true ]; then
        stop_cluster || true
    fi
}
trap cleanup EXIT INT

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   READ RATIO SWEEP (Cabinet, heterogeneous 5-node cluster)     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Test cases: ${TEST_CASES[*]}"
echo "Result archive: $RUN_DIR"
echo ""

for read_ratio in "${TEST_CASES[@]}"; do
    BASE_ENV=(
        "NUM_SERVERS=${NUM_SERVERS}" "NUM_CLIENTS=2" "THRESHOLD=${THRESHOLD}" "OPS=0"
        "EVAL_TYPE=0" "BATCHSIZE=1" "MSG_SIZE=512" "MODE=1"
        "INDEP_RATIO=${INDEP_RATIO}" "NUM_OBJECTS=${NUM_OBJECTS}"
        "BATCH_MODE=single" "BATCH_COMPOSITION=object-specific"
        "LOG_LEVEL=info" "ENABLE_PRIORITY=true" "RATIO_STEP=0.001"
        "READ_RATIO=${read_ratio}"
    )
    run_case "readratio_${read_ratio}" "$RUNTIME_SECONDS"
done

echo ""
echo "Extracting throughput/latency metrics..."
python3 "${REPO_ROOT}/extract_metrics.py" "$RUN_DIR" --system cabinet --size "$NUM_SERVERS"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Read ratio sweep (Cabinet) complete                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Results archived in: $RUN_DIR"
