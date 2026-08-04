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
    pthread_mutex_t lock;
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
    int work_seq;
    int reserved_slots[MAX_STAGES];

    FinalReorderBuffer *reorder;
    pthread_t *workers;
    pthread_t t_consumer;

    int is_shutting_down;     // Status destroy sinkronisasi internal

    // === IC-RCE: Initial Calibration Runtime Cost Estimation ===
    double stage_cost_estimates[MAX_STAGES]; // Waktu eksekusi per stage (detik)
    int    stage_calibrated[MAX_STAGES];     // Flag per-stage agar tiap layer diukur sekali
    int    calibration_done;                 // Flag: kalibrasi sudah selesai
    int    stages_calibrated;                // Counter: berapa stage sudah diukur
    pthread_mutex_t calib_lock;              // Lock khusus kalibrasi
    pthread_cond_t  calib_cond;              // Cond untuk sinkronisasi kalibrasi
};

typedef struct {
    PipelineEngine *engine;
    int core_class; // 1 = big core worker, 0 = little core worker, -1 = unknown/homogeneous
} WorkerContext;

static void signal_work_locked(PipelineEngine *engine) {
    engine->work_seq++;
    pthread_cond_broadcast(&engine->cond_work);
}

static double average_stage_cost_locked(PipelineEngine *engine) {
    int num_stages = engine->config.num_stages;
    double total = 0.0;
    int counted = 0;

    for (int i = 0; i < num_stages; i++) {
        if (engine->stage_cost_estimates[i] > 0.0) {
            total += engine->stage_cost_estimates[i];
            counted++;
        }
    }

    return counted > 0 ? total / counted : 0.0;
}

static int stage_matches_worker_preference_locked(PipelineEngine *engine, int stage_id, int core_class, int steal_mode, int urgent_backlog) {
    if (engine->config.enable_two_pool && engine->calibration_done && core_class >= 0) {
        double heavy_threshold = average_stage_cost_locked(engine) * 0.75;
        if (heavy_threshold > 0.0) {
            double estimated_cost = engine->stage_cost_estimates[stage_id];
            if (estimated_cost <= 0.0) {
                estimated_cost = 1.0;
            }
            int is_heavy = estimated_cost >= heavy_threshold;

            if (steal_mode == 0) {
                // Mode Normal (Prioritas Ketat):
                if (core_class == 1 && !is_heavy) return 0; // Big hindari ringan
                if (core_class == 0 && is_heavy) return 0;  // LITTLE hindari berat
            } else if (steal_mode == 1) {
                // Mode Steal (Work-Conserving Idle):
                // LITTLE core diizinkan mengambil task berat (membantu Big core)
                // Big core tetap dilarang mengambil task ringan agar cache fokus ke task berat
                // if (core_class == 1 && !is_heavy) return 0; 
                return 1;
            }
        }
    }

    return 1;
}

static int try_take_task_from_stages(PipelineEngine *engine, int core_class, int steal_mode, PipelineTask **task, int *stage_idx, int *reserved_next_idx) {
    int num_stages = engine->config.num_stages;

    for (int stage_id = num_stages - 1; stage_id >= 0; stage_id--) {
        StageQueue *sq = &engine->stage_qs[stage_id];
        if (pthread_mutex_trylock(&sq->lock) != 0) {
            continue;
        }

        if (sq->count == 0) {
            pthread_mutex_unlock(&sq->lock);
            continue;
        }

        int urgent_backlog = sq->count > (sq->cap / 2);
        pthread_mutex_lock(&engine->calib_lock);
        int preferred = stage_matches_worker_preference_locked(engine, stage_id, core_class, steal_mode, urgent_backlog);
        pthread_mutex_unlock(&engine->calib_lock);
        if (!preferred) {
            pthread_mutex_unlock(&sq->lock);
            continue;
        }

        int next_stage = stage_id + 1;
        int can_take = 1;
        if (next_stage < num_stages) {
            StageQueue *next_sq = &engine->stage_qs[next_stage];
            if (pthread_mutex_trylock(&next_sq->lock) != 0) {
                pthread_mutex_unlock(&sq->lock);
                continue;
            }

            pthread_mutex_lock(&engine->lock);
            can_take = (next_sq->count + engine->reserved_slots[next_stage]) < next_sq->cap;
            if (can_take) {
                engine->reserved_slots[next_stage]++;
                *reserved_next_idx = next_stage;
            }
            pthread_mutex_unlock(&engine->lock);
            pthread_mutex_unlock(&next_sq->lock);
        }

        if (!can_take) {
            pthread_mutex_unlock(&sq->lock);
            continue;
        }

        *task = sq_pop(sq);
        *stage_idx = stage_id;
        if (*task) {
            pthread_mutex_lock(&engine->lock);
            engine->tasks_in_flight++;
            pthread_cond_signal(&engine->cond_space);
            pthread_mutex_unlock(&engine->lock);
        }
        pthread_mutex_unlock(&sq->lock);
        return *task != NULL;
    }

    return 0;
}

