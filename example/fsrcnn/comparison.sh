#!/bin/bash
###############################################################################
# comparison.sh - FSRCNN Performance & Energy Comparison Script
# 
# Menguji skenario A, B, C, D FSRCNN dengan input yang sama,
# mengukur waktu eksekusi, throughput, konsumsi daya (PowerTop), dan PSNR.
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
    "C"
)

LABELS=(
    "Baseline (fsrcnn_baseline, parallel)"
    "A (Static Pipeline, 8 thr)"
    "B (SyncPilot, 4 workers)"
    "C (SyncPilot, 8 workers)"
)

# Executable yang digunakan tiap skenario: baseline atau syncpilot
SCENARIO_RUNNERS=(baseline syncpilot syncpilot syncpilot)

# Konfigurasi argumen untuk fsrcnn_syncpilot: <num_workers> <enable_static_pipeline>
SCENARIO_WORKERS=(8 8 4 8)
SCENARIO_STATIC=(0 1 0 0)

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

# ===================== CEK POWEROP =====================
HAS_POWER=0
if command -v powertop &> /dev/null; then
    # Cek apakah running sebagai root/sudo
    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
        HAS_POWER=1
        echo "PowerTop terdeteksi dan memiliki akses root/sudo. Pengukuran energi aktif."
    else
        echo "WARNING: PowerTop ditemukan tetapi membutuhkan hak akses root/sudo."
        echo "Silakan jalankan script ini dengan 'sudo bash comparison.sh' untuk mengaktifkan pengukuran energi."
    fi
else
    echo "WARNING: PowerTop tidak ditemukan. Pengukuran energi dinonaktifkan."
fi
echo ""

# ===================== FUNGSI UTILITAS =====================

# Fungsi untuk mengekstrak daya dari CSV PowerTop
extract_power() {
    local csv_file="$1"
    if [ ! -f "$csv_file" ]; then
        echo "0"
        return
    fi
    local line
    line=$(grep -i "System baseline power" "$csv_file" | head -n 1)
    if [ -z "$line" ]; then
        line=$(grep -i -E "system is using|baseline power" "$csv_file" | head -n 1)
    fi
    if [ -z "$line" ]; then
        echo "0"
        return
    fi
    
    local power_val
    power_val=$(echo "$line" | grep -oE '[0-9]+(\.[0-9]+)?\s*(W|mW|uW|µW|Watts)' | head -n 1)
    if [ -z "$power_val" ]; then
        power_val=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
        if [ -z "$power_val" ]; then
            power_val=$(echo "$line" | grep -oE '[0-9]+' | head -n 1)
        fi
        echo "$power_val"
        return
    fi
    
    local num
    num=$(echo "$power_val" | grep -oE '[0-9]+(\.[0-9]+)?')
    if echo "$power_val" | grep -i -q "mW"; then
        awk "BEGIN {print $num / 1000}"
    elif echo "$power_val" | grep -i -q -E "uW|µW"; then
        awk "BEGIN {print $num / 1000000}"
    else
        echo "$num"
    fi
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
    local is_static="$4"

    if [ "$runner" = "baseline" ]; then
        OMP_NUM_THREADS="$workers" "${SCRIPT_DIR}/fsrcnn_baseline" "$INPUT_PATH" "$output_file" > /dev/null 2>&1
    else
        "${SCRIPT_DIR}/fsrcnn_syncpilot" "$INPUT_PATH" "$output_file" "$workers" "$is_static" > /dev/null 2>&1
    fi
}

# ===================== PENGUKURAN IDLE POWER =====================
POWER_IDLE=0
if [ $HAS_POWER -eq 1 ]; then
    echo ">> Mengukur daya IDLE sistem selama 5 detik sebagai baseline..."
    sudo powertop --csv="${SCRIPT_DIR}/powertop_idle.csv" --time=5 >/dev/null 2>&1 || true
    POWER_IDLE=$(extract_power "${SCRIPT_DIR}/powertop_idle.csv")
    echo "   Daya Idle Sistem: $POWER_IDLE W"
    echo ""
