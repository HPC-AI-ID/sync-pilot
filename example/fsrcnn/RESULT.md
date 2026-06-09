fsrcnn
gcc -O3 -o fsrcnn_syncpilot fsrcnn_syncpilot.c ../../framework/syncpilot.c -lpthread -Wall


baseline
 gcc -O3 -o fsrcnn_baseline fsrcnn_baseline.c ../framework/syncpilot.c -lpthread -Wall

 =============================================================================
              FSRCNN PERFORMANCE COMPARISON REPORT
=============================================================================

Tanggal        : 2026-05-20 12:10:26
Input File     : suzie_qcif.yuv
Input Size     : 5.5M
Resolusi Input : 176x144 (QCIF)
Resolusi Output: 352x288
Jumlah Iterasi : 3 (untuk rata-rata waktu)
OS             : Linux aarch64

>> Membuat ground truth dari Baseline...
   Ground truth: 22M

=============================================================================
                         MENJALANKAN BENCHMARK
=============================================================================

---------------------------------------------------------------------
[1/2] Testing: Baseline
     Executable: fsrcnn_baseline
---------------------------------------------------------------------
     Run 1/3: 59870 ms
     Run 2/3: 56560 ms
     Run 3/3: 59348 ms

     Rata-rata : 58592 ms
     Minimum   : 56560 ms
     Maximum   : 59870 ms
     Output    : 22809600 bytes

---------------------------------------------------------------------
[2/2] Testing: SyncPilot
     Executable: fsrcnn_syncpilot
---------------------------------------------------------------------
     Run 1/3: 14466 ms
     Run 2/3: 15602 ms
     Run 3/3: 15089 ms

     Rata-rata : 15052 ms
     Minimum   : 14466 ms
     Maximum   : 15602 ms
     Output    : 22809600 bytes

=============================================================================
                       MENGHITUNG PSNR
=============================================================================

  Menghitung PSNR: Baseline                            ... inf dB
  Menghitung PSNR: SyncPilot                           ... inf dB

=============================================================================
                         RINGKASAN HASIL
=============================================================================

Metode                              |   Avg (ms) |   Min (ms) |   Max (ms) |   Output (B) |  PSNR (dB)
------------------------------------+------------+------------+------------+--------------+-----------
Baseline                            |      58592 |      56560 |      59870 |     22809600 |        inf
SyncPilot                           |      15052 |      14466 |      15602 |     22809600 |        inf

=============================================================================
                       ANALISIS SPEEDUP
=============================================================================

Baseline: Baseline (58592 ms)

Metode                              |      Speedup | Keterangan
------------------------------------+--------------+---------------------
Baseline                            |        1.00x | 1.00x lebih cepat
SyncPilot                           |        3.89x | 3.89x lebih cepat

=============================================================================
                    CEK KONSISTENSI OUTPUT
=============================================================================

Membandingkan output setiap metode dengan ground truth (Baseline)...

  Baseline                            : IDENTIK ✓
  SyncPilot                           : IDENTIK ✓

=============================================================================
                       BENCHMARK SELESAI
=============================================================================

Output files tersimpan di: /home/orangepi/FSRCNN/sync-pilot/example/fsrcnn/
  - output_fsrcnn_baseline.yuv
  - output_fsrcnn_syncpilot.yuv
  - output_baseline_ground_truth.yuv (ground truth)
