# paperdata — pengumpulan data pendukung paper

Satu skrip, sekali jalan, hasilnya satu direktori bertanggal.

```bash
cd sync-pilot/example/fsrcnn/paperdata
bash collect.sh
```

Perkiraan waktu **15–20 menit** dengan setelan bawaan (10 repetisi).

Setelah selesai skrip mencetak dua path — kirim keduanya:

```
out/<timestamp>/collect.txt    # laporan lengkap, terbaca manusia
out/<timestamp>/data.csv       # baris data saja, untuk diparsing
```

## Kenapa skrip ini ada

Audit menemukan tiga masalah provenance pada data lama, semuanya berakar di
dua hal:

1. `comparison_noise.sh` membuang stdout setiap run terukur ke `/dev/null`.
   Padahal `fsrcnn_syncpilot.c:424` **sudah mencetak Cost Table IC-RCE** tiap
   run — jadi data itu dihasilkan lalu langsung dibuang.
2. `logs/fsrcnn_syncpilot.txt` adalah satu file yang **ditimpa** setiap run,
   tanpa identitas skenario. Tidak mungkin tahu satu log berasal dari run mana.

Skrip ini menangkap stdout per run ke file bernama sendiri, dan mencatat
manifest lingkungan supaya angkanya bisa dipertanggungjawabkan.

## Yang dikerjakan

| Fase | Isi | Memperbaiki |
|---|---|---|
| 1 | Environment + manifest (kernel, gcc, governor, freq per core, git SHA) | klaim 3.9/2.8 GHz yang belum terverifikasi |
| 2 | Rasio kapasitas P vs E, beban identik, dipin | klaim 1.83×, kini satu sesi dengan sisanya |
| 3 | **Cost Table sweep** — 1/4/8/10/20W + 20W-notp, 10 repetisi | Tabel III, Fig. 3, argumen partisi di §V-F |
| 4 | perf counters, build `-O3` (bukan `-march=native`) | Tabel IV, kini sebanding dengan benchmark |
| 5 | Isolasi cluster (pengganti EXP-2/3/4) | Tabel V yang sebelumnya tak terlacak |
| 6 | gprof, build `-pg` terpisah | Tabel VI/VII |

## Yang TIDAK disentuh

`comparison_noise.sh` dan hasilnya (`benchmark/05-08-26.md`) — itu sumber
Tabel I dan II, sudah terverifikasi sel per sel, dan **tidak perlu diulang**.
Skrip ini tidak menulis apa pun di luar `paperdata/out/`.

## Opsi

```bash
REPEATS=15 bash collect.sh          # repetisi lebih banyak
SKIP_PERF=1 bash collect.sh         # lewati fase 4–5
SKIP_GPROF=1 bash collect.sh        # lewati fase 6
DROP_CACHES=1 bash collect.sh       # page cache dijatuhkan sebelum run 1 (root)
P_CPUS_OVERRIDE=10-19 E_CPUS_OVERRIDE=0-9 bash collect.sh   # kalau deteksi meleset
```

Skrip mendeteksi cluster dari `cpufreq/cpuinfo_max_freq`. **Periksa baris
"Performance cluster" / "Efficient cluster" di awal keluaran** — kalau salah,
hentikan dan ulangi dengan override, jangan pakai angkanya.

## Catatan metodologi

- **Run 1 tidak dibuang di FASE 3.** Kalibrasi memang peristiwa cold-start;
  membuangnya justru menghilangkan hal yang ingin diukur. Ini berbeda dari
  konvensi timing di `comparison_noise.sh`, dan disengaja.
- FASE 4 memakai `-O3` polos, bukan `-pg -march=native` seperti data lama.
  `-march=native` memilih instruksi yang tidak dipakai binary benchmark,
  sehingga IPC-nya tidak sebanding. FASE 6 tetap `-pg` dan sengaja dipisah.
- `FRAMES` hanya berlaku untuk FASE 2. `fsrcnn_syncpilot` tidak menerima
  argumen jumlah frame, jadi FASE 3 selalu memproses seluruh input.

## Belum tercakup

Dua hal butuh perubahan kode, jadi tidak dimasukkan ke sini:

- **Latensi per-frame (p95/p99).** Satu timestamp per frame di consumer thread.
  Ini limitation terbesar yang tersisa, dan menopang klaim sentral paper soal
  prediktabilitas latensi. Kalau dikerjakan, ia menggantikan `05-08-26.md`,
  bukan menambahnya — jangan dicampur.
- **Reproduksi deadlock gating** pada konfigurasi homogen. Butuh mematikan
  guard single-class di `framework/syncpilot.c` pada branch terpisah.
