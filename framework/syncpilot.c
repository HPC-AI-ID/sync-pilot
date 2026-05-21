#define _GNU_SOURCE
#include <sched.h>
#include "syncpilot.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include <time.h>


#ifdef __linux__
#include <sched.h>  // Untuk CPU_SET, cpu_set_t, pthread_setaffinity_np
#endif

// ==========================================
// Struktur Data Internal Endpoint
// ==========================================

// Antrean Sederhana Per Tahap
typedef struct {
    PipelineTask **items;
    int head, tail, count, cap;
} StageQueue;

static int sq_push(StageQueue *sq, PipelineTask *task) {
    if (sq->count >= sq->cap) return 0; // Penuh
    sq->items[sq->tail] = task;
    sq->tail = (sq->tail + 1) % sq->cap;
    sq->count++;
    return 1;
}

static PipelineTask* sq_pop(StageQueue *sq) {
    if (sq->count == 0) return NULL; // Kosong
    PipelineTask *task = sq->items[sq->head];
    sq->head = (sq->head + 1) % sq->cap;
    sq->count--;
    return task;
}

static PipelineTask* sq_peek(StageQueue *sq) {
    if (sq->count == 0) return NULL;
    return sq->items[sq->head];
}

// Reorder Buffer Internal
typedef struct {
    PipelineTask **slots;
    int size;
    pthread_mutex_t lock;
    pthread_cond_t  cond;
} FinalReorderBuffer;

// Inti Engine Framework (Mewarisi Config)
struct PipelineEngine {
    PipelineConfig  config;
    StageQueue     *stage_qs; // Array of queues [0..num_stages-1]

    pthread_mutex_t lock;
    pthread_cond_t  cond_work;
    pthread_cond_t  cond_space;

    int input_done;
    int shutdown;
    int tasks_in_flight;

    FinalReorderBuffer *reorder;
    pthread_t *workers;
    pthread_t t_consumer;

    int is_shutting_down;     // Status destroy sinkronisasi internal

    // === IC-RCE: Initial Calibration Runtime Cost Estimation ===
    double stage_cost_estimates[MAX_STAGES]; // Waktu eksekusi per stage (detik)
    int    calibration_done;                 // Flag: kalibrasi sudah selesai
    int    stages_calibrated;                // Counter: berapa stage sudah diukur
    pthread_mutex_t calib_lock;              // Lock khusus kalibrasi
    pthread_cond_t  calib_cond;              // Cond untuk sinkronisasi kalibrasi
};

typedef struct {
    PipelineEngine *engine;
    int worker_id;
} WorkerContext;

static int select_dynamic_stage_locked(PipelineEngine *engine) {
    int num_stages = engine->config.num_stages;

    if (engine->config.enable_calibration && !engine->calibration_done) {
        for (int stage_id = num_stages - 1; stage_id >= 0; stage_id--) {
            PipelineTask *candidate = sq_peek(&engine->stage_qs[stage_id]);
            if (candidate && candidate->task_id == 0) {
                return stage_id;
            }
        }
        return -1;
    }

    int best_stage = -1;
    double best_score = -1.0;

    for (int stage_id = num_stages - 1; stage_id >= 0; stage_id--) {
        StageQueue *sq = &engine->stage_qs[stage_id];
        if (sq->count == 0) continue;

        double estimated_cost = engine->stage_cost_estimates[stage_id];
        if (estimated_cost <= 0.0) {
            estimated_cost = 1.0;
        }

        /*
         * IC-RCE priority: heavy stages with backlog get served first.
         * A tiny downstream bias keeps completed-near tasks flowing out.
         */
        double backlog_factor = 1.0 + ((double)sq->count / (double)sq->cap);
        double downstream_bias = (double)stage_id / (double)(num_stages * 1000);
        double score = estimated_cost * backlog_factor + downstream_bias;

        if (score > best_score) {
            best_score = score;
            best_stage = stage_id;
        }
    }

    return best_stage;
}


