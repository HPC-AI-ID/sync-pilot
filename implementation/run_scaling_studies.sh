#!/bin/bash

# Complete Thread Scaling Script for FSRCNN SyncPilot
# Purpose: Test 1 to 8 workers with comprehensive profiling
# Author: Kilo

set -e

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
EXAMPLE_DIR="${PROJECT_DIR}/example/fsrcnn"
FRAMEWORK_DIR="${PROJECT_DIR}/framework"
INPUT_FILE="suzie_176x144.yuv"
NUM_FRAMES=150
TOTAL_WORKERS="1 2 4 8"

# Output directories
BASE_RESULTS="${PROJECT_DIR}/results"
export RESULTS_DIR="${BASE_RESULTS}"
export GPROF_DIR="${BASE_RESULTS}/gprof"
export PERF_DIR="${BASE_RESULTS}/perf"
export LOGS_DIR="${BASE_RESULTS}/logs"
export OUTPUT_DIR="${BASE_RESULTS}/outputs"

mkdir -p "${RESULTS_DIR}"
mkdir -p "${GPROF_DIR}"
mkdir -p "${PERF_DIR}"
mkdir -p "${LOGS_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "=========================================="
echo "FSRCNN SCALING SUITE - Thread 1 to 8"
echo "=========================================="
echo "Source:   ${EXAMPLE_DIR}"
echo "Binary:   ${RESULTS_DIR}/fsrcnn_thread*_"
echo "Threads:  ${TOTAL_WORKERS}"
echo "Frames:   ${NUM_FRAMES}"
echo "Input:    ${INPUT_FILE}"
echo "=========================================="

# Compile binary for each worker configuration
echo "Step 1: Compiling..."
cd "${EXAMPLE_DIR}"
export CC=gcc

for workers in $TOTAL_WORKERS; do
    OUTPUT_BIN="${RESULTS_DIR}/fsrcnn_thread${workers}"

    echo "  → Building thread${workers} binary..."
    ${CC} -O3 -Wall -o "${OUTPUT_BIN}" \
        fsrcnn_syncpilot.c \
        "${FRAMEWORK_DIR}/syncpilot.c" \
        -lm -lrt -lpthread

    echo "       ✓ Compiled: " "${OUTPUT_BIN}"
done

# Run each configuration with profiling
echo ""
echo "Step 2: Running 1-8 worker configurations with profiling..."

for workers in $TOTAL_WORKERS; do
    echo "----------------------------------------------------------"
    echo "Running: thread${workers} (workers = ${workers})"
    echo "----------------------------------------------------------"

    BINARY="${RESULTS_DIR}/fsrcnn_thread${workers}"
    OUTPUT_YUV="${OUTPUT_DIR}/out_thread${workers}.yuv"
    GPROF_FILE="${GPROF_DIR}/gprof_thread${workers}.txt"
    PERF_FILE="${PERF_DIR}/perf_thread${workers}.txt"
    RUN_LOG="${LOGS_DIR}/run_thread${workers}.log"
    CPU_LOG="${LOGS_DIR}/cpu_thread${workers}.log"

    echo "-------------------- gprof profiling --------------------"
    perf record -F 99 -g -o "${BINARY}.perf_data" \
        "${BINARY}" "${INPUT_FILE}" "${OUTPUT_YUV}" "${workers}" \
        2>&1 | tee "${RUN_LOG}"

    perf report -i "${BINARY}.perf_data" --stdio > "${GPROF_FILE}"

    echo "-------------------- perf stat --------------------"
    perf stat -e cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,$
    i915.gpu_workload,i915.pipeline_utilization -o "${PERF_FILE}" -- \
        "${BINARY}" "${INPUT_FILE}" "${OUTPUT_YUV}" "${workers}" \
        >> "${RUN_LOG}" 2>&1

    echo "-------------------- system stats --------------------"
    ps aux | head -20 | tee "${CPU_LOG}"

    echo "✓ Completed: thread${workers}"
    echo "        Output: ${OUTPUT_YUV}"
    echo "        Gprof:  ${GPROF_FILE}"
    echo "        Perf:   ${PERF_FILE}"
done

echo ""
echo "=========================================="
echo "SCALING STUDY COMPLETE"
echo "=========================================="
echo "Results located in: ${RESULTS_DIR}"
echo ""
echo "Directory Structure:"
echo "  gprof/  - Gprof reports for each configuration"
echo "  perf/   - Performance counters (IPC, caches, etc.)"
echo "  logs/   - Execution logs and system stats"
echo "  outputs/- Generated YUV output files"
echo ""
echo "Next Actions:"
echo "  1. Analyze gprof flat profiles to identify bottleneck layers"
echo "  2. Calculate IPC: instructions / cycles for each config"
echo "  3. Compare compute-bound vs memory-bound behavior"
echo "  4. Benchmark 1-top-vector vs hibrid distribution"
echo ""
echo "To execute run analysis script:"
echo "  ./scripts/analyze_scaling.sh"
echo ""
