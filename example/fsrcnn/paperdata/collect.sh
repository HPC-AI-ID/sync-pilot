#!/usr/bin/env bash
# =============================================================================
#  collect.sh — pengumpulan data pendukung paper, sekali jalan.
#
#  Menutup tiga celah provenance yang ditemukan saat audit:
#    FASE 1  Environment + manifest ....... klaim 3.9/2.8 GHz, kernel, gcc, governor
#    FASE 2  Rasio kapasitas P vs E ....... klaim 1.83x, diukur di sesi yang sama
#    FASE 3  Cost Table sweep ............ Tabel III + Fig. 3 + argumen partisi
#    FASE 4  perf counters ............... Tabel IV, flag build SAMA dgn benchmark
#    FASE 5  Isolasi cluster (EXP) ....... Tabel V, sebelumnya tak terlacak
#    FASE 6  gprof ....................... Tabel VI/VII, build -pg terpisah
#
#  YANG TIDAK DISENTUH: comparison_noise.sh dan hasilnya (Tabel I & II).
#  Skrip ini tidak menimpa apa pun di luar foldernya sendiri.
#
#  Pemakaian:
#      bash collect.sh                 # semua fase, 10 repetisi (~15-20 menit)
#      REPEATS=15 bash collect.sh      # lebih banyak repetisi
#      SKIP_PERF=1 bash collect.sh     # lewati FASE 4-5 (kalau perf tak tersedia)
#      SKIP_GPROF=1 bash collect.sh    # lewati FASE 6
#      DROP_CACHES=1 bash collect.sh   # jatuhkan page cache sebelum run 1 (butuh root)
#      P_CPUS_OVERRIDE=10-19 E_CPUS_OVERRIDE=0-9 bash collect.sh   # kalau deteksi meleset
#
#  Hasil: out/<timestamp>/collect.txt  <- ini satu file yang perlu dikirim
#         out/<timestamp>/runlogs/     <- stdout mentah tiap run, untuk audit
#
#  Baris berawalan '#CSV|' sengaja dibuat mudah diparsing.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSDIR="$(cd "${HERE}/.." && pwd)"          # example/fsrcnn
FRAMEWORK="${FSDIR}/../../framework/syncpilot.c"
INPUT="${FSDIR}/suzie_qcif.yuv"

REPEATS="${REPEATS:-10}"
# FRAMES hanya dipakai oleh fsrcnn_serial / fsrcnn_serial_little (FASE 2).
# fsrcnn_syncpilot tidak menerima argumen jumlah frame — ia selalu memproses
# seluruh input, jadi FASE 3 otomatis memakai 150 frame seperti benchmark.
FRAMES="${FRAMES:-150}"
COOLDOWN="${COOLDOWN:-5}"
SKIP_PERF="${SKIP_PERF:-0}"
SKIP_GPROF="${SKIP_GPROF:-0}"
DROP_CACHES="${DROP_CACHES:-0}"
# Override manual kalau deteksi cluster otomatis meleset, mis.:
#   P_CPUS_OVERRIDE=10-19 E_CPUS_OVERRIDE=0-9 bash collect.sh
P_CPUS_OVERRIDE="${P_CPUS_OVERRIDE:-}"
E_CPUS_OVERRIDE="${E_CPUS_OVERRIDE:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${HERE}/out/${STAMP}"
RUNLOGS="${OUTDIR}/runlogs"
BUILD="${OUTDIR}/bin"
SCRATCH="${OUTDIR}/scratch"
REPORT="${OUTDIR}/collect.txt"
DATACSV="${OUTDIR}/data.csv"

mkdir -p "$RUNLOGS" "$BUILD" "$SCRATCH"
: > "$DATACSV"

# Semua keluaran masuk ke REPORT sekaligus tampil di layar.
exec > >(tee -a "$REPORT") 2>&1

banner() {
    echo
    echo "============================================================================="
    echo "  $*"
    echo "============================================================================="
}

now_ms() {
    local t
    t="$(date +%s%3N 2>/dev/null)"
    case "$t" in
        ''|*[!0-9]*) python3 -c 'import time;print(int(time.time()*1000))' ;;
        *) echo "$t" ;;
    esac
}

fail() { echo "!! $*"; }

# Tulis satu baris data ke layar/laporan DAN ke data.csv (tanpa lewat tee,
# supaya hitungan di akhir tidak balapan dengan buffer tee).
emit() { printf '#CSV|%s\n' "$*"; printf '%s\n' "$*" >> "$DATACSV"; }

