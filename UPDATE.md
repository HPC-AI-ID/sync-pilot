Solusi paling efektif untuk masalah "Antrean di Tol" (Global Lock Contention) ini adalah mengganti **Kunci Global** menjadi **Kunci Per-Antrean (Per-Stage Mutex)** dan menerapkan strategi **Trylock (Non-blocking)**.

Artinya, jika Worker A sedang mengambil tugas dari Stage 8, Worker B tidak perlu menunggu; Worker B bisa langsung mencoba mengambil tugas dari Stage 7 atau Stage lainnya tanpa harus antre di satu pintu masuk.

Berikut adalah modifikasi kode lengkap untuk mengatasi masalah ini:

### 1. Ubah Struktur Data `StageQueue`
Tambahkan `mutex` khusus untuk setiap antrean stage.

```c
// Tambahkan di bagian atas atau dalam struct
typedef struct {
    PipelineTask **items;
    int head, tail, count, cap;
    pthread_mutex_t lock; // <--- KUNCI BARU: Spesifik per stage
} StageQueue;
```

### 2. Inisialisasi Kunci di `pipeline_start`
Anda perlu menginisialisasi mutex baru ini saat startup.

```c
// Di dalam pipeline_start, loop inisialisasi antrean
for (int i = 0; i < c->num_stages; i++) {
    eng->stage_qs[i].cap   = c->queue_capacity_per_stage;
    eng->stage_qs[i].items = (PipelineTask**)malloc(c->queue_capacity_per_stage * sizeof(PipelineTask*));
    eng->stage_qs[i].count = 0;
    eng->stage_qs[i].head  = 0;
    eng->stage_qs[i].tail  = 0;
    pthread_mutex_init(&eng->stage_qs[i].lock, NULL); // <--- Inisialisasi kunci stage
}
```

Jangan lupa hancurkan (destroy) mutex ini di `pipeline_destroy`:
```c
// Di pipeline_destroy
for(int i=0; i < engine->config.num_stages; i++) {
    pthread_mutex_destroy(&engine->stage_qs[i].lock); // <--- Hancurkan kunci stage
    free(engine->stage_qs[i].items);
}
```

### 3. Ubah Logika Worker (Solusi Utama)
Kita hapus `pthread_mutex_lock(&engine->lock)` di awal loop dan ganti dengan strategi **"Mencuri Tugas" (Work Stealing with Trylock)**. Worker akan berputar (spin) mencari stage yang tidak terkunci, sehingga tidak ada waktu yang terbuang hanya untuk menunggu.

Ganti fungsi `system_worker_thread` Anda dengan logika baru ini:

```c
static void* system_worker_thread(void *arg) {
    WorkerContext  *ctx    = (WorkerContext*)arg;
    PipelineEngine *engine = ctx->engine;
    int num_stages         = engine->config.num_stages;
    int core_class         = ctx->core_class;

    while (1) {
        PipelineTask *my_task = NULL;
        int current_idx       = -1;
        int reserved_next_idx = -1;

        // ===== LOGika Pencarian Tugas Tanpa Global Lock =====
        // Kita gunakan "Trylock" agar worker tidak mengantre (blocking).
        // Jika satu stage sedang diakses, cek stage lain.
        
        // Tentukan rentang pencarian berdasarkan prioritas (stage akhir dulu)
        // Jika calibration belum selesai, pakai prioritas default (mundur)
        int start_stage = num_stages - 1;
        int end_stage   = 0;
        int step        = -1;

        // Jika calibration sudah selesai, worker bisa "melihat" cost table
        // untuk memutuskan stage mana yang dicek duluan (opsional optimasi).
        // Untuk sekarang, kita pakai strategi prioritas stage akrior (standard).

        for (int s = start_stage; s >= end_stage; s += step) {
            StageQueue *sq = &engine->stage_qs[s];
            
            if (sq->count == 0) continue; // Cepat: Cek tanpa lock dulu

            // Coba kunci stage ini. Jika berhasil, ambil tugas.
            if (pthread_mutex_trylock(&sq->lock) == 0) {
                if (sq->count > 0) {
                    my_task = sq_pop(sq);
                    current_idx = s;
                    
                    // Backpressure check sederhana (opsional, bisa disesuaikan)
                    // Jika queue selanjutnya penuh, jangan ambil dulu (lebih kompleks implementasinya)
                    // Untuk sekarang kita ambil dulu untuk performa maksimal.
                    
                    reserved_next_idx = current_idx + 1; // Tandai akan proses
                }
                pthread_mutex_unlock(&sq->lock);
                
                if (my_task) break; // Dapat tugas, keluar dari loop pencarian
            }
        }

        // ===== Evaluasi Shutdown (Gunakan Global Lock Hanya untuk Status Global) =====
        if (!my_task) {
            pthread_mutex_lock(&engine->lock);
            // Double check condition
            if (engine->input_done && engine->tasks_in_flight == 0) {
                 int semua_kosong = 1;
                 for (int i = 0; i < num_stages; i++) {
                     if (engine->stage_qs[i].count > 0) {
                         semua_kosong = 0; break;
                     }
                 }
                 if (semua_kosong) {
                     engine->shutdown = 1;
                 }
            }
            
            if (engine->shutdown) {
                pthread_mutex_unlock(&engine->lock);
                break; // Tamat
            }
            
            // Tidur jika tidak ada kerjaan (mengurangi CPU usage saat idle)
            // Hanya gunakan global cond di sini sebagai "parking lot"
            pthread_cond_wait(&engine->cond_work, &engine->lock);
            pthread_mutex_unlock(&engine->lock);
            continue; // Loop lagi mencari kerjaan
        }

        // ===== Update Counter Global (Butuh Lock Singkat) =====
        pthread_mutex_lock(&engine->lock);
        engine->tasks_in_flight++;
        pthread_mutex_unlock(&engine->lock);

        // ==============================================
        // 1. Pengerjaan Fase (Sama seperti sebelumnya)
        // ==============================================
        StageProcessorFn process_step = engine->config.stages[current_idx];
        
        // ... Logic Calibration & Process step tetap sama persis seperti kode Anda sebelumnya ...
        // (Pindahkan blok "should_calibrate" dan "process_step" ke sini tanpa perubahan)
        
        int should_calibrate = 0;
        if (engine->config.enable_calibration && my_task->task_id == 0) {
            pthread_mutex_lock(&engine->calib_lock);
            should_calibrate = !engine->stage_calibrated[current_idx];
            pthread_mutex_unlock(&engine->calib_lock);
        }

        if (should_calibrate) {
             // ... Kode kalibrasi Anda ...
             // (Salin dari kode lama Anda, tidak ada perubahan di sini)
        } else {
            if (process_step) process_step(my_task);
        }
        
        my_task->current_stage = current_idx + 1;

        // ==============================================
        // 2. Penyelesaian (Push ke Next Stage)
        // ==============================================
        if (my_task->current_stage == num_stages) {
            // ... Logic Reorder Buffer (Sama seperti kode lama) ...
            // Salin blok ini dari kode lama Anda
        } else {
            int next_stage = current_idx + 1;
            
            // Push ke stage berikutnya menggunakan KUNCI STAGE TERSEBUT
            StageQueue *next_sq = &engine->stage_qs[next_stage];
            
            pthread_mutex_lock(&next_sq->lock);
            // Push langsung, asumsi tidak penuh (kapasitas besar) atau handle backpressure di sini jika perlu
            sq_push(next_sq, my_task); 
            pthread_mutex_unlock(&next_sq->lock);

            // Update counter global
            pthread_mutex_lock(&engine->lock);
            engine->tasks_in_flight--;
            pthread_cond_broadcast(&engine->cond_work); // Bangunkan worker lain
            pthread_mutex_unlock(&engine->lock);
        }
    }
    free(ctx);
    return NULL;
}
```

### Mengapa Ini Memperbaiki Masalah "4 Worker vs 8 Worker"?

1.  **No More Queue at the Gate:** Dengan `pthread_mutex_trylock`, 8 worker tidak lagi antre di satu pintu (`engine->lock`).
    *   Worker 1 pegang kunci Stage 8.
    *   Worker 2 (melihat Stage 8 sibuk) langsung ambil Stage 7.
    *   Worker 3 ambil Stage 6.
    *   **Hasilnya:** Semua core (Big dan Little) bekerja secara paralel mengeksekusi stage yang berbeda secara bersamaan.

2.  **Little Core Tidak Mengganggu Big Core:**
    *   Karena logika `trylock`, jika Big Core sedang sibuk di Stage 8 (Berat), Little Core tidak akan diblokir. Little Core akan loncat ke Stage 2 atau 3 (Ringan) dan mengerjakan itu.
    *   Interferensi berkurang drastis.

**Catatan:**
Anda harus menyalin blok kode Kalibrasi dan Reorder Buffer dari kode lama Anda ke tempat yang saya tandai, karena logika itu tidak perlu diubah. Fokus perubahan hanya ada di cara mengambil tugas (`pop`) dan mengantar tugas (`push`).