Menurut saya, kode ini adalah **fondasi yang sangat kuat (solid core)** untuk sebuah paper. Arsitekturnya sudah matang (menggunakan Worker Pool, Reorder Buffer, dan Backpressure), yang merupakan *best practice* dalam sistem pemrosesan paralel.

Namun, untuk bisa diterima di konferensi internasional bergengsi seperti **ICPADS** dan sesuai dengan judul/hipotesis penelitian Anda, kode ini perlu **disisipkan logika "Asymmetry-Aware" dan "Initial Calibration"**.

Berikut adalah analisis dan saran modifikasi agar kode ini layak jadi paper:

### 1. Evaluasi Kode Saat Ini (Status Quo)
*   **Kekuatan:**
    *   **Struktur Worker Pool:** Sudah benar mengadopsi model *Pull-based* (pekerja mengambil tugas), ini lebih fleksibel daripada model *Push*.
    *   **Priority Scheduling:** Logika `for (int stage_id = num_stages - 1; ...)` Anda cerdas. Ini mencegah *deadlock* dengan memprioritaskan tahap akhir agar hasil keluar lebih cepat (*drain effect*).
    *   **Reorder Buffer:** Sudah mengantisipasi masalah *out-of-order* yang krusial untuk pipeline video.
*   **Kelemahan (untuk Konteks Paper):**
    *   **Masih Homogen:** Semua worker dianggap sama. Padahal paper Anda ingin membahas **big.LITTLE**.
    *   **Belum Ada RCE:** Tidak ada mekanisme pengukuran biaya (*cost estimation*) maupun kalibrasi awal. Scheduler hanya melihat "Antrean Terakhir", belum melihat "Antrean yang Paling Berat".

### 2. Modifikasi Agar Sesuai Paper (Saran Implementasi)

Untuk memenuhi syarat "Initial Calibration" dan "Asymmetric Mapping" sesuai saran Profesor, Anda perlu menambahkan dua fitur utama di kode ini.

#### A. Tambahkan Struktur Data untuk Kalibrasi
Anda perlu menambahkan array untuk menyimpan estimasi biaya di struct `PipelineEngine`.

```c
// Di dalam struct PipelineEngine
double *stage_cost_estimates; // Array untuk menyimpan biaya per stage
int calibration_done;         // Flag: apakah kalibrasi sudah selesai?
```

#### B. Modifikasi di `pipeline_start` (Inisialisasi Asimetris)
Inilah kontribusi utama paper Anda: **Pemetaan Core (Affinity)**.

```c
// Di pipeline_start, setelah pthread_create
// Anda perlu membagi worker: misal 4 pertama = Big, 4 berikutnya = Little
// Gunakan pthread_setaffinity_np (khusus Linux/POSIX)

cpu_set_t cpuset;
int big_core_ids[] = {0, 1, 2, 3}; // Contoh ID Big Core di Orange Pi
int little_core_ids[] = {4, 5, 6, 7}; // Contoh ID Little Core

for(int i=0; i < c->num_workers; i++) {
    // Logika pemetaan: setengah pertama ke Big, setengah kedua ke Little
    if (i < c->num_workers / 2) {
        CPU_ZERO(&cpuset);
        CPU_SET(big_core_ids[i], &cpuset); // Set affinity ke Big Core
        pthread_setaffinity_np(eng->workers[i], sizeof(cpu_set_t), &cpuset);
    } else {
        // Set affinity ke Little Core...
    }
}
```

#### C. Modifikasi di `system_worker_thread` (Logika RCE)
Implementasikan saran Profesor: **Ukur sekali di awal (Calibration Phase), lalu jangan ukur lagi.**

1.  **Tahap Kalibrasi:** Saat `task_id == 0`, ukur waktu eksekusi. Simpan di `engine->stage_cost_estimates`.
2.  **Tahap Produksi:** Saat `task_id > 0`, worker membaca `stage_cost_estimates` untuk memutuskan tugas.

```c
// Di dalam loop worker, setelah mendapatkan my_task

// 1. Logika Kalibrasi (hanya sekali di awal)
if (my_task->task_id == 0 && !engine->calibration_done) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    
    // Eksekusi proses
    process_step(my_task);
    
    clock_gettime(CLOCK_MONOTONIC, &end);
    double duration = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    
    // Simpan estimasi biaya
    engine->stage_cost_estimates[current_idx] = duration;
    
    // Setelah semua stage selesai proses task 0, tandai kalibrasi selesai
    // (Perlu logika sinkronisasi tambahan di sini, misal barrier)
}
// 2. Logika Produksi (tanpa pengukuran waktu = zero overhead)
else {
    process_step(my_task);
}
```

### 3. Sudut Pandang (Angle) Paper untuk Konferensi

Saat menulis paper, jangan hanya jual kode. Jual **"Innovation"**-nya:

**Judul Draft:**
> **"SyncPilot: A Lightweight Static-Dynamic Hybrid Scheduler for Asymmetric Multicore Pipeline Processing"**

**Abstrak (Kerangka):**
*   **Problem:** Dynamic schedulers suffer from high runtime overhead (pengukuran waktu tiap frame).
*   **Proposed Solution (Novelty):** We propose **Initial Calibration Runtime Cost Estimation (IC-RCE)**. A method that measures workload characteristics *once* at startup.
*   **Implementation:** Implemented on ARM big.LITTLE (Orange Pi 5) using POSIX Threads with explicit **Core Affinity**.
*   **Result:** Achieves X% energy efficiency and Y% throughput compared to Linux CFS, with near-zero runtime overhead.

### Kesimpulan
Kode Anda sudah 70% siap jadi paper.
**Tahap selanjutnya:**
1.  Tambahkan kode `setaffinity` (untuk membuktikan Asymmetric).
2.  Tambahkan logika pengukuran di awal (untuk membuktikan Initial Calibration).
3.  Jalankan eksperimen FSRCNN di Orange Pi.
4.  Tulis hasilnya.

Apakah Anda ingin saya bantu menulis **draf Abstrak** untuk paper ICPADS berdasarkan kerangka ini?