# ---------------------------------------------------------------- FASE 1
banner "FASE 1 — ENVIRONMENT & MANIFEST"

echo "timestamp        : $(date +%Y-%m-%dT%H:%M:%S%z)"
echo "host             : $(hostname)"
echo "script           : ${BASH_SOURCE[0]}"
echo "repeats          : ${REPEATS}"
echo "frames (FASE 2)  : ${FRAMES}   (FASE 3 selalu seluruh input)"
echo
echo "--- uname -a ---"; uname -a
echo
echo "--- kernel cmdline ---"; cat /proc/cmdline 2>/dev/null || echo "(tidak tersedia)"
echo

CC="gcc-15"; command -v gcc-15 >/dev/null 2>&1 || CC="gcc"
echo "--- compiler ---"; echo "CC=${CC}"; $CC --version | head -1
echo

echo "--- git sync-pilot ---"
if git -C "${FSDIR}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "commit : $(git -C "${FSDIR}" rev-parse HEAD)"
    echo "branch : $(git -C "${FSDIR}" rev-parse --abbrev-ref HEAD)"
    echo "dirty  : $(git -C "${FSDIR}" status --porcelain | wc -l) file termodifikasi"
else
    echo "(bukan git repo)"
fi
echo

echo "--- lscpu ---"; lscpu 2>/dev/null | sed -n '1,30p'
echo

echo "--- per-CPU max freq & governor ---"
P_CPUS=""; E_CPUS=""; MAXF=0; E_MAXF=0
CPU_IDS=""; CPU_FREQS=""
for d in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$d" ] || continue
    c="${d##*/cpu}"
    f="$(cat "$d/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo 0)"
    g="$(cat "$d/cpufreq/scaling_governor" 2>/dev/null || echo '?')"
    CPU_IDS="${CPU_IDS} ${c}"
    CPU_FREQS="${CPU_FREQS} ${c}:${f}"
    [ "$f" -gt "$MAXF" ] && MAXF="$f"
    printf "  cpu%-3s max=%-10s governor=%s\n" "$c" "$f" "$g"
done
for pair in $CPU_FREQS; do
    c="${pair%%:*}"; f="${pair#*:}"
    if [ "$f" = "$MAXF" ] && [ "$MAXF" != "0" ]; then
        P_CPUS="${P_CPUS},${c}"
    else
        E_CPUS="${E_CPUS},${c}"
        E_MAXF="$f"
    fi
done
P_CPUS="${P_CPUS#,}"; E_CPUS="${E_CPUS#,}"

# Pengaman: kalau cpufreq tidak terbaca, semua core jatuh ke satu kelas.
# Pakai fallback yang sama dengan framework (paruh pertama/kedua) dan beri
# peringatan keras, supaya run 20 menit tidak terbuang karena taskset kosong.
if [ -n "$P_CPUS_OVERRIDE" ] && [ -n "$E_CPUS_OVERRIDE" ]; then
    P_CPUS="$P_CPUS_OVERRIDE"; E_CPUS="$E_CPUS_OVERRIDE"
    echo "OVERRIDE MANUAL dipakai: P=${P_CPUS}  E=${E_CPUS}"
fi

NCPU="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 0)"
if [ -z "$P_CPUS" ] || [ -z "$E_CPUS" ]; then
    fail "PERINGATAN: cpufreq tidak terbaca / hanya satu kelas core terdeteksi."
    if [ "$NCPU" -ge 2 ]; then
        half=$(( NCPU / 2 ))
        E_CPUS="$(seq -s, 0 $(( half - 1 )))"
        P_CPUS="$(seq -s, "$half" $(( NCPU - 1 )))"
        fail "Memakai fallback paruh-paruh: E=${E_CPUS}  P=${P_CPUS}"
        fail "PERIKSA INI sebelum memakai angkanya di paper."
    else
        fail "Tidak bisa menentukan cluster. Hentikan."
        exit 1
    fi
fi
P_ONE="${P_CPUS%%,*}"; E_ONE="${E_CPUS%%,*}"

TASKSET_OK=1
if ! command -v taskset >/dev/null 2>&1; then
    TASKSET_OK=0
    fail "taskset TIDAK ADA (paket util-linux). FASE 2 & 5 akan berjalan TANPA"
    fail "pinning — angkanya tidak sah untuk klaim rasio kapasitas di paper."
