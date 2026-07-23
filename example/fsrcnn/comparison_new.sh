#!/bin/bash
###############################################################################
# comparison.sh - FSRCNN Performance Comparison Script
# 
# Menguji skenario FSRCNN dengan input yang sama,
# mengukur waktu eksekusi, throughput, dan PSNR.
#
# Usage:
#   bash comparison.sh              # build lalu jalankan benchmark penuh
#   bash comparison.sh --build-only # hanya build/cache executable, tanpa eksekusi
###############################################################################

set -e

BUILD_ONLY=0
if [ "${1:-}" = "--build-only" ] || [ "${1:-}" = "build-only" ]; then
    BUILD_ONLY=1
fi

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
NUM_RUNS=8

# Total frames
TOTAL_FRAMES=150

# Ukuran output YUV420p yang diharapkan untuk validasi cache ground truth
EXPECTED_OUTPUT_SIZE=$((OUT_WIDTH * OUT_HEIGHT * 3 / 2 * TOTAL_FRAMES))

# Skenario Percobaan
SCENARIOS=(
    # "BASE"
    "SER"
    "LIT"
    "A"
    "B"
    "C"
    "D"
)

LABELS=(
    # "Baseline (fsrcnn_baseline, parallel)"
    "Serial (fsrcnn_serial, big core pinned)"
    "Serial (fsrcnn_serial_little, little core pinned)"
    "A (SyncPilot, 4 workers)"
    "B (SyncPilot, 8 workers)"
    "C (SyncPilot, 10 workers)"
    "D (SyncPilot, 20 workers)"
)

# SCENARIO_RUNNERS=(baseline serial serial_little syncpilot syncpilot syncpilot syncpilot)
SCENARIO_RUNNERS=(serial serial_little syncpilot syncpilot syncpilot syncpilot)

SCENARIO_WORKERS=(150 150 4 8 10 20)

SCENARIO_INNER_THREADS=(1 1 1 1 1 1)

# ===================== PANDUAN FOTO DAYA =====================
print_power_photo_guide() {
    echo "============================================================================="
    echo "                    PANDUAN FOTO DATA DAYA / POWER METER"
    echo "============================================================================="
    echo "TIDAK perlu foto saat:"
    echo "  - kompilasi/build executable"
    echo "  - mode --build-only/cache build"
    echo "  - pembuatan ground truth"
    echo "  - hitung PSNR, cek konsistensi, dan generate grafik"
    echo ""
    echo "PERLU foto hanya saat terminal menampilkan:"
    echo "  [FOTO DAYA MULAI]  sampai  [FOTO DAYA SELESAI]"
    echo ""
    echo "Catatan: jika hanya ingin build/cache program, jalankan:"
    echo "  bash comparison.sh --build-only"
    echo "============================================================================="
    echo ""
}

print_no_photo_phase() {
    local phase="$1"
    echo "[FOTO DAYA] Tidak perlu foto: ${phase}."
}

print_photo_start() {
    local label="$1"
    local run="$2"
    local total="$3"
    echo ""
    echo "[FOTO DAYA MULAI] Skenario: ${label} | Run ${run}/${total}"
    echo "Ambil/foto data daya sekarang, selama program sedang berjalan."
}

print_photo_end() {
    local label="$1"
    local run="$2"
    local elapsed="$3"
    echo "[FOTO DAYA SELESAI] Skenario: ${label} | Run ${run} selesai (${elapsed} ms)."
    echo "Setelah baris ini, tidak perlu foto sampai ada tanda FOTO DAYA MULAI berikutnya."
}

print_power_photo_guide

# ===================== KOMPILASI =====================
echo "============================================================================="
echo "                          KOMPILASI EXECUTABLE"
echo "============================================================================="
print_no_photo_phase "kompilasi/build executable"
CC="gcc-15"
if ! command -v gcc-15 &> /dev/null; then
    CC="gcc"
