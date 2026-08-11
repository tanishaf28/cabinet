#!/bin/bash
# ================================================================
# N=5 SMOKE TEST — indep ratio sweep (eval1) + batch size sweep (eval2),
# once with fixed clients (SCALE_CLIENTS=false, FIXED_CLIENT_COUNT=3) and
# once with scale clients (SCALE_CLIENTS=true, 5 clients piling onto the
# leader). Runs both Cabinet (fixed t=1) and Raft (t=floor((n-1)/2)).
#
# Wraps run_hetero_plainmsg_cab.sh / run_hetero_plainmsg_raft.sh with
# CLUSTER_SIZES="5" so the full n=3/7/11 sweep is skipped. Use this to
# sanity-check the cluster on a single cluster size before committing to
# the full sweep.
#
# Usage: bash run_n5_test.sh [cab|raft|both]   (default: both)
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-both}"

export CLUSTER_SIZES="5"
export RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"

run_protocol() {
    local name=$1
    local run_script=$2

    echo "################################################################"
    echo "# ${name} N=5 test — FIXED clients (FIXED_CLIENT_COUNT=3)"
    echo "################################################################"
    SCALE_CLIENTS=false FIXED_CLIENT_COUNT=3 bash "$run_script" eval1
    SCALE_CLIENTS=false FIXED_CLIENT_COUNT=3 bash "$run_script" eval2

    echo "################################################################"
    echo "# ${name} N=5 test — SCALE clients (5 clients)"
    echo "################################################################"
    SCALE_CLIENTS=true bash "$run_script" eval1
    SCALE_CLIENTS=true bash "$run_script" eval2
}

case "$TARGET" in
    cab)  run_protocol "Cabinet" "${SCRIPT_DIR}/run_hetero_plainmsg_cab.sh" ;;
    raft) run_protocol "Raft" "${SCRIPT_DIR}/run_hetero_plainmsg_raft.sh" ;;
    both)
        run_protocol "Cabinet" "${SCRIPT_DIR}/run_hetero_plainmsg_cab.sh"
        run_protocol "Raft" "${SCRIPT_DIR}/run_hetero_plainmsg_raft.sh"
        ;;
    *) echo "Usage: bash run_n5_test.sh [cab|raft|both]"; exit 1 ;;
esac

echo ""
echo "N=5 test complete. Results under: ${SCRIPT_DIR}/../results/hetero_plainmsg/<timestamp>/n5/"