fi
pin() {  # $1 = daftar cpu; sisanya = perintah
    local cpus="$1"; shift
    if [ "$TASKSET_OK" = "1" ]; then taskset -c "$cpus" "$@"; else "$@"; fi
}
echo
echo "Performance cluster (freq tertinggi = ${MAXF}) : ${P_CPUS}"
echo "Efficient cluster                              : ${E_CPUS}"
emit "env|max_freq_khz|${MAXF}|p_cpus|${P_CPUS}|e_cpus|${E_CPUS}"
emit "env|p_max_khz|${MAXF}|e_max_khz|${E_MAXF}"
if [ "$E_MAXF" != "0" ]; then
    echo "rasio frekuensi nominal P/E : $(awk -v a="$MAXF" -v b="$E_MAXF" 'BEGIN{printf "%.3f", a/b}')"
fi

# ---------------------------------------------------------------- BUILD
banner "BUILD (flag SAMA dengan comparison_noise.sh: -O3, tanpa -march=native)"

BUILD_SP="${CC} -O3 -o ${BUILD}/fsrcnn_syncpilot ${FSDIR}/fsrcnn_syncpilot.c ${FRAMEWORK} -lpthread -lm"
BUILD_SER="${CC} -O3 -o ${BUILD}/fsrcnn_serial ${FSDIR}/fsrcnn_serial.c -lm"
BUILD_LIT="${CC} -O3 -o ${BUILD}/fsrcnn_serial_little ${FSDIR}/fsrcnn_serial_little.c -lm"

echo "$BUILD_SP";  eval "$BUILD_SP"  || { fail "build syncpilot GAGAL"; exit 1; }
echo "$BUILD_SER"; eval "$BUILD_SER" || fail "build serial gagal"
echo "$BUILD_LIT"; eval "$BUILD_LIT" || fail "build serial_little gagal"
echo "Build selesai."

# Bobot/bias dibaca dari direktori kerja -> jalankan dari FSDIR.
cd "$FSDIR" || exit 1

drop_caches_if_asked() {
    [ "$DROP_CACHES" = "1" ] || return 0
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null \
        && echo "   (page cache dijatuhkan)" \
        || echo "   (gagal drop caches — butuh root; dilewati)"
}

# ---------------------------------------------------------------- FASE 2
banner "FASE 2 — RASIO KAPASITAS PERFORMANCE vs EFFICIENT"
echo "Beban identik single-thread, dipin ke satu core tiap cluster."
echo "Ini yang menopang klaim 1.83x dan argumen 'frekuensi != kapasitas'."
echo

CAP_REPEATS=$(( REPEATS < 5 ? REPEATS : 5 ))
for pair in "P:${P_ONE}:fsrcnn_serial" "E:${E_ONE}:fsrcnn_serial_little"; do
    cls="${pair%%:*}"; rest="${pair#*:}"; cpu="${rest%%:*}"; exe="${rest#*:}"
    echo "--- cluster ${cls}, cpu ${cpu}, ${exe} ---"
    for r in $(seq 1 "$CAP_REPEATS"); do
        out="${SCRATCH}/cap_${cls}_${r}.yuv"
        t0="$(now_ms)"
        pin "$cpu" "${BUILD}/${exe}" "$INPUT" "$out" "$FRAMES" \
            > "${RUNLOGS}/cap_${cls}_run${r}.log" 2>&1
        rc=$?
        t1="$(now_ms)"
        ms=$(( t1 - t0 ))
        [ $rc -eq 0 ] || fail "cap ${cls} run ${r} rc=${rc}"
        echo "  run ${r}: ${ms} ms"
        emit "capacity|${cls}|${cpu}|${r}|${ms}"
        rm -f "$out"
        sleep 1
    done
done
echo "(rasio dihitung saat analisis, dari baris #CSV|capacity)"

# ---------------------------------------------------------------- FASE 3
banner "FASE 3 — COST TABLE SWEEP  (INI YANG PALING PENTING)"
cat <<'NOTE'
Setiap run mencetak Cost Table IC-RCE-nya sendiri (fsrcnn_syncpilot.c:424).
Selama ini stdout dibuang ke /dev/null oleh comparison_noise.sh, jadi datanya
hilang. Di sini stdout ditangkap per run.

Catatan metodologi: kalibrasi ADALAH peristiwa cold-start, jadi run 1 TIDAK
dibuang — justru dilaporkan apa adanya bersama run lainnya.
NOTE
echo

# nama|workers|env tambahan
COST_CONFIGS=(
    "1W|1|"
    "4W|4|"
    "8W|8|"
    "10W|10|"
    "20W-gated|20|"
    "20W-notp|20|SYNCPILOT_DISABLE_TWOPOOL=1"
)

