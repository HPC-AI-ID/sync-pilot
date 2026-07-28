=============================================================================
                       MENGHITUNG PSNR
=============================================================================
[FOTO DAYA] Tidak perlu foto: menghitung PSNR.

  Menghitung PSNR: Serial (fsrcnn_serial, big core pinned) ... inf dB
  Menghitung PSNR: A (SyncPilot, 4 workers)       ... inf dB
  Menghitung PSNR: B (SyncPilot, 8 workers)       ... inf dB
  Menghitung PSNR: C (SyncPilot, 10 workers)      ... inf dB
  Menghitung PSNR: D (SyncPilot, 20 workers)      ... inf dB

=============================================================================
                         RINGKASAN HASIL
=============================================================================

Skenario                       |   Avg (ms) |   Min (ms) |   Max (ms) | Throughput(fps) |  PSNR (dB)
-------------------------------+------------+------------+------------+-----------------+-----------
Serial (fsrcnn_serial, big core pinned) |      10445 |      10378 |      10483 |           14.36 |        inf
A (SyncPilot, 4 workers)       |       3016 |       2995 |       3049 |           49.73 |        inf
B (SyncPilot, 8 workers)       |       1581 |       1569 |       1592 |           94.88 |        inf
C (SyncPilot, 10 workers)      |       1334 |       1317 |       1348 |          112.44 |        inf
D (SyncPilot, 20 workers)      |       1112 |       1101 |       1139 |          134.89 |        inf

=============================================================================
                       ANALISIS SPEEDUP (Ts/Tp)
=============================================================================

Serial (Ts): Serial (fsrcnn_serial, big core pinned) (10445 ms)

Skenario                       |      Speedup | Keterangan
-------------------------------+--------------+---------------------
Serial (fsrcnn_serial, big core pinned) |        1.00x | 1.00x lebih cepat dari Serial
A (SyncPilot, 4 workers)       |        3.46x | 3.46x lebih cepat dari Serial
B (SyncPilot, 8 workers)       |        6.61x | 6.61x lebih cepat dari Serial
C (SyncPilot, 10 workers)      |        7.83x | 7.83x lebih cepat dari Serial
D (SyncPilot, 20 workers)      |        9.39x | 9.39x lebih cepat dari Serial

=============================================================================
                    CEK KONSISTENSI OUTPUT
=============================================================================
[FOTO DAYA] Tidak perlu foto: cek konsistensi output.

  Serial (fsrcnn_serial, big core pinned) : IDENTIK ✓
  A (SyncPilot, 4 workers)       : IDENTIK ✓
  B (SyncPilot, 8 workers)       : IDENTIK ✓
  C (SyncPilot, 10 workers)      : IDENTIK ✓
  D (SyncPilot, 20 workers)      : IDENTIK ✓

=============================================================================
                  MENULIS DATA & MEMBUAT GRAFIK (GNUPLOT)
=============================================================================
[FOTO DAYA] Tidak perlu foto: menulis data dan membuat grafik.

  [✓] File data gnuplot berhasil diperbarui di: /home/lab_iot/FSRCNN/sync-pilot/example/fsrcnn/benchmark_data.dat
  [✓] Grafik throughput (fsrcnn_throughput.png) dan waktu (fsrcnn_time.png) berhasil digenerate!

=============================================================================
                       BENCHMARK SELESAI
=============================================================================

lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ 

--------------ASUS SPESIFIKASI----------------
lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ gcc --version
gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
Copyright (C) 2023 Free Software Foundation, Inc.
This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ 

lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ cat /etc/os-release
PRETTY_NAME="Ubuntu 24.04.4 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.4 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
UBUNTU_CODENAME=noble
LOGO=ubuntu-logo
lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ 

lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ hostnamectl
 Static hostname: node6
       Icon name: computer-server
         Chassis: server 🖳
      Machine ID: 4e43f891072243d9bf235014c26c7a73
         Boot ID: 53e176df833d4571b36e14f4d2dcdaa4
Operating System: Ubuntu 24.04.4 LTS              
          Kernel: Linux 6.17.0-1018-nvidia
    Architecture: arm64
 Hardware Vendor: ASUSTeK COMPUTER INC.
  Hardware Model: GX10
Firmware Version: GX10DGX.0104.2026.0326.1657
   Firmware Date: Thu 2026-03-26
    Firmware Age: 3month 3w 6d
lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ 

lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ lsb_release -a
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 24.04.4 LTS
Release:        24.04
Codename:       noble
lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ 

lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ uname -r
6.17.0-1018-nvidia
lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ 

lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ lscpu
Architecture:                aarch64
  CPU op-mode(s):            64-bit
  Byte Order:                Little Endian
CPU(s):                      20
  On-line CPU(s) list:       0-19
Vendor ID:                   ARM
  Model name:                Cortex-X925
    Model:                   1
    Thread(s) per core:      1
    Core(s) per socket:      10
    Socket(s):               1
    Stepping:                r0p1
    Frequency boost:         disabled
    CPU(s) scaling MHz:      100%
    CPU max MHz:             3900.0000
    CPU min MHz:             1378.0000
    BogoMIPS:                2000.00
    Flags:                   fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 sm3 sm4 asimddp sha512 sve asimdfhm dit uscat ilrcpc flagm sb paca pacg dcpodp sve2 sveaes svepmull 
                             svebitperm svesha3 svesm4 flagm2 frint svei8mm svebf16 i8mm bf16 dgh bti ecv afp wfxt
  Model name:                Cortex-A725
    Model:                   1
    Thread(s) per core:      1
    Core(s) per socket:      10
    Socket(s):               1
    Stepping:                r0p1
    CPU(s) scaling MHz:      100%
    CPU max MHz:             2808.0000
    CPU min MHz:             338.0000
    BogoMIPS:                2000.00
    Flags:                   fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 sm3 sm4 asimddp sha512 sve asimdfhm dit uscat ilrcpc flagm sb paca pacg dcpodp sve2 sveaes svepmull 
                             svebitperm svesha3 svesm4 flagm2 frint svei8mm svebf16 i8mm bf16 dgh bti ecv afp wfxt
Caches (sum of all):         
  L1d:                       1.3 MiB (20 instances)
  L1i:                       1.3 MiB (20 instances)
  L2:                        25 MiB (20 instances)
  L3:                        24 MiB (2 instances)
NUMA:                        
  NUMA node(s):              1
  NUMA node0 CPU(s):         0-19
Vulnerabilities:             
  Gather data sampling:      Not affected
  Ghostwrite:                Not affected
  Indirect target selection: Not affected
  Itlb multihit:             Not affected
  L1tf:                      Not affected
  Mds:                       Not affected
  Meltdown:                  Not affected
  Mmio stale data:           Not affected
  Old microcode:             Not affected
  Reg file data sampling:    Not affected
  Retbleed:                  Not affected
  Spec rstack overflow:      Not affected
  Spec store bypass:         Mitigation; Speculative Store Bypass disabled via prctl
  Spectre v1:                Mitigation; __user pointer sanitization
  Spectre v2:                Mitigation; CSV2, BHB
  Srbds:                     Not affected
  Tsa:                       Not affected
  Tsx async abort:           Not affected
  Vmscape:                   Not affected
lab_iot@node6:~/FSRCNN/sync-pilot/example/fsrcnn$ 