// ==========================================
// Logika Consumer Thread (Penulis Tuntas)
// ==========================================

static void* system_consumer_thread(void *arg) {
    PipelineEngine *engine = (PipelineEngine*)arg;
    FinalReorderBuffer *rb = engine->reorder;
    int total_tasks        = engine->config.total_tasks;
    ConsumerWriterFn cfn   = engine->config.consumer;

    int next_req_id = 0;
    while (next_req_id < total_tasks) {
        // Pemblokir: Tunggu ID berurutan muncul di loker Reorder Buffer
        pthread_mutex_lock(&rb->lock);
        while (rb->slots[next_req_id] == NULL) {
            pthread_cond_wait(&rb->cond, &rb->lock);
        }
        PipelineTask *ready_task = rb->slots[next_req_id];
        rb->slots[next_req_id]  = NULL; // Kosongkan
        pthread_mutex_unlock(&rb->lock);

        // Eksekusi fungsi akhir yang dijanjikan Consumer! (Aman untuk tulis file)
        if(cfn) {
            cfn(ready_task);
        }

        // Cleanup pembungkus pointer (Developer hrs bersihin 'ready_task->data' sendiri)
        free(ready_task);

        next_req_id++;
    }

    return NULL;
}


// ==========================================
// Logika Worker Thread (Engine Prioritas Pusat)
// ==========================================