for cfg in "${COST_CONFIGS[@]}"; do
    name="${cfg%%|*}"; rest="${cfg#*|}"; workers="${rest%%|*}"; extra="${rest#*|}"
    echo
    echo "--- konfigurasi ${name} (workers=${workers}) ${extra:+[${extra}]} ---"
    for r in $(seq 1 "$REPEATS"); do
        [ "$r" = "1" ] && drop_caches_if_asked
        log="${RUNLOGS}/cost_${name}_run${r}.log"
        out="${SCRATCH}/cost_${name}_${r}.yuv"
        t0="$(now_ms)"
        env ${extra} "${BUILD}/fsrcnn_syncpilot" "$INPUT" "$out" "$workers" > "$log" 2>&1
        rc=$?
        t1="$(now_ms)"
        ms=$(( t1 - t0 ))
        rm -f "$out"

        # Ambil 8 baris "Layer N: X detik" dari Cost Table.
        vals=()
        while IFS= read -r v; do vals+=("$v"); done \
            < <(grep -E '^Layer [1-8]: ' "$log" | awk '{print $3}')
        if [ "${#vals[@]}" -ne 8 ]; then
            fail "  run ${r}: Cost Table tidak lengkap (${#vals[@]}/8) rc=${rc} — cek ${log}"
            emit "cost|${name}|${r}|INCOMPLETE|${ms}"
            continue
        fi
        joined="$(IFS=,; echo "${vals[*]}")"
        echo "  run ${r}: ${ms} ms | ${joined}"
        emit "cost|${name}|${r}|${joined}|${ms}"
        sleep 1
    done
    sleep "$COOLDOWN"
done

echo
echo "Juga dicatat: keputusan two_pool yang dilaporkan framework."
grep -h "two_pool" "${RUNLOGS}"/cost_*_run1.log 2>/dev/null | sort -u || echo "(tidak ada baris two_pool)"

# ---------------------------------------------------------------- FASE 4 & 5
if [ "$SKIP_PERF" = "1" ]; then
    banner "FASE 4-5 — DILEWATI (SKIP_PERF=1)"
elif ! command -v perf >/dev/null 2>&1; then
    banner "FASE 4-5 — DILEWATI (perf tidak ditemukan)"
else
    banner "FASE 4 — PERF COUNTERS (build -O3, sebanding dengan benchmark)"
    echo "Berbeda dari data lama yang memakai '-pg -march=native'."
    echo

    PMU_LIST="$(ls /sys/bus/event_source/devices/ 2>/dev/null | grep -E '^armv8' | sort)"
    echo "PMU terdeteksi:"; echo "$PMU_LIST" | sed 's/^/  /'
    PMU_E="$(echo "$PMU_LIST" | sed -n '1p')"
    PMU_P="$(echo "$PMU_LIST" | sed -n '2p')"
    echo "diasumsikan: cluster Efficient=${PMU_E:-?}  Performance=${PMU_P:-?}"
    echo "(verifikasi lewat daftar cpu di FASE 1 sebelum dipakai di paper)"
    echo

    perf_events() {   # $1 = nama pmu
        echo "${1}/instructions/,${1}/cycles/,${1}/cache-references/,${1}/cache-misses/"
    }

    ALL_EV=""
    [ -n "${PMU_E:-}" ] && ALL_EV="$(perf_events "$PMU_E")"
    [ -n "${PMU_P:-}" ] && ALL_EV="${ALL_EV:+${ALL_EV},}$(perf_events "$PMU_P")"

    for w in 1 4 8 10 20; do
        echo "--- perf stat, ${w} worker ---"
        out="${SCRATCH}/perf_${w}.yuv"
        perf stat -e "$ALL_EV" \
            "${BUILD}/fsrcnn_syncpilot" "$INPUT" "$out" "$w" \
            > "${RUNLOGS}/perf_${w}w.log" 2>&1
        rm -f "$out"
        grep -E 'insn per cycle|cache-misses|cache-references|cycles|instructions|seconds time' \
             "${RUNLOGS}/perf_${w}w.log" | sed 's/^/  /'
        emit "perfrun|${w}|${RUNLOGS}/perf_${w}w.log"
        sleep "$COOLDOWN"
    done

    banner "FASE 5 — ISOLASI CLUSTER (pengganti EXP-2 / EXP-3 / EXP-4)"
    echo "Tiga eksperimen terkendali yang di data lama tidak bisa dilacak."
    echo

    run_exp() {  # $1 nama  $2 taskset-cpus (kosong=default)  $3 events  $4 keterangan
        local nm="$1" cpus="$2" ev="$3" desc="$4"
        echo "--- ${nm}: ${desc} ---"
        local out="${SCRATCH}/${nm}.yuv"
        if [ -n "$cpus" ] && [ "$TASKSET_OK" = "1" ]; then
            perf stat -e "$ev" taskset -c "$cpus" \
                "${BUILD}/fsrcnn_syncpilot" "$INPUT" "$out" 20 \
                > "${RUNLOGS}/${nm}.log" 2>&1
        else
            perf stat -e "$ev" \
                "${BUILD}/fsrcnn_syncpilot" "$INPUT" "$out" 20 \
                > "${RUNLOGS}/${nm}.log" 2>&1
        fi
        rm -f "$out"
        grep -E 'insn per cycle|instructions|cycles|seconds time' "${RUNLOGS}/${nm}.log" | sed 's/^/  /'
        emit "exp|${nm}|${RUNLOGS}/${nm}.log"
        sleep "$COOLDOWN"
    }

    if [ -n "${PMU_P:-}" ]; then
        run_exp "EXP2_P_only_pinned_P" "$P_CPUS" "$(perf_events "$PMU_P")" \
                "20 worker dipaksa hanya ke cluster Performance, counter Performance"
        run_exp "EXP4_full20_counters_P" "" "$(perf_events "$PMU_P")" \
                "20 worker penuh (P+E), counter Performance saja"
    fi
    if [ -n "${PMU_E:-}" ]; then
        run_exp "EXP3_full20_counters_E" "" "$(perf_events "$PMU_E")" \
                "20 worker penuh (P+E), counter Efficient saja"
    fi