fi
echo "Using compiler: $CC"
$CC -O3 -fopenmp -o "${SCRIPT_DIR}/fsrcnn_baseline" "${SCRIPT_DIR}/fsrcnn_baseline.c" -lm
$CC -O3 -o "${SCRIPT_DIR}/fsrcnn_serial" "${SCRIPT_DIR}/fsrcnn_serial.c" -lm
$CC -O3 -o "${SCRIPT_DIR}/fsrcnn_serial_little" "${SCRIPT_DIR}/fsrcnn_serial_little.c" -lm
$CC -O3 -o "${SCRIPT_DIR}/fsrcnn_syncpilot" "${SCRIPT_DIR}/fsrcnn_syncpilot.c" "${SCRIPT_DIR}/../../framework/syncpilot.c" -lpthread -lm
echo "Kompilasi selesai."
echo ""

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo "============================================================================="
    echo "                         MODE BUILD-ONLY / CACHE"
    echo "============================================================================="
    echo "Executable sudah berhasil dibuat."
    echo "Benchmark TIDAK dijalankan, jadi data daya TIDAK perlu difoto."
    echo "Jalankan tanpa --build-only jika sudah siap mengukur eksekusi:"
    echo "  bash comparison.sh"
    echo "============================================================================="
    echo ""
    exit 0
fi

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

get_file_size() {
    local file="$1"
    stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0"
}

run_scenario() {
    local runner="$1"
    local output_file="$2"
    local workers="$3"
    local inner_threads="${4:-1}"

    if [ "$runner" = "baseline" ]; then
        OMP_NUM_THREADS="$workers" "${SCRIPT_DIR}/fsrcnn_baseline" "$INPUT_PATH" "$output_file" > /dev/null 2>&1
    elif [ "$runner" = "serial" ]; then
        "${SCRIPT_DIR}/fsrcnn_serial" "$INPUT_PATH" "$output_file" "$TOTAL_FRAMES" > /dev/null 2>&1
    elif [ "$runner" = "serial_little" ]; then
        "${SCRIPT_DIR}/fsrcnn_serial_little" "$INPUT_PATH" "$output_file" "$TOTAL_FRAMES" > /dev/null 2>&1
    elif [ "$runner" = "hybrid" ]; then
        "${SCRIPT_DIR}/fsrcnn_syncpilot_hybrid" "$INPUT_PATH" "$output_file" "$workers" "$inner_threads" > /dev/null 2>&1
    elif [ "$runner" = "twopool" ]; then
        "${SCRIPT_DIR}/fsrcnn_syncpilot_twopool" "$INPUT_PATH" "$output_file" "$workers" > /dev/null 2>&1
    else
        "${SCRIPT_DIR}/fsrcnn_syncpilot" "$INPUT_PATH" "$output_file" "$workers" > /dev/null 2>&1
    fi
}

# ===================== GROUND TRUTH GENERATION =====================
GROUND_TRUTH="${SCRIPT_DIR}/output_baseline_ground_truth.yuv"
print_no_photo_phase "pembuatan ground truth pembanding"

if [ -f "$GROUND_TRUTH" ]; then
    ground_truth_size=$(get_file_size "$GROUND_TRUTH")
else
    ground_truth_size=0
fi

if [ "$ground_truth_size" -eq "$EXPECTED_OUTPUT_SIZE" ]; then
    echo ">> Ground truth sudah ada, pakai cache: ${GROUND_TRUTH}"
    echo "   Ukuran: $(du -h "$GROUND_TRUTH" | awk '{print $1}')"
else
    if [ "$ground_truth_size" -gt 0 ]; then
        echo ">> Ground truth cache tidak valid (${ground_truth_size} bytes, expected ${EXPECTED_OUTPUT_SIZE}), membuat ulang..."
    else
        echo ">> Membuat ground truth dari Baseline (fsrcnn_baseline)..."
    fi
    "${SCRIPT_DIR}/fsrcnn_baseline" "$INPUT_PATH" "$GROUND_TRUTH" > /dev/null 2>&1
    echo "   Ground truth selesai: $(du -h "$GROUND_TRUTH" | awk '{print $1}')"