static void* system_worker_thread(void *arg) {
    WorkerContext  *ctx    = (WorkerContext*)arg;
    PipelineEngine *engine = ctx->engine;
    int num_stages         = engine->config.num_stages;

    while (1) {
        pthread_mutex_lock(&engine->lock);

        PipelineTask *my_task = NULL;
        int current_idx       = -1;

        // Loop Prioritas: Cari stage tertinggi dlu
        while (!engine->shutdown) {
            if (engine->config.enable_static_pipeline) {
                // Static Pipeline: Worker only pops from its dedicated stage
                int stage_id = ctx->worker_id;
                if (stage_id < num_stages) {
                    my_task = sq_pop(&engine->stage_qs[stage_id]);
                    if (my_task) {
                        current_idx = stage_id;
                    }
                }
            } else {
                current_idx = select_dynamic_stage_locked(engine);
                if (current_idx >= 0) {
                    my_task = sq_pop(&engine->stage_qs[current_idx]);
                }
            }

            if (my_task) break; // Dapat pekerjaan! Hajar!

            // Evaluasi Shutdown
            if (engine->input_done && engine->tasks_in_flight == 0) {
                int semua_kosong = 1;
                for (int i = 0; i < num_stages; i++) {
                    if (engine->stage_qs[i].count > 0) {
                        semua_kosong = 0;
                        break;
                    }
                }
                if (semua_kosong) {
                    engine->shutdown = 1;
                    pthread_cond_broadcast(&engine->cond_work);
                    break;
                }
            }

            // Tidur nunggu disuruh
            pthread_cond_wait(&engine->cond_work, &engine->lock);
        }

        if (engine->shutdown && !my_task) {
            pthread_mutex_unlock(&engine->lock);
            break; // Tamat riwayat thread
        }

        engine->tasks_in_flight++;
        pthread_cond_signal(&engine->cond_space); // Beri tau pusher klo antrean mkn lega
        pthread_mutex_unlock(&engine->lock);

        // ====== 1. Pengerjaan Fase (Luar Lock) ======
        StageProcessorFn process_step = engine->config.stages[current_idx];

        if (engine->config.enable_calibration &&
            my_task->task_id == 0 &&
            !engine->calibration_done) {

            // === CALIBRATION PHASE: Ukur waktu eksekusi stage ini ===
            struct timespec cal_start, cal_end;
            clock_gettime(CLOCK_MONOTONIC, &cal_start);

            if (process_step) {
                process_step(my_task);
            }

            clock_gettime(CLOCK_MONOTONIC, &cal_end);
            double duration = (cal_end.tv_sec - cal_start.tv_sec)
                            + (cal_end.tv_nsec - cal_start.tv_nsec) / 1e9;

            // Simpan estimasi biaya stage ini (thread-safe)
            pthread_mutex_lock(&engine->calib_lock);
            engine->stage_cost_estimates[current_idx] = duration;
            engine->stages_calibrated++;

            if (engine->stages_calibrated >= engine->config.num_stages) {
                engine->calibration_done = 1;
                pthread_cond_broadcast(&engine->calib_cond);
                pthread_mutex_lock(&engine->lock);
                pthread_cond_broadcast(&engine->cond_work);
                pthread_mutex_unlock(&engine->lock);
            }
            pthread_mutex_unlock(&engine->calib_lock);

        } else {
            // === PRODUCTION PHASE: Zero overhead, tanpa pengukuran ===
            if (process_step) {
                process_step(my_task);
            }
        }

        my_task->current_stage = current_idx + 1; // Elevasi tingkat tahapnya

        // ====== 2. Penyelesaian Tuntas atau Lanjut Antrean =======
        if (my_task->current_stage == num_stages) {
            // Sudah Tahap Terakhir (Finish!) -> Alirkan ke Reorder Buffer
            FinalReorderBuffer *rb = engine->reorder;
            pthread_mutex_lock(&rb->lock);
            rb->slots[my_task->task_id] = my_task; // Taruh di rak Consumer
            pthread_cond_signal(&rb->cond);
            pthread_mutex_unlock(&rb->lock);

            // Laporkan tugas in-flight beres
            pthread_mutex_lock(&engine->lock);
            engine->tasks_in_flight--;
            if (engine->input_done && engine->tasks_in_flight == 0) {
                int semua_kosong = 1;
                for (int i = 0; i < num_stages; i++) {
                    if (engine->stage_qs[i].count > 0) { semua_kosong = 0; break; }
                }
                if (semua_kosong) {
                    engine->shutdown = 1;
                    pthread_cond_broadcast(&engine->cond_work);
                }
            }
            pthread_cond_signal(&engine->cond_space);
            pthread_mutex_unlock(&engine->lock);

        } else {
            // Belum selesai (Lanjut ke tahapan antrean berikutnya)
            int next_stage = current_idx + 1;
            pthread_mutex_lock(&engine->lock);
            while (!sq_push(&engine->stage_qs[next_stage], my_task)) {
                // Klo antrean berikutnya full (backpressure internal antar stage)
                pthread_cond_broadcast(&engine->cond_work); // Bangunin thread lain utk nguras
                pthread_mutex_unlock(&engine->lock);
                // usleep(1M) -> Hindari busy wait parah tanpa konteks block OS
                // Kita switch aja yield cpu agar thread penguras layer lambat kerjain tugssnya dl
                struct timespec ts; ts.tv_sec = 0; ts.tv_nsec = 50000; nanosleep(&ts, NULL);
                pthread_mutex_lock(&engine->lock);
            }
            engine->tasks_in_flight--; // Krn sudah aman parkir di Q stage slnjutnya
            pthread_cond_broadcast(&engine->cond_work);
            pthread_cond_signal(&engine->cond_space);
            pthread_mutex_unlock(&engine->lock);
        }
    }
    free(ctx);
    return NULL;
}


// ==========================================
// API PUBLIC ENGINE START KONTRAKTOR
// ==========================================