fi

# ---------------------------------------------------------------- FASE 6
if [ "$SKIP_GPROF" = "1" ]; then
    banner "FASE 6 — DILEWATI (SKIP_GPROF=1)"
elif ! command -v gprof >/dev/null 2>&1; then
    banner "FASE 6 — DILEWATI (gprof tidak ditemukan)"
else
    banner "FASE 6 — GPROF (build -pg TERPISAH, sengaja tidak sebanding dgn FASE 4)"
    BUILD_PG="${CC} -O3 -pg -o ${BUILD}/fsrcnn_syncpilot_pg ${FSDIR}/fsrcnn_syncpilot.c ${FRAMEWORK} -lpthread -lm"
    echo "$BUILD_PG"
    if eval "$BUILD_PG"; then
        for w in 10 20; do
            echo
            echo "--- gprof, ${w} worker ---"
            gd="${SCRATCH}/gprof_${w}"; mkdir -p "$gd"
            (
                cd "$gd" || exit 1
                for f in "${FSDIR}"/weights_layer*.txt "${FSDIR}"/biasess_layer*.txt; do
                    ln -sf "$f" "$(basename "$f")"
                done
                "${BUILD}/fsrcnn_syncpilot_pg" "$INPUT" "${gd}/out.yuv" "$w" \
                    > "${RUNLOGS}/gprof_${w}w_run.log" 2>&1
            )
            if [ -f "${gd}/gmon.out" ]; then
                gprof "${BUILD}/fsrcnn_syncpilot_pg" "${gd}/gmon.out" \
                    > "${RUNLOGS}/gprof_${w}w.txt" 2>&1
                echo "  20 baris teratas flat profile:"
                sed -n '1,25p' "${RUNLOGS}/gprof_${w}w.txt" | sed 's/^/  /'
                emit "gprof|${w}|${RUNLOGS}/gprof_${w}w.txt"
            else
                fail "  gmon.out tidak dihasilkan untuk ${w}W"
            fi
            rm -f "${gd}/out.yuv"
            sleep "$COOLDOWN"
        done
    else
        fail "build -pg gagal, FASE 6 dilewati"
    fi
fi

# ---------------------------------------------------------------- PENUTUP
banner "SELESAI"
rm -rf "$SCRATCH"
echo "Laporan lengkap : ${REPORT}"
echo "Log mentah      : ${RUNLOGS}"
echo
echo "Ringkasan baris data (dari data.csv):"
for k in env capacity cost perfrun exp gprof; do
    n="$(grep -c "^${k}|" "$DATACSV" 2>/dev/null)" || n=0
    printf "  %-9s : %s\n" "$k" "$n"
done
echo
echo "KIRIM DUA FILE INI:"
echo "  ${REPORT}"
echo "  ${DATACSV}"
echo
echo "TIDAK tercakup skrip ini (butuh ubah kode, dibahas terpisah):"
echo "  - latensi per-frame untuk p95/p99"
echo "  - reproduksi deadlock gating pada konfigurasi homogen"