fi

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
declare -a POWERS
declare -a ENERGIES

for i in "${!SCENARIOS[@]}"; do
    scen="${SCENARIOS[$i]}"
    label="${LABELS[$i]}"
    runner="${SCENARIO_RUNNERS[$i]}"
    workers="${SCENARIO_WORKERS[$i]}"
    is_static="${SCENARIO_STATIC[$i]}"
    
    output_file="${SCRIPT_DIR}/output_scenario_${scen}.yuv"
    OUTPUT_FILES[$i]="$output_file"
    
    echo "---------------------------------------------------------------------"
    echo "Skenario ${label}"
    if [ "$runner" = "baseline" ]; then
        echo "     Config: executable=fsrcnn_baseline, OMP_NUM_THREADS=${workers}"
    else
        echo "     Config: executable=fsrcnn_syncpilot, workers=${workers}, static_mode=${is_static}"
    fi
    echo "---------------------------------------------------------------------"
    
    total_time=0
    min_time=999999999
    max_time=0
    t_power_sec=5
    POWERS[$i]=0

    for ((run=1; run<=NUM_RUNS; run++)); do
        rm -f "$output_file"

        if [ "$run" -eq 2 ] && [ $HAS_POWER -eq 1 ]; then
            printf "     Memulai PowerTop (%d detik)...\n" "$t_power_sec"
            sudo powertop --csv="${SCRIPT_DIR}/powertop_${scen}.csv" --time="$t_power_sec" >/dev/null 2>&1 &
            POWER_PID=$!
            sleep 1
        fi

        start_time=$(get_time_ms)
        run_scenario "$runner" "$output_file" "$workers" "$is_static"
        end_time=$(get_time_ms)

        elapsed=$((end_time - start_time))
        total_time=$((total_time + elapsed))
        [ $elapsed -lt $min_time ] && min_time=$elapsed
        [ $elapsed -gt $max_time ] && max_time=$elapsed

        if [ "$run" -eq 1 ]; then
            printf "     Run %d/%d (Profil): %d ms\n" "$run" "$NUM_RUNS" "$elapsed"

            # Hitung waktu powertop yang aman berdasarkan run 1.
            t_power_sec=$((elapsed / 1000 + 4))
            if [ $t_power_sec -lt 5 ]; then
                t_power_sec=5
            fi
        elif [ "$run" -eq 2 ]; then
            printf "     Run %d/%d (Power) : %d ms\n" "$run" "$NUM_RUNS" "$elapsed"
        else
            printf "     Run %d/%d (Normal): %d ms\n" "$run" "$NUM_RUNS" "$elapsed"
        fi

        if [ "$run" -eq 2 ] && [ $HAS_POWER -eq 1 ]; then
            wait $POWER_PID || true
            # Ekstrak daya rata-rata.
            p_avg=$(extract_power "${SCRIPT_DIR}/powertop_${scen}.csv")
            POWERS[$i]=$p_avg
        fi
    done
    
    # Hitung rata-rata
    avg_time=$((total_time / NUM_RUNS))
    TIMES_AVG[$i]=$avg_time
    TIMES_MIN[$i]=$min_time
    TIMES_MAX[$i]=$max_time
    
    # Hitung daya & energi
    if [ $HAS_POWER -eq 1 ]; then
        p_avg=${POWERS[$i]}
        p_net=$(awk "BEGIN {print $p_avg - $POWER_IDLE}")
        # Cegah nilai negatif
        if (( $(awk "BEGIN {print ($p_net < 0) ? 1 : 0}") )); then
            p_net=0
        fi
        # Energi Net = Daya Net * Durasi PowerTop
        e_net=$(awk "BEGIN {print $p_net * $t_power_sec}")
        
        # Waktu eksekusi rata-rata dalam detik
        avg_sec=$(awk "BEGIN {print $avg_time / 1000}")
        # Estimasi daya rata-rata sistem saat eksekusi
        p_exec=$(awk "BEGIN {print $POWER_IDLE + ($e_net / $avg_sec)}")
        # Energi eksekusi total (Joule)
        e_exec=$(awk "BEGIN {print $p_exec * $avg_sec}")
        
        POWERS[$i]=$(awk "BEGIN {printf \"%.2f\", $p_exec}")
        ENERGIES[$i]=$(awk "BEGIN {printf \"%.2f\", $e_exec}")
    else
        POWERS[$i]="N/A"
        ENERGIES[$i]="N/A"
    fi
    
    # Ukuran output
    if [ -f "$output_file" ]; then
        OUTPUT_SIZES[$i]=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo "0")
    else
        OUTPUT_SIZES[$i]=0
    fi
    
    echo ""
    printf "     Rata-rata : %d ms\n" "$avg_time"
    printf "     Daya      : %s W\n" "${POWERS[$i]}"
    printf "     Energi    : %s J\n" "${ENERGIES[$i]}"
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
printf "%-30s | %10s | %10s | %10s | %15s | %12s | %10s | %10s\n" \
    "Skenario" "Avg (ms)" "Min (ms)" "Max (ms)" "Throughput(fps)" "Avg Power(W)" "Energy (J)" "PSNR (dB)"
