#!/bin/bash
###############################################################################
# comparison.sh - FSRCNN Performance Comparison Script
# 
# Menguji skenario FSRCNN dengan input yang sama,
# mengukur waktu eksekusi, throughput, dan PSNR.
#
# Usage: bash comparison.sh
###############################################################################

set -e

# ===================== KONFIGURASI =====================
INPUT_FILE="suzie_qcif.yuv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_PATH="${SCRIPT_DIR}/${INPUT_FILE}"

# Resolusi QCIF
WIDTH=176
HEIGHT=144

# Upscale factor (2x)
OUT_WIDTH=$((WIDTH * 2))
OUT_HEIGHT=$((HEIGHT * 2))

# Jumlah iterasi untuk rata-rata waktu
NUM_RUNS=3

# Total frames
TOTAL_FRAMES=150

# Skenario Percobaan
SCENARIOS=(
    "BASE"
    "A"
    "B"
)

LABELS=(
    "Baseline (fsrcnn_baseline, parallel)"
    "A (SyncPilot, 4 workers)"
    "B (SyncPilot, 8 workers)"
)

# Executable yang digunakan tiap skenario: baseline atau syncpilot
SCENARIO_RUNNERS=(baseline syncpilot syncpilot)

# Konfigurasi argumen untuk fsrcnn_syncpilot: <num_workers>
SCENARIO_WORKERS=(8 4 8)

# ===================== KOMPILASI =====================
echo "============================================================================="
echo "                          KOMPILASI EXECUTABLE"
echo "============================================================================="
CC="gcc-15"
if ! command -v gcc-15 &> /dev/null; then
    CC="gcc"
fi
echo "Using compiler: $CC"
$CC -O3 -fopenmp -o "${SCRIPT_DIR}/fsrcnn_baseline" "${SCRIPT_DIR}/fsrcnn_baseline.c" -lm
$CC -O3 -o "${SCRIPT_DIR}/fsrcnn_syncpilot" "${SCRIPT_DIR}/fsrcnn_syncpilot.c" "${SCRIPT_DIR}/../../framework/syncpilot.c" -lpthread -lm
echo "Kompilasi selesai."
echo ""

# ===================== VALIDASI INPUT =====================
if [ ! -f "$INPUT_PATH" ]; then
    echo "ERROR: Input file '${INPUT_FILE}' tidak ditemukan di ${SCRIPT_DIR}"
    exit 1
fi

# ===================== FUNGSI UTILITAS =====================

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
        echo "ffmpeg not found"
    fi
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

run_scenario() {
    local runner="$1"
    local output_file="$2"
    local workers="$3"

    if [ "$runner" = "baseline" ]; then
        OMP_NUM_THREADS="$workers" "${SCRIPT_DIR}/fsrcnn_baseline" "$INPUT_PATH" "$output_file" > /dev/null 2>&1
    else
        "${SCRIPT_DIR}/fsrcnn_syncpilot" "$INPUT_PATH" "$output_file" "$workers" > /dev/null 2>&1
    fi
}

# ===================== GROUND TRUTH GENERATION =====================
GROUND_TRUTH="${SCRIPT_DIR}/output_baseline_ground_truth.yuv"
echo ">> Membuat ground truth dari Baseline (fsrcnn_baseline)..."
"${SCRIPT_DIR}/fsrcnn_baseline" "$INPUT_PATH" "$GROUND_TRUTH" > /dev/null 2>&1
echo "   Ground truth selesai: $(du -h "$GROUND_TRUTH" | awk '{print $1}')"
echo ""

# ===================== EKSEKUSI SKENARIO =====================
echo "============================================================================="
echo "                         MENJALANKAN BENCHMARK"
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
    echo "Skenario ${label}"
    if [ "$runner" = "baseline" ]; then
        echo "     Config: executable=fsrcnn_baseline, OMP_NUM_THREADS=${workers}"
    else
        echo "     Config: executable=fsrcnn_syncpilot, workers=${workers}"
    fi
    echo "---------------------------------------------------------------------"
    
    total_time=0
    min_time=999999999
    max_time=0

    for ((run=1; run<=NUM_RUNS; run++)); do
        rm -f "$output_file"

        start_time=$(get_time_ms)
        run_scenario "$runner" "$output_file" "$workers"
        end_time=$(get_time_ms)

        elapsed=$((end_time - start_time))
        total_time=$((total_time + elapsed))
        [ $elapsed -lt $min_time ] && min_time=$elapsed
        [ $elapsed -gt $max_time ] && max_time=$elapsed

        if [ "$run" -eq 1 ]; then
            printf "     Run %d/%d (Profil): %d ms\n" "$run" "$NUM_RUNS" "$elapsed"
        else
            printf "     Run %d/%d (Normal): %d ms\n" "$run" "$NUM_RUNS" "$elapsed"
        fi
    done
    
    # Hitung rata-rata
    avg_time=$((total_time / NUM_RUNS))
    TIMES_AVG[$i]=$avg_time
    TIMES_MIN[$i]=$min_time
    TIMES_MAX[$i]=$max_time
    
    # Ukuran output
    if [ -f "$output_file" ]; then
        OUTPUT_SIZES[$i]=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo "0")
    else
        OUTPUT_SIZES[$i]=0
    fi
    
    echo ""
    printf "     Rata-rata : %d ms\n" "$avg_time"
    echo ""
done