fi
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
    inner_threads="${SCENARIO_INNER_THREADS[$i]}"
    
    output_file="${SCRIPT_DIR}/output_scenario_${scen}.yuv"
    OUTPUT_FILES[$i]="$output_file"
    
    echo "---------------------------------------------------------------------"
    echo "Skenario ${label}"
    if [ "$runner" = "baseline" ]; then
        echo "     Config: executable=fsrcnn_baseline, OMP_NUM_THREADS=${workers}"
    elif [ "$runner" = "serial" ]; then
        echo "     Config: executable=fsrcnn_serial, big core pinned, ${TOTAL_FRAMES} frames"
    elif [ "$runner" = "serial_little" ]; then
        echo "     Config: executable=fsrcnn_serial_little, little core pinned, ${TOTAL_FRAMES} frames"
    elif [ "$runner" = "hybrid" ]; then
        echo "     Config: executable=fsrcnn_syncpilot_hybrid, workers=${workers}, inner_threads=${inner_threads}"
    elif [ "$runner" = "twopool" ]; then
        echo "     Config: executable=fsrcnn_syncpilot_twopool, workers=${workers}, mode=4 big + 4 little"
    else
        echo "     Config: executable=fsrcnn_syncpilot, workers=${workers}"
    fi
    echo "---------------------------------------------------------------------"
    
    total_time=0
    min_time=999999999
    max_time=0

    for ((run=1; run<=NUM_RUNS; run++)); do
        rm -f "$output_file"

        print_photo_start "$label" "$run" "$NUM_RUNS"
        start_time=$(get_time_ms)
        run_scenario "$runner" "$output_file" "$workers" "$inner_threads"
        end_time=$(get_time_ms)

        elapsed=$((end_time - start_time))
        total_time=$((total_time + elapsed))
        [ $elapsed -lt $min_time ] && min_time=$elapsed
        [ $elapsed -gt $max_time ] && max_time=$elapsed
        print_photo_end "$label" "$run" "$elapsed"

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
        OUTPUT_SIZES[$i]=$(get_file_size "$output_file")
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
print_no_photo_phase "menghitung PSNR"
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
echo "                       ANALISIS SPEEDUP (vs Big Core Serial)"
echo "============================================================================="
echo ""

serial_idx=-1
serial_little_idx=-1
for i in "${!SCENARIOS[@]}"; do
    if [ "${SCENARIO_RUNNERS[$i]}" = "serial" ]; then
        serial_idx=$i
    elif [ "${SCENARIO_RUNNERS[$i]}" = "serial_little" ]; then
        serial_little_idx=$i
    fi
done

if [ "$serial_idx" -ge 0 ] && [ "$serial_little_idx" -ge 0 ]; then
    serial_time=${TIMES_AVG[$serial_idx]}
    little_time=${TIMES_AVG[$serial_little_idx]}
    if [ "$little_time" -gt 0 ] && [ "$serial_time" -gt 0 ]; then
        big_vs_little=$(awk "BEGIN {printf \"%.2f\", $serial_time / $little_time}")
        echo "SPEEDUP FACTOR [Big vs Little]: ${big_vs_little}x (Big=${serial_time}ms / Little=${little_time}ms)"
    else
        echo "SPEEDUP FACTOR [Big vs Little]: N/A"
    fi
    echo ""
fi

serial_time=${TIMES_AVG[$serial_idx]}
printf "Serial (Big): %s (%d ms)\n\n" "${LABELS[$serial_idx]}" "$serial_time"
printf "%-30s | %12s | %s\n" "Skenario" "Speedup" "Keterangan"
printf "%-30s-+-%12s-+-%s\n" "------------------------------" "------------" "--------------------"

for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    avg=${TIMES_AVG[$i]}

    if [ "$avg" -gt 0 ]; then
        speedup=$(awk "BEGIN {printf \"%.2f\", $serial_time / $avg}")
        if (( $(awk "BEGIN {print ($speedup >= 1.0) ? 1 : 0}") )); then
            keterangan="${speedup}x lebih cepat dari Serial"
        else
            slowdown=$(awk "BEGIN {printf \"%.2f\", $avg / $serial_time}")
            keterangan="${slowdown}x lebih lambat dari Serial"
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
print_no_photo_phase "cek konsistensi output"
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
print_no_photo_phase "menulis data dan membuat grafik"
echo ""
DAT_FILE="${SCRIPT_DIR}/benchmark_data.dat"
echo "# Skenario Time_ms Throughput_fps" > "$DAT_FILE"

for i in "${!SCENARIOS[@]}"; do
    scen="${SCENARIOS[$i]}"
    runner="${SCENARIO_RUNNERS[$i]}"
    workers="${SCENARIO_WORKERS[$i]}"
    inner_threads="${SCENARIO_INNER_THREADS[$i]}"
    avg=${TIMES_AVG[$i]}
    throughput=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_FRAMES * 1000) / $avg}")

    if [ "$runner" = "baseline" ]; then
        short_label="${scen} (Baseline, ${workers}t)"
    elif [ "$runner" = "serial" ]; then
        short_label="${scen} (Serial, big core)"
    elif [ "$runner" = "serial_little" ]; then
        short_label="${scen} (Serial, little core)"
    elif [ "$runner" = "hybrid" ]; then
        short_label="${scen} (Hybrid, ${workers}w+${inner_threads}i)"
    elif [ "$runner" = "twopool" ]; then
        short_label="${scen} (Two-pool, 4b+4l)"
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
