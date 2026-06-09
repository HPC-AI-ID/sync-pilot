# Analisis Percepatan FSRCNN SyncPilot 8 Worker

Dokumen ini menjelaskan mengapa konfigurasi 8 worker belum lebih cepat dari 4 worker pada FSRCNN di Orange Pi, serta arah perbaikan agar 8 worker bisa memberikan throughput lebih tinggi.

## Masalah Utama

Secara logika, 8 worker seharusnya bisa memakai seluruh CPU. Namun pada platform heterogeneous big.LITTLE, CPU 100% tidak otomatis berarti throughput maksimum.

Pada FSRCNN, konfigurasi 4 worker kemungkinan besar berjalan dominan di big cores. Konfigurasi 8 worker melibatkan big cores dan little cores. Jika little core ikut memproses pekerjaan yang berada di critical path, waktu output frame bisa tertahan walaupun semua CPU terlihat aktif.

## Mengapa 8 Worker Bisa Lebih Lambat

### 1. Little Core Masuk Critical Path

Pipeline FSRCNN tetap harus menghasilkan frame secara berurutan. Jika frame lebih awal diproses lambat oleh little core pada stage berat, frame-frame berikutnya bisa selesai lebih dulu tetapi tetap menunggu di reorder buffer.

Dalam kasus ini, reorder buffer bukan penyebab utama. Reorder buffer hanya memperlihatkan efek tail latency dari task yang lebih lambat.

### 2. IC-RCE Masih Per-Layer, Belum Per-Core

IC-RCE saat ini mengukur biaya tiap layer, misalnya:

```text
cost[layer]
```

Namun pada big.LITTLE, biaya layer bergantung pada jenis core. Estimasi yang lebih tepat adalah:

```text
cost[layer][big]
cost[layer][little]
```

Layer yang terlihat ringan pada big core bisa tetap mahal pada little core.

### 3. Worker 8 Menambah Sinkronisasi

Semakin banyak worker, semakin sering terjadi:

```text
lock/unlock queue
condition variable wakeup
akses shared queue
reorder buffer wait
cache miss
memory bandwidth contention
```

Jika overhead ini lebih besar daripada kontribusi little core, maka 8 worker bisa lebih lambat daripada 4 worker.

### 4. Layer Berat Tidak Dipecah Cukup Halus

FSRCNN memiliki stage berat, terutama layer 7 dan layer 8. Jika satu layer untuk satu frame masih dikerjakan oleh satu worker, tambahan worker tidak selalu mempercepat bottleneck utama.

Untuk membuat 8 core benar-benar berguna, layer berat perlu dipecah menjadi unit kerja yang lebih kecil, misalnya tile spatial atau channel block.

## Strategi Agar 8 Worker Bisa Lebih Cepat

### 1. Pin Big dan Little Core Secara Eksplisit

Pada Orange Pi 5, topologi umum adalah:

```text
cpu0-3 = little cores
cpu4-7 = big cores
```

Worker harus dipin sejak awal pembuatan thread, bukan setelah thread sudah berjalan. Gunakan `pthread_attr_setaffinity_np()` sebelum `pthread_create()` agar worker tidak sempat berjalan di core yang salah saat fase kalibrasi.

### 2. Buat Two-Pool Scheduler

Pisahkan worker menjadi dua pool:

```text
Big worker pool:
  layer berat, critical path, frame prioritas awal

Little worker pool:
  layer ringan, backlog non-kritis, tile kecil
```

Tujuannya adalah 4 big workers tetap menangani critical path, sedangkan 4 little workers membantu pekerjaan ringan tanpa mengganggu output berurutan.

### 3. Terapkan IC-RCE Per Core Class

Kalibrasi perlu membedakan biaya layer di big dan little core:

```text
cost_big[layer]
cost_little[layer]
```

Setelah itu scheduler bisa membuat keputusan seperti:

```text
if layer is heavy:
    schedule to big core
else:
    schedule to little core or any idle worker
```

### 4. Batasi Work Stealing

Work stealing tetap berguna, tetapi harus dibatasi:

```text
Big core:
  boleh mencuri pekerjaan ringan jika tidak ada stage berat

Little core:
  hanya boleh mencuri pekerjaan berat jika backlog sangat besar
  atau jika pekerjaan tersebut tidak berada pada critical output order
```

Tanpa batas ini, little core bisa mengambil layer berat dan memperlambat frame yang sedang ditunggu reorder buffer.

### 5. Pecah Layer 8 Secara Tile-Based

Layer 8 adalah kandidat optimasi utama. Pembagian per channel membantu, tetapi belum tentu cache-friendly. Alternatif yang lebih baik:

```text
layer 8 dibagi per tile spatial
big core mengerjakan tile besar atau tile critical
little core mengerjakan tile kecil atau tile non-kritis
```

Pendekatan tile-based bisa mengurangi cache miss dan membuat kontribusi little core lebih terkendali.

### 6. Kurangi Malloc/Free Per Layer

Saat ini banyak buffer sementara dibuat dan dibebaskan berulang. Pada embedded CPU, `malloc/free` dapat menjadi overhead besar dan memperburuk kontensi antar-worker.

Solusi:

```text
preallocate buffer pool per worker
reuse tmp buffer antar-frame
hindari malloc/free di hot path layer
```

## Rekomendasi Eksperimen

Gunakan konfigurasi berikut untuk membedakan bottleneck:

```text
A = SyncPilot 4 worker
B = SyncPilot 8 worker
C = Hybrid 4 worker + 2 inner thread
D = Hybrid 8 worker + 1 inner thread
E = Hybrid 4 worker + 4 inner thread
F = Two-pool scheduler 4 big + 4 little
```

Interpretasi:

```text
Jika B tetap lambat:
  masalah ada pada pipeline worker, sinkronisasi, atau little-core tail latency.

Jika C/E lebih cepat:
  bottleneck ada pada layer berat dan intra-layer parallelism membantu.

Jika F lebih cepat:
  masalah utama adalah scheduling big/little, bukan jumlah core.
```

## Kesimpulan Sementara

Konfigurasi 4 worker lebih cepat bukan berarti SyncPilot gagal. Hasil tersebut menunjukkan bahwa FSRCNN di Orange Pi lebih sensitif terhadap critical path, bandwidth memori, dan heterogenitas core daripada jumlah worker mentah.

Target desain berikutnya bukan sekadar menjalankan 8 worker bebas, tetapi:

```text
4 big workers = critical path
4 little workers = helper untuk pekerjaan ringan atau tile non-kritis
```

Dengan desain two-pool, IC-RCE per core class, work stealing terbatas, dan optimasi layer 8 berbasis tile, konfigurasi 8 worker memiliki peluang lebih besar untuk mengungguli 4 worker.