# ===================== MENGHITUNG PSNR =====================
echo "============================================================================="
echo "                       MENGHITUNG PSNR"
echo "============================================================================="
echo ""

declare -a PSNR_VALUES
for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    output_file="${OUTPUT_FILES[$i]}"
    
    printf "  Menghitung PSNR: %-30s ... " "${label}"
    psnr=$(calculate_psnr "$GROUND_TRUTH" "$output_file")
    PSNR_VALUES[$i]="$psnr"
    echo "$psnr dB"
done
echo ""

# ===================== TABEL RINGKASAN =====================
echo "============================================================================="
echo "                         RINGKASAN HASIL"
echo "============================================================================="
echo ""

# Header tabel
printf "%-30s | %10s | %10s | %10s | %15s | %10s\n" \
    "Skenario" "Avg (ms)" "Min (ms)" "Max (ms)" "Throughput(fps)" "PSNR (dB)"
printf "%-30s-+-%10s-+-%10s-+-%10s-+-%15s-+-%10s\n" \
    "------------------------------" "----------" "----------" "----------" "---------------" "----------"

for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    avg=${TIMES_AVG[$i]}
    throughput=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_FRAMES * 1000) / $avg}")
    
    printf "%-30s | %10d | %10d | %10d | %15s | %10s\n" \
        "${label}" \
        "${TIMES_AVG[$i]}" \
        "${TIMES_MIN[$i]}" \
        "${TIMES_MAX[$i]}" \
        "${throughput}" \
        "${PSNR_VALUES[$i]}"
done
echo ""

# ===================== SPEEDUP ANALYSIS =====================
echo "============================================================================="
echo "                       ANALISIS SPEEDUP"
echo "============================================================================="
echo ""

baseline_time=${TIMES_AVG[0]}
printf "Baseline: %s (%d ms)\n\n" "${LABELS[0]}" "$baseline_time"
printf "%-30s | %12s | %s\n" "Skenario" "Speedup" "Keterangan"
printf "%-30s-+-%12s-+-%s\n" "------------------------------" "------------" "--------------------"

for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    avg=${TIMES_AVG[$i]}
    
    if [ "$avg" -gt 0 ]; then
        speedup=$(awk "BEGIN {printf \"%.2f\", $baseline_time / $avg}")
        if (( $(awk "BEGIN {print ($speedup >= 1.0) ? 1 : 0}") )); then
            keterangan="${speedup}x lebih cepat"
        else
            slowdown=$(awk "BEGIN {printf \"%.2f\", $avg / $baseline_time}")
            keterangan="${slowdown}x lebih lambat"
        fi
    else
        speedup="N/A"
        keterangan="Error"
    fi
    
    printf "%-30s | %12s | %s\n" "${label}" "${speedup}x" "$keterangan"
done
echo ""

# ===================== CEK KONSISTENSI =====================
echo "============================================================================="
echo "                    CEK KONSISTENSI OUTPUT"
echo "============================================================================="
echo ""
for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    output_file="${OUTPUT_FILES[$i]}"
    
    if [ -f "$output_file" ] && [ -f "$GROUND_TRUTH" ]; then
        if cmp -s "$GROUND_TRUTH" "$output_file"; then
            printf "  %-30s : IDENTIK ✓\n" "${label}"
        else
            diff_bytes=$(cmp -l "$GROUND_TRUTH" "$output_file" 2>/dev/null | wc -l | tr -d ' ')
            printf "  %-30s : BERBEDA ✗ (%s bytes berbeda)\n" "${label}" "$diff_bytes"
        fi
    else
        printf "  %-30s : FILE TIDAK DITEMUKAN\n" "${label}"
    fi
done
echo ""

# ===================== GENERATOR DATA GNUPLOT DILANJUTKAN AUTOMATIS =====================
echo "============================================================================="
echo "                  MENULIS DATA & MEMBUAT GRAFIK (GNUPLOT)"
echo "============================================================================="
echo ""
DAT_FILE="${SCRIPT_DIR}/benchmark_data.dat"
echo "# Skenario Time_ms Throughput_fps" > "$DAT_FILE"

for i in "${!SCENARIOS[@]}"; do
    scen="${SCENARIOS[$i]}"
    runner="${SCENARIO_RUNNERS[$i]}"
    workers="${SCENARIO_WORKERS[$i]}"
    avg=${TIMES_AVG[$i]}
    throughput=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_FRAMES * 1000) / $avg}")

    if [ "$runner" = "baseline" ]; then
        short_label="${scen} (Baseline, ${workers}t)"
    else
        short_label="${scen} (SyncPilot, ${workers}w)"
    fi

    echo "\"$short_label\" $avg $throughput" >> "$DAT_FILE"
done
echo "  [✓] File data gnuplot berhasil diperbarui di: $DAT_FILE"

if command -v gnuplot &> /dev/null; then
    # Masuk ke folder script agar gambar output tersimpan di sana
    cd "$SCRIPT_DIR"
    gnuplot plot_results.gp
    echo "  [✓] Grafik throughput (fsrcnn_throughput.png) dan waktu (fsrcnn_time.png) berhasil digenerate!"
else
    echo "  [!] WARNING: gnuplot tidak ditemukan di sistem Anda."
    echo "      Silakan install gnuplot atau jalankan secara manual menggunakan file plot_results.gp"
fi
echo ""

echo "============================================================================="
echo "                       BENCHMARK SELESAI"
echo "============================================================================="
echo ""