printf "%-30s-+-%10s-+-%10s-+-%10s-+-%15s-+-%12s-+-%10s-+-%10s\n" \
    "------------------------------" "----------" "----------" "----------" "---------------" "------------" "----------" "----------"

for i in "${!SCENARIOS[@]}"; do
    label="${LABELS[$i]}"
    avg=${TIMES_AVG[$i]}
    throughput=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_FRAMES * 1000) / $avg}")
    
    printf "%-30s | %10d | %10d | %10d | %15s | %12s | %10s | %10s\n" \
        "${label}" \
        "${TIMES_AVG[$i]}" \
        "${TIMES_MIN[$i]}" \
        "${TIMES_MAX[$i]}" \
        "${throughput}" \
        "${POWERS[$i]}" \
        "${ENERGIES[$i]}" \
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
echo "# Skenario Time_ms Throughput_fps Energy_J" > "$DAT_FILE"

for i in "${!SCENARIOS[@]}"; do
    scen="${SCENARIOS[$i]}"
    runner="${SCENARIO_RUNNERS[$i]}"
    workers="${SCENARIO_WORKERS[$i]}"
    is_static="${SCENARIO_STATIC[$i]}"
    avg=${TIMES_AVG[$i]}
    throughput=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_FRAMES * 1000) / $avg}")
    energy="${ENERGIES[$i]}"
    if [ "$energy" = "N/A" ]; then
        energy="?"
    fi

    if [ "$runner" = "baseline" ]; then
        short_label="${scen} (Baseline, ${workers}t)"
    elif [ "$is_static" -eq 1 ]; then
        short_label="${scen} (Static, ${workers}t)"
    else
        short_label="${scen} (SyncPilot, ${workers}w)"
    fi

    echo "\"$short_label\" $avg $throughput $energy" >> "$DAT_FILE"
done
echo "  [✓] File data gnuplot berhasil diperbarui di: $DAT_FILE"

if command -v gnuplot &> /dev/null; then
    # Masuk ke folder script agar gambar output tersimpan di sana
    cd "$SCRIPT_DIR"
    gnuplot plot_results.gp
    echo "  [✓] Grafik throughput (fsrcnn_throughput.png), waktu (fsrcnn_time.png), dan energi (fsrcnn_energy.png) berhasil digenerate!"
else
    echo "  [!] WARNING: gnuplot tidak ditemukan di sistem Anda."
    echo "      Silakan install gnuplot atau jalankan secara manual menggunakan file plot_results.gp"
fi
echo ""

echo "============================================================================="
echo "                       BENCHMARK SELESAI"
echo "============================================================================="
echo ""
