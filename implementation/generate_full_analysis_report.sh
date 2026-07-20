#!/bin/bash

# Extended Analysis Script - Generate detailed reports
# Purpose: Comprehensive analysis of all profiling data

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
RESULTS_DIR="${1:-${PROJECT_DIR}/results}"
export GPROF_DIR="${RESULTS_DIR}/gprof"
export PERF_DIR="${RESULTS_DIR}/perf"
export LOGS_DIR="${RESULTS_DIR}/logs"
export OUTPUT_DIR="${RESULTS_DIR}/outputs"
export ANALYSIS_DIR="${RESULTS_DIR}/analysis"

mkdir -p "${ANALYSIS_DIR}"

echo "=========================================="
echo "GENERATING COMPREHENSIVE ANALYSIS REPORT"
echo "=========================================="
echo "Source:  ${RESULTS_DIR}"
echo "Output:  ${ANALYSIS_DIR}"
echo "=========================================="

# Generate summary statistics
ANALYSIS_FILE="${ANALYSIS_DIR}/summary_analysis.txt"

cat > "${ANALYSIS_FILE}" << 'HEADER'
================================================================================
FSRCNN SCALING ANALYSIS REPORT
================================================================================
Generated: $(date)
Platform: Orange Pi 5 (RK3588S)
Study: Thread scaling 1 to 8 workers on AMP (big.LITTLE)
================================================================================

HEADER

# Generate section for each worker configuration
for workers in 1 2 4 8; do
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "THREAD ${workers} ANALYSIS"
    echo "--------------------------------------------------------------------------------"

    PERF_FILE="${PERF_DIR}/perf_thread${workers}.txt"
    GPROF_FILE="${GPROF_DIR}/gprof_thread${workers}.txt"
    RUN_LOG="${LOGS_DIR}/run_thread${workers}.log"
    CPU_LOG="${LOGS_DIR}/cpu_thread${workers}.log"

    # Extract physical performance
    APP_TIME=$(grep -oP 'time elapsed.*\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)
    CPU_TIME=$(grep -oP 'cpu\).*user.*sys.*\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)
    WALL_TIME=$(echo "${APP_TIME:-1}" | awk '{print $1/1e9}')  # Convert from nanoseconds

    # Extract IPC
    IPC=$(grep -oP 'instructions\s+\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)
    CYCLES=$(grep -oP 'cycles\s+\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)

    # Extract cache statistics
    CACHE_HIT=$(grep -oP 'cache-references.*\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)
    CACHE_MISS=$(grep -oP 'cache-misses.*\K[0-9.]+' "${PERF_FILE}" 2>/dev/null | head -1)

    # Calculate derived metrics
    if [ -n "${CYCLES}" ] && [ "${CYCLES}" != "0" ]; then
        CALC_IPC=$(echo "scale=3; ${IPC} / ${CYCLES}" | bc)
    else
        CALC_IPC="N/A"
    fi

    CALC_CACHE_HIT_RATIO="N/A"
    if [ -n "${CACHE_HIT}" ] && [ -n "${CACHE_MISS}" ] && [ "${CACHE_HIT}" != "0" ]; then
        CALC_CACHE_HIT_RATIO=$(echo "scale=3; 100 - (${CACHE_MISS} / ${CACHE_HIT} * 100)" | bc)
    fi

    # Generate analysis text
cat >> "${ANALYSIS_FILE}" << TEAL

THREAD ${workers} SUMMARY
-----------------------
Binary: ${RESULTS_DIR}/fsrcnn_thread${workers}
CPU Threads: ${workers}
Wall Clock Time: ${WALL_TIME}s
CPU User Time: ${CPU_TIME}s
---

PERFORMANCE METRICS
-------------------
Total Instructions: ${IPC}
Total Cycles: ${CYCLES}
IPC (Instructions/Cycle): ${CALC_IPC}

Cache Performance:
Total Cache References: ${CACHE_HIT}
Total Cache Misses: ${CACHE_MISS}
Hit Rate (%): ${CALC_CACHE_HIT_RATIO}

KEY INSIGHTS (based on exposure)
--------------------------------
TEAL

    # Layer bottleneck analysis from gprof
    if [ -f "${GPROF_FILE}" ]; then
        echo "" >> "${ANALYSIS_FILE}"
        echo "LAYER BOTTLENECK IDENTIFICATION (gprof)" >> "${ANALYSIS_FILE}"
        echo "----------------------------------------" >> "${ANALYSIS_FILE}"
        echo "The gprof flat profile below identifies most expensive functions:" >> "${ANALYSIS_FILE}"
        echo "" >> "${ANALYSIS_FILE}"
        grep -A 20 "Call graph" "${GPROF_FILE}" 2>/dev/null | \
            sed 's/^/    /' >> "${ANALYSIS_FILE}"

        # Map gprof function names to FSRCNN layers
        echo "" >> "${ANALYSIS_FILE}"
        echo "Mapping: gprof function → FSRCNN layer" >> "${ANALYSIS_FILE}"
        echo "----------------------------------------" >> "${ANALYSIS_FILE}"
        echo "  layer1 → fsrcnn_process_stage (FSRCNN Layer 1)" >> "${ANALYSIS_FILE}"
        echo "  layer8 → fsrcnn_process_stage (FSRCNN Layer 8 - DECONV)" >> "${ANALYSIS_FILE}"
    fi

done

cat >> "${ANALYSIS_FILE}" << FOOTER

================================================================================
SCALING COMPARISON SUMMARY
================================================================================

Configurations Tested:
  1x Serial Baseline    → 1 worker
  2x Mixed             → 1 Big + 1 LITTLE (estimate)
  4x Big-Only          → 4 workers, all Big cores (recommended)
  8x Hybrid            → 4 Big + 4 LITTLE (optimal? analyze below)

Note: Full thread distribution analysis requires additional benchmark data.
      The 4 Big-Only configuration shows promise for compute-bound workloads.

================================================================================
NEXT STEPS
================================================================================

1. Execute: ./run_scaling_studies.sh
2. Generate this report: ./generate_full_analysis_report.sh
3. Analyze layer-level cost data from framework (syncpilot logs)
4. Compare IPC values Thread 4 vs Hybrid to validate integration
5. Add input resolution scaling test (176x144 vs 352x288) to confirm
   compute-bound nature (if time increases with resolution, it's compute-bound)

===============================================================================
FOOTER

echo "Report generated: ${ANALYSIS_FILE}"=
