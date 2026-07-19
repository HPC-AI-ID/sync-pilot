#!/bin/bash

# Performance Analysis Script
# Purpose: Extract and dich for actionable insights

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
RESULTS_DIR="${PROJECT_DIR}/results"
export GPROF_DIR="${RESULTS_DIR}/gprof"
export PERF_DIR="${RESULTS_DIR}/perf"
export LOGS_DIR="${RESULTS_DIR}/logs"
export OUTPUT_DIR="${RESULTS_DIR}/outputs"
export ANALYSIS_DIR="${RESULTS_DIR}/analysis"

mkdir -p "${ANALYSIS_DIR}"

echo "=========================================="
echo "FSRCNN SCALING ANALYSIS TOOLKIT"
echo "=========================================="
echo "Results:  ${RESULTS_DIR}"
echo "Analysis: ${ANALYSIS_DIR}"
echo "=========================================="

echo ""
echo "ANALYSIS 1: IPC Values Extraction"
echo "-----------------------------------"

for workers in 1 2 4 8; do
    PERF_FILE="${PERF_DIR}/perf_thread${workers}.txt"

    if [ -f "${PERF_FILE}" ]; then
        echo "Thread ${workers}:"

        # Extract IPC (Instructions per Cycle)
        IPC=$(grep -oP 'instructions\s+\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)
        CYCLES=$(grep -oP 'cycles\s+\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)

        if [ -n "${IPC}" ] && [ -n "${CYCLES}" ] && [ "${CYCLES}" != "0" ]; then
            CALC_IPC=$(echo "scale=3; ${IPC} / ${CYCLES}" | bc)
            echo "  → IPC: ${CALC_IPC}"
        else
            echo "  → IPC: Unable to extract (file may be incomplete)"
        fi

        # Extract CPU time breakdown
        echo "  → CPU time breakdown:"
        grep "CPU time breakdown:" -A 5 "${ANALYSIS_DIR}/analysis_thread${workers}.txt" 2>/dev/null || \
            echo "    (file not yet generated)"
    fi

    echo ""
done

echo "ANALYSIS 2: Flat Profile Layer Bottleneck"
echo "------------------------------------------"

for workers in 1 2 4 8; do
    GPROF_FILE="${GPROF_DIR}/gprof_thread${workers}.txt"

    if [ -f "${GPROF_FILE}" ]; then
        echo "Thread ${workers} profile:"
        grep -A 2 "Index by function name and cumulative percent" -A 100 "${GPROF_FILE}" | \
            head -30
    fi

    echo ""
done

echo "ANALYSIS 3: Speedup Comparison"
echo "------------------------------"

# Extract baseline (Now we guess baseline to speedup formula)
# Current: Thread 1 should be baseline
for workers in 1 2 4 8; do
    PERF_FILE="${PERF_DIR}/perf_thread${workers}.txt"

    if [ -f "${PERF_FILE}" ]; then
        TOTAL_TIME=$(grep "seconds time elapsed" "${PERF_FILE}" 2>/dev/null | head -1)

        echo "Thread ${workers}: ${TOTAL_TIME}"
    fi
done

echo ""
echo "To generate full analysis:"
echo "  ./generate_full_analysis_report.sh ${RESULTS_DIR}"
echo ""