PipelineEngine* pipeline_start(PipelineConfig *c) {
    if(!c || c->num_stages <= 0 || c->num_workers <= 0) return NULL;

    PipelineEngine *eng = (PipelineEngine*)malloc(sizeof(PipelineEngine));
    memset(eng, 0, sizeof(PipelineEngine));
    memcpy(&eng->config, c, sizeof(PipelineConfig));

    pthread_mutex_init(&eng->lock, NULL);
    pthread_cond_init(&eng->cond_work, NULL);
    pthread_cond_init(&eng->cond_space, NULL);

    // Inisialisasi IC-RCE (Initial Calibration)
    memset(eng->stage_cost_estimates, 0, sizeof(eng->stage_cost_estimates));
    eng->calibration_done  = 0;
    eng->stages_calibrated = 0;
    pthread_mutex_init(&eng->calib_lock, NULL);
    pthread_cond_init(&eng->calib_cond, NULL);
    
    // Inisialisasi Antrean per Stage
    eng->stage_qs = (StageQueue*)malloc(c->num_stages * sizeof(StageQueue));
    for (int i = 0; i < c->num_stages; i++) {
        eng->stage_qs[i].cap   = c->queue_capacity_per_stage;
        eng->stage_qs[i].items = (PipelineTask**)malloc(c->queue_capacity_per_stage * sizeof(PipelineTask*));
        eng->stage_qs[i].count = 0;
        eng->stage_qs[i].head  = 0;
        eng->stage_qs[i].tail  = 0;
    }

    // Inisialisasi Reorder Buffer Final
    eng->reorder = (FinalReorderBuffer*)malloc(sizeof(FinalReorderBuffer));
    eng->reorder->size  = c->total_tasks;
    eng->reorder->slots = (PipelineTask**)calloc(c->total_tasks, sizeof(PipelineTask*));
    pthread_mutex_init(&eng->reorder->lock, NULL);
    pthread_cond_init(&eng->reorder->cond, NULL);

    // Kembang-biakan Consumer pembaca Buffer
    pthread_create(&eng->t_consumer, NULL, system_consumer_thread, eng);

    // Kembang-biakan Tentaranya (Worker Pool Priority)
    eng->workers = (pthread_t*)malloc(c->num_workers * sizeof(pthread_t));
    for(int i=0; i < c->num_workers; i++) {
        WorkerContext *wctx = (WorkerContext*)malloc(sizeof(WorkerContext));
        wctx->engine = eng;
        wctx->worker_id = i;
        pthread_create(&eng->workers[i], NULL, system_worker_thread, wctx);
    }

    // === Asymmetric Core Affinity Mapping (khusus Linux) ===
#ifdef __linux__
    if (c->enable_affinity) {
        int auto_big_cores[MAX_CORES];
        int auto_little_cores[MAX_CORES];
        int num_big = c->num_big_cores;
        int num_little = c->num_little_cores;

        // Salin konfigurasi manual jika disediakan oleh pengguna
        if (num_big > 0 || num_little > 0) {
            memcpy(auto_big_cores, c->big_core_ids, num_big * sizeof(int));
            memcpy(auto_little_cores, c->little_core_ids, num_little * sizeof(int));
        } else {
            // DETEKSI OTOMATIS: Scan topologi frekuensi CPU Linux
            int n_cpus = sysconf(_SC_NPROCESSORS_ONLN);
            if (n_cpus > MAX_CORES) n_cpus = MAX_CORES;

            long max_freqs[MAX_CORES];
            long highest_freq = 0;
            long lowest_freq = -1;
            int has_freq = 0;

            for (int i = 0; i < n_cpus; i++) {
                char path[128];
                snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
                FILE *f = fopen(path, "r");
                if (f) {
                    long freq = 0;
                    if (fscanf(f, "%ld", &freq) == 1) {
                        max_freqs[i] = freq;
                        has_freq = 1;
                        if (freq > highest_freq) highest_freq = freq;
                        if (lowest_freq == -1 || freq < lowest_freq) lowest_freq = freq;
                    } else {
                        max_freqs[i] = 0;
                    }
                    fclose(f);
                } else {
                    max_freqs[i] = 0;
                }
            }

            num_big = 0;
            num_little = 0;

            if (has_freq && highest_freq > lowest_freq) {
                // Arsitektur Asimetris Terdeteksi! (big.LITTLE)
                // Core dengan frekuensi tertinggi = Big Cores
                for (int i = 0; i < n_cpus; i++) {
                    if (max_freqs[i] == highest_freq) {
                        auto_big_cores[num_big++] = i;
                    } else {
                        auto_little_cores[num_little++] = i;
                    }
                }
            } else {
                // Arsitektur Homogen atau pembacaan frekuensi gagal: Split 50/50
                for (int i = 0; i < n_cpus; i++) {
                    if (i < n_cpus / 2) {
                        auto_big_cores[num_big++] = i;
                    } else {
                        auto_little_cores[num_little++] = i;
                    }
                }
            }
        }

        // Terapkan Affinity Pinning menggunakan hasil deteksi
        for (int i = 0; i < c->num_workers; i++) {
            cpu_set_t cpuset;
            CPU_ZERO(&cpuset);

            if (num_big > 0 && i < num_big) {
                // Thread-thread pertama dialokasikan ke Big Cores
                CPU_SET(auto_big_cores[i], &cpuset);
            } else if (num_little > 0) {
                // Sisanya dialokasikan ke Little Cores secara round-robin
                int little_idx = (i - num_big) % num_little;
                CPU_SET(auto_little_cores[little_idx], &cpuset);
            } else {
                continue;
            }

            pthread_setaffinity_np(eng->workers[i], sizeof(cpu_set_t), &cpuset);
        }
    }
#endif

    return eng;
}