static int all_stage_queues_empty(PipelineEngine *engine) {
    int num_stages = engine->config.num_stages;
    int all_empty = 1;

    for (int i = 0; i < num_stages; i++) {
        StageQueue *sq = &engine->stage_qs[i];
        pthread_mutex_lock(&sq->lock);
        if (sq->count > 0) {
            all_empty = 0;
        }
        pthread_mutex_unlock(&sq->lock);
        if (!all_empty) break;
    }

    return all_empty;
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
    int core_class         = ctx->core_class;

    while (1) {
        PipelineTask *my_task = NULL;
        int current_idx       = -1;
        int reserved_next_idx = -1;

        // Scheduler non-blocking: worker mencoba kunci tiap stage tanpa antre global.
        try_take_task_from_stages(engine, core_class, 0, &my_task, &current_idx, &reserved_next_idx);
        if (!my_task) {
            try_take_task_from_stages(engine, core_class, 1, &my_task, &current_idx, &reserved_next_idx);
        }

        if (!my_task) {
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

        // ====== 1. Pengerjaan Fase (Luar Lock) ======
        StageProcessorFn process_step = engine->config.stages[current_idx];

        int should_calibrate = 0;
        if (engine->config.enable_calibration && my_task->task_id == 0) {
            pthread_mutex_lock(&engine->calib_lock);
            should_calibrate = !engine->stage_calibrated[current_idx];
            pthread_mutex_unlock(&engine->calib_lock);
        }

        if (should_calibrate) {

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
            pthread_cond_signal(&engine->cond_space);
            pthread_mutex_unlock(&engine->lock);

        } else {
            // Belum selesai (Lanjut ke tahapan antrean berikutnya)
            int next_stage = current_idx + 1;
            StageQueue *next_sq = &engine->stage_qs[next_stage];

            pthread_mutex_lock(&next_sq->lock);
            if (!sq_push(next_sq, my_task)) {
                fprintf(stderr, "SyncPilot internal error: reserved stage queue penuh\n");
                abort();
            }
            pthread_mutex_unlock(&next_sq->lock);

            pthread_mutex_lock(&engine->lock);
            if (reserved_next_idx == next_stage && engine->reserved_slots[next_stage] > 0) {
                engine->reserved_slots[next_stage]--;
            }
            engine->tasks_in_flight--; // Krn sudah aman parkir di Q stage slnjutnya
            signal_work_locked(engine);
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
    memset(eng->stage_calibrated, 0, sizeof(eng->stage_calibrated));
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
        pthread_mutex_init(&eng->stage_qs[i].lock, NULL);
    }

    // Inisialisasi Reorder Buffer Final
    eng->reorder = (FinalReorderBuffer*)malloc(sizeof(FinalReorderBuffer));
    eng->reorder->size  = c->total_tasks;
    eng->reorder->slots = (PipelineTask**)calloc(c->total_tasks, sizeof(PipelineTask*));
    pthread_mutex_init(&eng->reorder->lock, NULL);
    pthread_cond_init(&eng->reorder->cond, NULL);

    int worker_core_classes[MAX_CORES];
    for (int i = 0; i < MAX_CORES; i++) worker_core_classes[i] = -1;

#ifdef __linux__
    int auto_big_cores[MAX_CORES];
    int auto_little_cores[MAX_CORES];
    int num_big = c->num_big_cores;
    int num_little = c->num_little_cores;

    if (c->enable_affinity) {
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
                for (int i = 0; i < n_cpus; i++) {
                    if (max_freqs[i] == highest_freq) {
                        auto_big_cores[num_big++] = i;
                    } else {
                        auto_little_cores[num_little++] = i;
                    }
                }
            } else {
                for (int i = 0; i < n_cpus; i++) {
                    if (i < n_cpus / 2) {
                        auto_little_cores[num_little++] = i;
                    } else {
                        auto_big_cores[num_big++] = i;
                    }
                }
            }
        }

        for (int i = 0; i < c->num_workers && i < MAX_CORES; i++) {
            if (num_big > 0 && i < num_big) {
                worker_core_classes[i] = 1;
            } else if (num_little > 0) {
                worker_core_classes[i] = 0;
            }
        }

        // Guard: two_pool hanya bermakna bila kedua kelas hadir
        int n_big_w = 0, n_lit_w = 0;
        for (int i = 0; i < c->num_workers && i < MAX_CORES; i++) {
            if      (worker_core_classes[i] == 1) n_big_w++;
            else if (worker_core_classes[i] == 0) n_lit_w++;
        }
        if (n_big_w == 0 || n_lit_w == 0) {
            eng->config.enable_two_pool = 0;
            printf("[INFO] two_pool dinonaktifkan: hanya satu kelas core (%dB/%dL).\n", n_big_w, n_lit_w);
        } else if (!eng->config.enable_two_pool) {
            // Sengaja dimatikan oleh pemanggil (mis. ablasi cost-gating), bukan
            // karena topologi — jangan laporkan sebagai aktif.
            printf("[INFO] two_pool dimatikan oleh konfigurasi: %dB/%dL, affinity tetap aktif.\n", n_big_w, n_lit_w);
        } else {
            printf("[INFO] two_pool aktif: %dB/%dL.\n", n_big_w, n_lit_w);
        }
    }
#endif

    // Kembang-biakan Consumer pembaca Buffer
    pthread_create(&eng->t_consumer, NULL, system_consumer_thread, eng);

    // Kembang-biakan Tentaranya (Worker Pool Priority)
    eng->workers = (pthread_t*)malloc(c->num_workers * sizeof(pthread_t));
    for(int i=0; i < c->num_workers; i++) {
        WorkerContext *wctx = (WorkerContext*)malloc(sizeof(WorkerContext));
        wctx->engine = eng;
        wctx->core_class = (i < MAX_CORES) ? worker_core_classes[i] : -1;
        pthread_create(&eng->workers[i], NULL, system_worker_thread, wctx);
    }

    // === Asymmetric Core Affinity Mapping (khusus Linux) ===
#ifdef __linux__
    if (c->enable_affinity) {
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

        if (num_big > 0) {
            cpu_set_t cpuset_consumer;
            CPU_ZERO(&cpuset_consumer);
            // Kunci Consumer secara eksklusif ke Big Core pertama (indeks 0)
            CPU_SET(auto_big_cores[0], &cpuset_consumer); 
            pthread_setaffinity_np(eng->t_consumer, sizeof(cpu_set_t), &cpuset_consumer);
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

     // Push ke gerbang tol tahapan awal (Stage-0), Push ini blocking via Cond klo antrian penuh. 
     while(1) {
         StageQueue *sq = &engine->stage_qs[0];
         pthread_mutex_lock(&sq->lock);
         int pushed = sq_push(sq, t);
         if (!pushed) {
             pthread_mutex_lock(&engine->lock);
         }
         pthread_mutex_unlock(&sq->lock);

         if (pushed) {
             break;
         }

         pthread_cond_wait(&engine->cond_space, &engine->lock);
         pthread_mutex_unlock(&engine->lock);
     }

     pthread_mutex_lock(&engine->lock);
     signal_work_locked(engine);
     pthread_mutex_unlock(&engine->lock);
}


void pipeline_close_input(PipelineEngine *engine) {
     pthread_mutex_lock(&engine->lock);
     engine->input_done = 1;
     signal_work_locked(engine);
     pthread_mutex_unlock(&engine->lock);
}


void pipeline_wait(PipelineEngine *engine) {
    // Join siasat pasukan
    for(int i=0; i < engine->config.num_workers; i++) {
        pthread_join(engine->workers[i], NULL);
    }
    // Join siasat consumer kurir
    pthread_join(engine->t_consumer, NULL);
}


void pipeline_destroy(PipelineEngine *engine) {
    // Demolish Engine Mem Space
    for(int i=0; i < engine->config.num_stages; i++) {
        pthread_mutex_destroy(&engine->stage_qs[i].lock);
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


void pipeline_wait_and_destroy(PipelineEngine *engine) {
    pipeline_wait(engine);
    pipeline_destroy(engine);
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
