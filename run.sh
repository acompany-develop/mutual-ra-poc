#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# End-to-end 2-node vTPM mutual-attestation.
set -euo pipefail
cd "$(dirname "$0")"

echo "== bring up one swtpm per node =="

start_one() {
    local name="$1"
    local dir="/tmp/tpm/${name}"
    local sock="${dir}.sock"
    pkill -f "path=${sock}" 2>/dev/null || true
    sleep 0.2
    rm -rf "$dir"          # discard previous TPM state
    mkdir -p "$dir"
    rm -f "$sock" "${sock}.ctrl"
    swtpm socket --tpm2 \
        --tpmstate dir="$dir" \
        --flags startup-clear \
        --ctrl type=unixio,path="${sock}.ctrl" \
        --server type=unixio,path="$sock" \
        --daemon
    echo "${name} (re)started -> swtpm:path=${sock}"
}

mkdir -p /tmp/tpm
start_one n0
start_one n1
sleep 0.5

echo "== run node 1 (listener, vTPM n0) in background =="
TPM_TCTI="swtpm:path=/tmp/tpm/n0.sock" HS_PORT=30303 \
    uv run node___NODE1.py &
N1=$!
sleep 1

echo "== run node 2 (connector, vTPM n1) =="
TPM_TCTI="swtpm:path=/tmp/tpm/n1.sock" HS_PORT=30303 \
    uv run node___NODE2.py

wait "$N1"
echo "== done =="