void pipeline_feed(PipelineEngine *engine, int id, void *raw_data) {
     PipelineTask *t = (PipelineTask*)malloc(sizeof(PipelineTask));
     t->task_id = id;
     t->current_stage = 0;
     t->data = raw_data;

     pthread_mutex_lock(&engine->lock);
     // Push ke gerbang tol tahapan awal (Stage-0), Push ini blocking via Cond klo antrian penuh. 
     while(!sq_push(&engine->stage_qs[0], t)) {
         pthread_cond_wait(&engine->cond_space, &engine->lock);
     }
     pthread_cond_broadcast(&engine->cond_work);
     pthread_mutex_unlock(&engine->lock);
}


void pipeline_close_input(PipelineEngine *engine) {
     pthread_mutex_lock(&engine->lock);
     engine->input_done = 1;
     pthread_cond_broadcast(&engine->cond_work);
     pthread_mutex_unlock(&engine->lock);
}


void pipeline_wait_and_destroy(PipelineEngine *engine) {
    // Join siasat pasukan
    for(int i=0; i < engine->config.num_workers; i++) {
        pthread_join(engine->workers[i], NULL);
    }
    // Join siasat consumer kurir
    pthread_join(engine->t_consumer, NULL);

    // Demolish Engine Mem Space
    for(int i=0; i < engine->config.num_stages; i++) {
        free(engine->stage_qs[i].items);
    }
    free(engine->stage_qs);
    free(engine->workers);

    free(engine->reorder->slots);
    pthread_mutex_destroy(&engine->reorder->lock);
    pthread_cond_destroy(&engine->reorder->cond);
    free(engine->reorder);

    pthread_mutex_destroy(&engine->lock);
    pthread_cond_destroy(&engine->cond_work);
    pthread_cond_destroy(&engine->cond_space);

    // Cleanup IC-RCE
    pthread_mutex_destroy(&engine->calib_lock);
    pthread_cond_destroy(&engine->calib_cond);

    free(engine);
}


// ==========================================
// API PUBLIC IC-RCE (Calibration Query)
// ==========================================

const double* pipeline_get_stage_costs(PipelineEngine *engine) {
    if (!engine || !engine->calibration_done) return NULL;
    return engine->stage_cost_estimates;
}

int pipeline_is_calibrated(PipelineEngine *engine) {
    if (!engine) return 0;
    return engine->calibration_done;
}
