#!/bin/bash
###############################################################################
# comparison_new.sh - Python FSRCNN Performance Comparison Script
#
# Mirrors the C version: benchmarks Python serial vs Python SyncPilot
# across different worker counts, measures time, throughput, and PSNR.
#
# Usage:
#   bash comparison_new.sh              # run full benchmark
#   bash comparison_new.sh --build-only # only check dependencies
###############################################################################

set -e

BUILD_ONLY=0
if [ "${1:-}" = "--build-only" ] || [ "${1:-}" = "build-only" ]; then
    BUILD_ONLY=1
fi

# ===================== KONFIGURASI =====================
INPUT_FILE="suzie_qcif.yuv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_PATH="${SCRIPT_DIR}/../fsrcnn/${INPUT_FILE}"

C_EXAMPLE_DIR="${SCRIPT_DIR}/../fsrcnn"

# Resolusi QCIF
WIDTH=176
HEIGHT=144
OUT_WIDTH=$((WIDTH * 2))
OUT_HEIGHT=$((HEIGHT * 2))

NUM_RUNS=5
TOTAL_FRAMES=150
EXPECTED_OUTPUT_SIZE=$((OUT_WIDTH * OUT_HEIGHT * 3 / 2 * TOTAL_FRAMES))

# Python
PYTHON="python3"
SERIAL_SCRIPT="${SCRIPT_DIR}/fsrcnn_serial.py"
SYNCPILOT_SCRIPT="${SCRIPT_DIR}/fsrcnn_syncpilot.py"

# Skenarios
SCENARIOS=("SER" "A" "B" "C" "D")
LABELS=(
    "Python Serial (sequential)"
    "Python SyncPilot 2 workers"
    "Python SyncPilot 4 workers"
    "Python SyncPilot 8 workers"
    "Python SyncPilot 16 workers"
)
SCENARIO_RUNNERS=("serial" "syncpilot" "syncpilot" "syncpilot" "syncpilot")
SCENARIO_WORKERS=(1 2 4 8 16)

# ===================== UTILITIES =====================

check_venv() {
    if [ -z "$VIRTUAL_ENV" ]; then
        echo "[WARN] Tidak ada virtual environment aktif."
        echo "       Recommend: cd ${SCRIPT_DIR} && source venv/bin/activate"
    fi

    if ! $PYTHON -c "import numpy" 2>/dev/null; then
        echo "[ERROR] numpy tidak terinstall. Jalankan: pip install numpy"
        exit 1
    fi
    echo "[✓] Python environment OK."
}

get_time_ms() {
    if [[ "$(uname)" == "Darwin" ]]; then
        if command -v gdate &> /dev/null; then
            echo $(($(gdate +%s%N) / 1000000))
        elif command -v python3 &> /dev/null; then
            python3 -c "import time; print(int(time.time() * 1000))"
        else
            echo $(($(date +%s) * 1000))
        fi
    else
        echo $(($(date +%s%N) / 1000000))
    fi
}

get_file_size() {
    local file="$1"
    stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0"
}

calculate_psnr() {
    local file1="$1"
    local file2="$2"

    if [ ! -f "$file1" ] || [ ! -f "$file2" ]; then
        echo "N/A"
        return
    fi

    if command -v ffmpeg &> /dev/null; then
        local psnr_output
        psnr_output=$(ffmpeg -s ${OUT_WIDTH}x${OUT_HEIGHT} -pix_fmt yuv420p -i "$file1" \
                             -s ${OUT_WIDTH}x${OUT_HEIGHT} -pix_fmt yuv420p -i "$file2" \
                             -lavfi psnr -f null - 2>&1 | grep "average" | tail -1)

        if [ -n "$psnr_output" ]; then
            echo "$psnr_output" | sed 's/.*average://' | awk '{print $1}'
        else
            echo "N/A"
        fi
    else
        $PYTHON -c "
import sys, math, numpy as np
size = $OUT_WIDTH * $OUT_HEIGHT
with open('$file1', 'rb') as f1, open('$file2', 'rb') as f2:
    y1 = np.frombuffer(f1.read(size), dtype=np.uint8)
    y2 = np.frombuffer(f2.read(size), dtype=np.uint8)
mse = np.mean((y1.astype(float) - y2.astype(float)) ** 2)
if mse == 0:
    print('inf')
else:
    print(f'{(20 * math.log10(255.0) - 10 * math.log10(mse)):.2f}')
" 2>/dev/null || echo "N/A"
    fi
}

run_scenario() {
    local script="$1"
    local output_file="$2"
    local workers="$3"

    if [ "$workers" = "1" ]; then
        $PYTHON "$script" "$INPUT_PATH" "$output_file" "$TOTAL_FRAMES" > /dev/null 2>&1
    else
        $PYTHON "$script" "$INPUT_PATH" "$output_file" "$workers" > /dev/null 2>&1
    fi
}

