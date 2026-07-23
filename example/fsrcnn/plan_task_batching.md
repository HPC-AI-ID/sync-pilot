Jika Anda ingin mengejar performa puncak dan "memeras" silikon ASUS GX10 agar mendekati hitungan teoretis 1:1,84 (ekspektasi speedup ~11x), maka kita harus menghilangkan "Lock Contention" (Tabrakan Kunci) secara agresif.

Saat 20 worker berdesakan mengambil tugas, mereka mengunci dan membuka fungsi pthread_mutex_lock(&sq->lock) dan pthread_mutex_lock(&engine->lock) satu per satu untuk setiap frame. Ini membuang waktu komputasi yang sangat besar hanya untuk urusan administratif antrean.

Solusi HPC paling masuk akal tanpa harus merombak seluruh struktur SyncPilot adalah menerapkan Task Batching (Pemborongan Tugas).

Konsep Task Batching
Daripada 1 worker mengambil 1 frame, memprosesnya, lalu menaruhnya kembali ke antrean (mengunci mutex 2x per frame), kita menyuruh worker untuk mengambil 4 hingga 8 frame sekaligus dalam satu tarikan napas.

Keuntungan 1: Mengurangi frekuensi mutex lock hingga 80%.

Keuntungan 2: Meningkatkan Cache Locality (RAM tidak melompat-lompat, worker memproses tugas yang sama secara beruntun).

Berikut adalah modifikasi kodenya. Anda cukup mengganti blok-blok fungsi lama dengan kode di bawah ini di dalam syncpilot.c:

1. Tambahkan Konstanta Batch & Fungsi Antrean Baru
Taruh ini di bagian atas file, di bawah definisi StageQueue:

C
#define BATCH_SIZE 8 // Ambil maksimal 8 tugas sekaligus untuk menekan Mutex

// Fungsi Push Borongan
static int sq_push_batch(StageQueue *sq, PipelineTask **tasks, int count) {
    if (sq->count + count > sq->cap) return 0;
    for (int i = 0; i < count; i++) {
        sq->items[sq->tail] = tasks[i];
        sq->tail = (sq->tail + 1) % sq->cap;
    }
    sq->count += count;
    return count;
}

// Fungsi Pop Borongan
static int sq_pop_batch(StageQueue *sq, PipelineTask **tasks, int max_count) {
    int taken = 0;
    while (taken < max_count && sq->count > 0) {
        tasks[taken++] = sq->items[sq->head];
        sq->head = (sq->head + 1) % sq->cap;
        sq->count--;
    }
    return taken;
}
2. Ganti Fungsi try_take_task_from_stages
Ganti fungsi lama Anda dengan versi borongan (batch) ini:

C
static int try_take_batch_from_stages(PipelineEngine *engine, int core_class, int steal_mode, PipelineTask **tasks, int *stage_idx, int *reserved_next_idx) {
    int num_stages = engine->config.num_stages;

    for (int stage_id = num_stages - 1; stage_id >= 0; stage_id--) {
        StageQueue *sq = &engine->stage_qs[stage_id];
        if (pthread_mutex_trylock(&sq->lock) != 0) continue;
        if (sq->count == 0) { pthread_mutex_unlock(&sq->lock); continue; }

        int urgent_backlog = sq->count > (sq->cap / 2);
        pthread_mutex_lock(&engine->calib_lock);
        int preferred = stage_matches_worker_preference_locked(engine, stage_id, core_class, steal_mode, urgent_backlog);
        pthread_mutex_unlock(&engine->calib_lock);
        if (!preferred) { pthread_mutex_unlock(&sq->lock); continue; }

        int next_stage = stage_id + 1;
        int can_take = 0;
        
        if (next_stage < num_stages) {
            StageQueue *next_sq = &engine->stage_qs[next_stage];
            if (pthread_mutex_trylock(&next_sq->lock) != 0) {
                pthread_mutex_unlock(&sq->lock); continue;
            }

            pthread_mutex_lock(&engine->lock);
            int available_space = next_sq->cap - (next_sq->count + engine->reserved_slots[next_stage]);
            
            // Batasi pengambilan: Sebesar BATCH_SIZE atau sisa ruang antrean
            can_take = (available_space > BATCH_SIZE) ? BATCH_SIZE : available_space;
            if (can_take > sq->count) can_take = sq->count;

            if (can_take > 0) {
                engine->reserved_slots[next_stage] += can_take; // Pesan tempat sekaligus banyak
                *reserved_next_idx = next_stage;
            }
            pthread_mutex_unlock(&engine->lock);
            pthread_mutex_unlock(&next_sq->lock);
        } else {
            // Tahap akhir, ambil sebanyak BATCH_SIZE atau isi antrean
            can_take = (sq->count > BATCH_SIZE) ? BATCH_SIZE : sq->count;
        }

        if (can_take <= 0) {
            pthread_mutex_unlock(&sq->lock); continue;
        }

        // Ambil secara borongan!
        int taken = sq_pop_batch(sq, tasks, can_take);
        *stage_idx = stage_id;
        
        pthread_mutex_lock(&engine->lock);
        engine->tasks_in_flight += taken;
        pthread_cond_broadcast(&engine->cond_space);
        pthread_mutex_unlock(&engine->lock);
        
        pthread_mutex_unlock(&sq->lock);
        return taken;
    }

    return 0;
}
3. Ganti system_worker_thread (Fungsi Eksekutor Utama)
Ganti fungsi lama Anda agar sanggup mengeksekusi kumpulan array (batch) yang diambil dari fungsi di atas:

C
static void* system_worker_thread(void *arg) {
    WorkerContext  *ctx    = (WorkerContext*)arg;
    PipelineEngine *engine = ctx->engine;
    int num_stages         = engine->config.num_stages;
    int core_class         = ctx->core_class;

    while (1) {
        PipelineTask *my_tasks[BATCH_SIZE];
        int taken_count       = 0;
        int current_idx       = -1;
        int reserved_next_idx = -1;

        taken_count = try_take_batch_from_stages(engine, core_class, 0, my_tasks, &current_idx, &reserved_next_idx);
        if (taken_count == 0) {
            taken_count = try_take_batch_from_stages(engine, core_class, 1, my_tasks, &current_idx, &reserved_next_idx);
        }

        if (taken_count == 0) {
            pthread_mutex_lock(&engine->lock);
            int can_shutdown = engine->input_done && engine->tasks_in_flight == 0;
            pthread_mutex_unlock(&engine->lock);

            if (can_shutdown && all_stage_queues_empty(engine)) {
                pthread_mutex_lock(&engine->lock);
                if (engine->input_done && engine->tasks_in_flight == 0) {
                    engine->shutdown = 1;
                    signal_work_locked(engine);
                }
                pthread_mutex_unlock(&engine->lock);
            }

            pthread_mutex_lock(&engine->lock);
            if (engine->shutdown) {
                pthread_mutex_unlock(&engine->lock);
                break;
            }

            int seen_work_seq = engine->work_seq;
            while (!engine->shutdown && seen_work_seq == engine->work_seq) {
                pthread_cond_wait(&engine->cond_work, &engine->lock);
            }
            pthread_mutex_unlock(&engine->lock);
            continue;
        }

        // ====== 1. Eksekusi Borongan (Looping Lokal Tanpa Lock) ======
        StageProcessorFn process_step = engine->config.stages[current_idx];

        for (int b = 0; b < taken_count; b++) {
            PipelineTask *task = my_tasks[b];
            int should_calibrate = 0;

            if (engine->config.enable_calibration && task->task_id == 0) {
                pthread_mutex_lock(&engine->calib_lock);
                should_calibrate = !engine->stage_calibrated[current_idx];
                pthread_mutex_unlock(&engine->calib_lock);
            }

            if (should_calibrate) {
                struct timespec cal_start, cal_end;
                clock_gettime(CLOCK_MONOTONIC, &cal_start);
                if (process_step) process_step(task);
                clock_gettime(CLOCK_MONOTONIC, &cal_end);
                
                double duration = (cal_end.tv_sec - cal_start.tv_sec) + (cal_end.tv_nsec - cal_start.tv_nsec) / 1e9;
                
                pthread_mutex_lock(&engine->calib_lock);
                if (!engine->stage_calibrated[current_idx]) {
                    engine->stage_calibrated[current_idx] = 1;
                    engine->stage_cost_estimates[current_idx] = duration;
                    engine->stages_calibrated++;
                }
                if (engine->stages_calibrated >= engine->config.num_stages) {
                    engine->calibration_done = 1;
                    pthread_cond_broadcast(&engine->calib_cond);
                    pthread_mutex_lock(&engine->lock);
                    signal_work_locked(engine);
                    pthread_mutex_unlock(&engine->lock);
                }
                pthread_mutex_unlock(&engine->calib_lock);
            } else {
                if (process_step) process_step(task);
            }
            task->current_stage = current_idx + 1;
        }

        // ====== 2. Lempar Borongan ke Tahap Berikutnya =======
        if (current_idx + 1 == num_stages) {
            // Langsung lempar semua ke Reorder Buffer
            FinalReorderBuffer *rb = engine->reorder;
            pthread_mutex_lock(&rb->lock);
            for (int b = 0; b < taken_count; b++) {
                rb->slots[my_tasks[b]->task_id] = my_tasks[b];
            }
            pthread_cond_broadcast(&rb->cond);
            pthread_mutex_unlock(&rb->lock);

            // Laporkan tugas selesai
            pthread_mutex_lock(&engine->lock);
            engine->tasks_in_flight -= taken_count;
            int can_shutdown = engine->input_done && engine->tasks_in_flight == 0;
            pthread_mutex_unlock(&engine->lock);
            
            if (can_shutdown && all_stage_queues_empty(engine)) {
                pthread_mutex_lock(&engine->lock);
                if (engine->input_done && engine->tasks_in_flight == 0) {
                    engine->shutdown = 1;
                    signal_work_locked(engine);
                }
                pthread_mutex_unlock(&engine->lock);
            }

            pthread_mutex_lock(&engine->lock);
            pthread_cond_broadcast(&engine->cond_space);
            pthread_mutex_unlock(&engine->lock);

        } else {
            // Masukkan borongan ke queue berikutnya
            int next_stage = current_idx + 1;
            StageQueue *next_sq = &engine->stage_qs[next_stage];

            pthread_mutex_lock(&next_sq->lock);
            if (!sq_push_batch(next_sq, my_tasks, taken_count)) {
                fprintf(stderr, "SyncPilot internal error: reserved stage queue penuh\n");
                abort();
            }
            pthread_mutex_unlock(&next_sq->lock);

            pthread_mutex_lock(&engine->lock);
            if (reserved_next_idx == next_stage) {
                engine->reserved_slots[next_stage] -= taken_count;
            }
            engine->tasks_in_flight -= taken_count; // Keluar dari ruang kerja thread
            signal_work_locked(engine);
            pthread_cond_broadcast(&engine->cond_space);
            pthread_mutex_unlock(&engine->lock);
        }
    }
    free(ctx);
    return NULL;
}