# ===================== MAIN =====================

echo "============================================================================="
echo "           PYTHON FSRCNN PERFORMANCE COMPARISON"
echo "============================================================================="
echo ""

if [ "$BUILD_ONLY" -eq 1 ]; then
    check_venv
    echo "Dependencies OK. Mode build-only, benchmark dihentikan."
    exit 0
fi

check_venv
echo ""

# ===================== VALIDASI INPUT =====================
if [ ! -f "$INPUT_PATH" ]; then
    echo "[ERROR] Input file tidak ditemukan: $INPUT_PATH"
    exit 1
fi

# Ground truth dari C baseline
GROUND_TRUTH="${C_EXAMPLE_DIR}/output_baseline_ground_truth.yuv"

if [ ! -f "$GROUND_TRUTH" ]; then
    ground_truth_size=0
else
    ground_truth_size=$(get_file_size "$GROUND_TRUTH")
fi

if [ "$ground_truth_size" -ne "$EXPECTED_OUTPUT_SIZE" ]; then
    if [ "$ground_truth_size" -gt 0 ]; then
        echo ">> Ground truth cache tidak valid, membuat ulang..."
    else
        echo ">> Membuat ground truth dari C Baseline..."
    fi

    if [ ! -f "${C_EXAMPLE_DIR}/fsrcnn_baseline" ]; then
        echo "[ERROR] C baseline binary tidak ditemukan: ${C_EXAMPLE_DIR}/fsrcnn_baseline"
        echo "       Compile dulu di $C_EXAMPLE_DIR"
        exit 1
    fi

    "${C_EXAMPLE_DIR}/fsrcnn_baseline" "$INPUT_PATH" "$GROUND_TRUTH" > /dev/null 2>&1
    echo "   Ground truth selesai: $(du -h "$GROUND_TRUTH" | awk '{print $1}')"
else
    echo ">> Ground truth cache valid: $(du -h "$GROUND_TRUTH" | awk '{print $1}')"
fi
echo ""

# ===================== BENCHMARK =====================
echo "============================================================================="
echo "                    MENJALANKAN BENCHMARK PYTHON"
echo "============================================================================="
echo ""

declare -a TIMES_AVG
declare -a TIMES_MIN
declare -a TIMES_MAX
declare -a OUTPUT_SIZES
declare -a OUTPUT_FILES

for i in "${!SCENARIOS[@]}"; do
    scen="${SCENARIOS[$i]}"
    label="${LABELS[$i]}"
    runner="${SCENARIO_RUNNERS[$i]}"
    workers="${SCENARIO_WORKERS[$i]}"
    output_file="${SCRIPT_DIR}/output_scenario_${scen}.yuv"
    OUTPUT_FILES[$i]="$output_file"

    echo "---------------------------------------------------------------------"
    echo "Skenario: ${label}"
    if [ "$runner" = "serial" ]; then
        echo "     Config: fsrcnn_serial.py, workers=sequential"
    else
        echo "     Config: fsrcnn_syncpilot.py, workers=${workers}"
    fi
    echo "---------------------------------------------------------------------"

    total_time=0
    min_time=999999999
    max_time=0

    for ((run=1; run<=NUM_RUNS; run++)); do
        rm -f "$output_file"

        start_time=$(get_time_ms)
        if [ "$runner" = "serial" ]; then
            $PYTHON "$SERIAL_SCRIPT" "$INPUT_PATH" "$output_file" "$TOTAL_FRAMES" > /dev/null 2>&1
        else
            $PYTHON "$SYNCPILOT_SCRIPT" "$INPUT_PATH" "$output_file" "$workers" > /dev/null 2>&1
        fi
        end_time=$(get_time_ms)

        elapsed=$((end_time - start_time))
        total_time=$((total_time + elapsed))
        [ $elapsed -lt $min_time ] && min_time=$elapsed
        [ $elapsed -gt $max_time ] && max_time=$elapsed

        printf "     Run %d/%d: %d ms\n" "$run" "$NUM_RUNS" "$elapsed"
    done

    avg_time=$((total_time / NUM_RUNS))
    TIMES_AVG[$i]=$avg_time
    TIMES_MIN[$i]=$min_time
    TIMES_MAX[$i]=$max_time

    if [ -f "$output_file" ]; then
        OUTPUT_SIZES[$i]=$(get_file_size "$output_file")
    else
        OUTPUT_SIZES[$i]=0
    fi

    echo ""
    printf "     Rata-rata: %d ms\n" "$avg_time"
    echo ""
done

# ===================== PSNR =====================
echo "============================================================================="
echo "                    MENGHITUNG PSNR"
echo "============================================================================="
echo ""

declare -a PSNR_VALUES
for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    output_file="${OUTPUT_FILES[$i]}"

    if [ ! -f "$output_file" ]; then
        PSNR_VALUES[$i]="N/A"
        printf "  PSNR %-35s: N/A (file not found)\n" "${label}"
        continue
    fi

    printf "  PSNR %-35s: " "${label}"
    psnr=$(calculate_psnr "$GROUND_TRUTH" "$output_file")
    PSNR_VALUES[$i]="$psnr"
    echo "$psnr dB"
done
echo ""

# ===================== RINGKASAN =====================
echo "============================================================================="
echo "                    RINGKASAN HASIL PYTHON"
echo "============================================================================="
echo ""

printf "%-35s | %10s | %10s | %10s | %15s | %10s\n" \
    "Skenario" "Avg (ms)" "Min (ms)" "Max (ms)" "Throughput(fps)" "PSNR (dB)"
printf "%-35s-+-%10s-+-%10s-+-%10s-+-%15s-+-%10s\n" \
    "-----------------------------------" "----------" "----------" "----------" "---------------" "----------"

for i in "${!SCENARIOS[@]}"; do
    throughput=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_FRAMES * 1000) / ${TIMES_AVG[$i]}}")
    printf "%-35s | %10d | %10d | %10d | %15s | %10s\n" \
        "${LABELS[$i]}" \
        "${TIMES_AVG[$i]}" \
        "${TIMES_MIN[$i]}" \
        "${TIMES_MAX[$i]}" \
        "$throughput" \
        "${PSNR_VALUES[$i]}"
done
echo ""

# ===================== SPEEDUP ANALYSIS =====================
echo "============================================================================="
echo "                    ANALISIS SPEEDUP (vs Python Serial)"
echo "============================================================================="
echo ""

serial_time=${TIMES_AVG[0]}
printf "Baseline Serial (Python): %d ms\n\n" "$serial_time"

printf "%-35s | %12s | %s\n" "Skenario" "Speedup" "Keterangan"
printf "%-35s-+-%12s-+-%s\n" "-----------------------------------" "------------" "--------------------"

for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    avg=${TIMES_AVG[$i]}

    if [ "$avg" -gt 0 ]; then
        speedup=$(awk "BEGIN {printf \"%.2f\", $serial_time / $avg}")
        if (( $(awk "BEGIN {print ($speedup >= 1.0) ? 1 : 0}") )); then
            keterangan="${speedup}x lebih cepat"
        else
            slowdown=$(awk "BEGIN {printf \"%.2f\", $avg / $serial_time}")
            keterangan="${slowdown}x lebih lambat"
        fi
    else
        speedup="N/A"
        keterangan="Error"
    fi

    printf "%-35s | %12s | %s\n" "${label}" "${speedup}x" "$keterangan"
done
echo ""

# ===================== KONSISTENSI =====================
echo "============================================================================="
echo "                    CEK KONSISTENSI OUTPUT"
echo "============================================================================="
echo ""
for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    output_file="${OUTPUT_FILES[$i]}"

    if [ -f "$output_file" ] && [ -f "$GROUND_TRUTH" ]; then
        if cmp -s "$GROUND_TRUTH" "$output_file"; then
            printf "  %-35s : IDENTIK [OK]\n" "${label}"
        else
            printf "  %-35s : BERBEDA [DIFF]\n" "${label}"
        fi
    else
        printf "  %-35s : FILE TIDAK DITEMUKAN\n" "${label}"
    fi
done
echo ""

# ===================== GNUPLOT DATA =====================
echo "============================================================================="
echo "                  MENULIS DATA & MEMBUAT GRAFIK (GNUPLOT)"
echo "============================================================================="
echo ""

DAT_FILE="${SCRIPT_DIR}/benchmark_data.dat"
echo "# Skenario Time_ms Throughput_fps" > "$DAT_FILE"

for i in "${!SCENARIOS[@]}"; do
    scen="${SCENARIOS[$i]}"
    workers="${SCENARIO_WORKERS[$i]}"
    avg=${TIMES_AVG[$i]}
    throughput=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_FRAMES * 1000) / $avg}")

    short_label="${scen} (Python, ${workers})"
    echo "\"$short_label\" $avg $throughput" >> "$DAT_FILE"
done

echo "  [✓] File data gnuplot: $DAT_FILE"

if command -v gnuplot &> /dev/null; then
    cd "$SCRIPT_DIR"
    if [ -f "plot_results.gp" ]; then
        gnuplot plot_results.gp
        echo "  [✓] Grafik berhasil dibuat"
    else
        echo "  [!] plot_results.gp tidak ditemukan, buat file tersebut untuk generate grafik."
    fi
else
    echo "  [!] GNUPLOT tidak ditemukan. Install: brew install gnuplot (macOS)"
    echo "      Atau buat plot manual dari $DAT_FILE"
fi

echo ""
echo "============================================================================="
echo "                    BENCHMARK PYTHON SELESAI"
echo "============================================================================="
echo ""
