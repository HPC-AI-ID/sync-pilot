# SyncPilot Framework — Arsitektur & Implementasi

> Dokumen ini menjelaskan alur kerja SyncPilot (`sync-pilot/framework/syncpilot.c`) beserta implementasi nyatanya pada kasus uji FSRCNN (`sync-pilot/example/fsrcnn/fsrcnn_syncpilot.c`).

---

## 1. Gambaran Umum

SyncPilot adalah *framework* C generik untuk **pipelining asynchronous** dengan *dynamic load balancing* dan jaminan urutan keluaran (*ordered output*).

- **Masalah yang diselesaikan:** Pada pipeline statis (mis. 1 thread per layer), layer yang paling lambat menjadi *bottleneck* dan membuat thread lainnya *idle*.
- **Solusi:** Semua stage dijalankan oleh satu **worker pool homogen**. Worker yang menganggur langsung mengambil stage yang paling sibuk (*priority stealing*).

---

## 2. Struktur Data Inti

### 2.1 `PipelineTask`
Setiap *item* yang mengalir di pipeline.

```c
typedef struct {
    void *data;          // Payload buatan developer
    int task_id;         // ID berurutan (0, 1, 2, ...) untuk pengurutan akhir
    int current_stage;   // Stage saat ini (0 = pertama)
} PipelineTask;
```

### 2.2 `StageQueue` (Antrean per Stage)
Setiap stage memiliki antrean tersendiri dengan *mutex* dan *buffer melingkar* (ring buffer).

```c
typedef struct {
    PipelineTask **items;
    int head, tail, count, cap;
    pthread_mutex_t lock;
} StageQueue;
```

Operasi: `sq_push()` dan `sq_pop()`.

#### 2.2.1 `sq_push` — Memasukkan Task ke Antrean

```c
static int sq_push(StageQueue *sq, PipelineTask *task) {
    if (sq->count >= sq->cap) return 0; // Penuh
    sq->items[sq->tail] = task;
    sq->tail = (sq->tail + 1) % sq->cap;
    sq->count++;
    return 1;
}
```

**Mekanisme (Ring Buffer / Circular Buffer):**

1. **Cek kapasitas:** Jika `count >= cap`, antrean penuh. Kembalikan `0` (gagal).
2. **Tulis data:** Simpan pointer `task` di posisi `tail` saat ini.
3. **Geser tail:** `tail = (tail + 1) % cap`. Operasi modulo membuat tail "melilit" kembali ke indeks 0 setelah mencapai `cap - 1`.
4. **Naikkan count:** `count++` menandakan ada elemen baru.
5. **Kembalikan `1`:** Berhasil.

**Contoh Visual**

Misal `cap = 4`, awal `head = 0`, `tail = 0`, `count = 0`:

```
Push A → items[0]=A, tail=1, count=1
Push B → items[1]=B, tail=2, count=2
Push C → items[2]=C, tail=3, count=3
Push D → items[3]=D, tail=0 (3+1 % 4), count=4  ← Penuh
Push E → return 0 (gagal, count == cap)
```

Setelah pop 2x (`head` jadi 2), sisa `[C, D]`:

```
Push E → items[0]=E, tail=1, count=3  ← Menulis ulang slot yang sudah kosong
```

**Catatan Penting:**

- **Tidak ada mutex di dalam fungsi.** Pemanggil (`system_worker_thread`) sudah mengunci `sq->lock` sebelum memanggil `sq_push`. Ini menghindari *lock nesting* yang tidak perlu.
- **Return value:** `1` = sukses, `0` = antrean penuh (backpressure ke feeder).

#### 2.2.2 `sq_pop` — Mengambil Task dari Antrean

```c
static PipelineTask* sq_pop(StageQueue *sq) {
    if (sq->count == 0) return NULL; // Kosong
    PipelineTask *task = sq->items[sq->head];
    sq->head = (sq->head + 1) % sq->cap;
    sq->count--;
    return task;
}
```

**Mekanisme:**

1. **Cek kosong:** Jika `count == 0`, antrean kosong. Kembalikan `NULL`.
2. **Ambil data:** Baca `items[head]` (FIFO — *first in, first out*).
3. **Geser head:** `head = (head + 1) % cap`.
4. **Turunkan count:** `count--` menandakan satu elemen keluar.
5. **Kembalikan task:** Pointer ke `PipelineTask`.

**Contoh Visual**

Melanjutkan state sebelumnya (`items = [A, B, C, D]`, `head=0`, `count=4`):

```
Pop  → task=A, head=1, count=3
Pop  → task=B, head=2, count=2
Pop  → task=C, head=3, count=1
Pop  → task=D, head=0 (3+1 % 4), count=0  ← Kosong
Pop  → return NULL
```

#### 2.2.3 Mengapa FIFO Ring Buffer?

1. **Urutan fair:** Task yang masuk lebih awal ke stage tertentu diproses lebih awal (meskipun antrean bisa *steal* dari stage lain).
2. **Memori terbatas:** Kapasitas tetap (`cap`), tidak ada `malloc`/`free` di dalam push/pop — mencegah *fragmentation* pada sistem embedded.
3. **Modulo wrap:** Indeks melilit secara otomatis, memanfaatkan seluruh slot buffer tanpa memindahkan data.
4. **Backpressure:** Ketika `count >= cap`, feeder (`pipeline_feed`) diblokir oleh `cond_space`, mencegah *overflow* memori.

#### 2.2.4 Alur Penggunaan di Framework

```c
// Worker mengambil task (bersamaan dengan reserved slot check)
pthread_mutex_lock(&sq->lock);
PipelineTask *task = sq_pop(sq);
pthread_mutex_unlock(&sq->lock);

// Worker menyelesaikan stage, lalu push ke stage berikutnya
pthread_mutex_lock(&next_sq->lock);
sq_push(next_sq, task);
pthread_mutex_unlock(&next_sq->lock);
```

Synchronization dilakukan **di luar** fungsi `sq_push`/`sq_pop` agar fleksibel — misalnya `try_take_task_from_stages` bisa mencoba beberapa stage berbeda dalam satu transaksi menggunakan `pthread_mutex_trylock`.

### 2.3 `FinalReorderBuffer` (Reorder Buffer)
Menjamin outputConsumer berurutan berdasarkan `task_id`.

```c
typedef struct {
    PipelineTask **slots;   // Ukuran = total_tasks
    int size;
    pthread_mutex_t lock;
    pthread_cond_t  cond;
} FinalReorderBuffer;
```

### 2.4 `PipelineEngine`
Inti mesin framework.

```c
struct PipelineEngine {
    PipelineConfig config;
    StageQueue *stage_qs;            // Array antrean [0..num_stages-1]

    pthread_mutex_t lock;
    pthread_cond_t  cond_work;       // Bangunkan worker saat ada kerja
    pthread_cond_t  cond_space;      // Bangunkan feeder saat antrean tidak penuh

    int input_done;                  // 1 jika semua input sudah di-feed
    int shutdown;                    // 1 jika harus matikan worker
    int tasks_in_flight;             // Counter task yang sedang berjalan
    int work_seq;                    // Sequence number untuk broadcast
    int reserved_slots[MAX_STAGES];  // Backpressure: slot di stage berikutnya

    FinalReorderBuffer *reorder;
    pthread_t *workers;
    pthread_t t_consumer;

    // === IC-RCE (Initial Calibration Runtime Cost Estimation) ===
    double stage_cost_estimates[MAX_STAGES];
    int    stage_calibrated[MAX_STAGES];
    int    calibration_done;
    int    stages_calibrated;
    pthread_mutex_t calib_lock;
    pthread_cond_t  calib_cond;
};
```

### 2.5 `WorkerContext`
Konteks setiap worker thread.

```c
typedef struct {
    PipelineEngine *engine;
    int core_class;   // 1 = big core, 0 = little core, -1 = tidak diketahui
} WorkerContext;
```

---

## 3. Alur Eksekusi (End-to-End)

```
[Developer] --pipeline_feed()--> [Stage Queue 0] --worker--> [Stage Queue 1] ... --> [Reorder Buffer] --> [Consumer Thread] --> [Disk/Output]
```

### Langkah 1: Feed (`pipeline_feed`)
Developer membuat `PipelineTask`, mengisi `task->data` dengan struct kastem, lalu memanggil `pipeline_feed(engine, id, data)`.
- Task dimasukkan ke `stage_qs[0]`.
- Jika antrean penuh, feeder **diblokir** hingga ada slot kosong (`cond_space`).

### Langkah 2: Worker Scheduler (`system_worker_thread`)
Worker melakukan **non-blocking steal**:

1. Coba ambil task dari stage paling akhir ke awal (`try_take_task_from_stages`) dengan *preference* biasa (`steal_mode = 0`).
2. Jika tidak ada, coba lagi dengan *steal mode* (`steal_mode = 1`) — worker boleh mengambil stage yang kurang cocok jika backlog-nya tinggi.
3. Jika masih tidak ada, worker tidur di `cond_work` sampai ada sinyal.

Saat mengambil task, worker juga melakukan **reserved slot** di stage berikutnya untuk mencegah *overcommit* (backpressure).

### Langkah 3: Eksekusi Stage
Worker menjalankan callback `StageProcessorFn` (mis. `layer3()` pada FSRCNN).

Jika `enable_calibration = 1` dan ini adalah *task pertama* di stage tersebut, worker mengukur durasi eksekusi (`clock_gettime(CLOCK_MONOTONIC)`) untuk **IC-RCE**.

### Langkah 4: Propagasi ke Stage Berikutnya
- Jika `current_stage + 1 == num_stages` → task masuk ke **Reorder Buffer**.
- Jika belum selesai → task di-*push* ke `stage_qs[next_stage]`.

### Langkah 5: Reorder Buffer & Consumer
Consumer thread (`system_consumer_thread`) menunggu `task_id` berurutan muncul di buffer.
- Setelah `task_id` yang diinginkan tersedia, consumer memanggil `ConsumerWriterFn`, kemudian `free()` task.
- Ini memastikan **penulisan file/output selalu berurutan** walaupun worker berjalan *out-of-order*.

### Langkah 6: Shutdown
Setelah `pipeline_close_input()` dipanggil dan semua `tasks_in_flight == 0` serta semua antrean kosong, worker-worker mulai keluar (`shutdown = 1`).

---

## 4. IC-RCE (Initial Calibration Runtime Cost Estimation)

Fitur unggulan SyncPilot untuk *asymmetric scheduling*.

### Tujuan
Mengestimasi biaya waktu (`stage_cost_estimates`) setiap stage pada **task pertama** (frame 0), tanpa biaya runtime di task selanjutnya.

### Mekanisme
1. Worker memproses task ID = 0.
2. Jika stage tersebut belum terkalibrasi, worker mengukur waktu sebelum dan sesudah `process_step()`.
3. Hasil disimpan di `engine->stage_cost_estimates[stage_id]`.
4. Setelah semua stage terukur (`stages_calibrated >= num_stages`), flag `calibration_done` di-set dan `calib_cond` di-*broadcast*.

### Manfaat
- Memberi dasar logis untuk **two-pool scheduling** (heavy stage → big core, light stage → little core).
- Tersedia via API publik: `pipeline_get_stage_costs()` dan `pipeline_is_calibrated()`.

---

## 5. Asymmetric Core Affinity (Linux Only)

Sistem deteksi dan *pinning* core secara otomatis:

1. Baca `cpufreq/cpuinfo_max_freq` setiap CPU.
2. CPU dengan `max_freq` tertinggi → **big cores**.
3. Sisanya → **little cores**.
4. Worker worker dialokasikan: worker pertama ke big core, sisanya ke little core (round-robin).
5. Terapkan via `pthread_setaffinity_np()`.

Jika auto-deteksi gagal (mis. file `sysfs` tidak ada), sistem fallback ke pembagian: CPU pertama setengah → *little*, setengah akhir → *big*.

---

## 6. API Publik

| Fungsi | Deskripsi |
|---|---|
| `pipeline_start(PipelineConfig *c)` | Buat dan hidupkan engine (worker + consumer thread). |
| `pipeline_feed(engine, id, raw_data)` | Masukkan task baru ke Stage 0 (blocking jika penuh). |
| `pipeline_close_input(engine)` | Tutup pintu masuk, izinkan worker selesaikan sisa tugas. |
| `pipeline_wait(engine)` | Tunggu semua worker + consumer selesai (`pthread_join`). |
| `pipeline_destroy(engine)` | Bersihkan memori engine. |
| `pipeline_wait_and_destroy(engine)` | Gabungan wait + destroy. |
| `pipeline_get_stage_costs(engine)` | Ambil array biaya stage hasil IC-RCE. |
| `pipeline_is_calibrated(engine)` | Cek apakah kalibrasi sudah selesai. |

---

## 7. Implementasi Kasus: FSRCNN (`fsrcnn_syncpilot.c`)

### 7.1 Data Structure (Kastem)

```c
typedef struct {
    double *data;
    int    rows;
    int    cols;
    int    channels;
    int    scale;    // Untuk layer8 (upsampling)
} MyVideoFrame;
```

Setiap `PipelineTask->data` menunjuk ke `MyVideoFrame`.

### 7.2 Stage Callbacks (8 Layer FSRCNN)

```c
cfg.stages[0] = cb_layer1;  // Feature extraction (conv + PReLU)
cfg.stages[1] = cb_layer2;  // 1x1 conv
cfg.stages[2] = cb_layer3;  // 3x3 conv
cfg.stages[3] = cb_layer4;  // 3x3 conv
cfg.stages[4] = cb_layer5;  // 3x3 conv
cfg.stages[5] = cb_layer6;  // 3x3 conv
cfg.stages[6] = cb_layer7;  // 1x1 conv
cfg.stages[7] = cb_layer8;  // Deconv / Upsampling (9x9, stride=scale)
```

Callback `cb_layerN(PipelineTask *t)` memanggil `fsrcnn_process_stage(t, layer_num)`:

1. Hitung ukuran output layer (terganti di layer8 karena *upsampling*).
2. Alokasikan buffer output (`get_buffer`).
3. Jalankan fungsi layer (mis. `layer3(input, output, rows, cols)`).
4. Log waktu eksekusi + CPU ID.
5. **In-place update:** `release_buffer(fb->data)` → ganti dengan buffer baru, update `rows/cols/channels`.

### 7.3 Consumer Writer (`fsrcnn_consumer_writer`)

Dijamin berurutan oleh Reorder Buffer.

Langkah:
1. Ambil `MyVideoFrame` dari `task->data`.
2. Konversi Y `[0,1]` → `[0,255]` (`double_2_uint8`).
3. Tulis Luminance (Y) ke file output.
4. Tulis Chrominance (U, V) dengan replikasi 2x2 (karena upscale).
5. `release_buffer(fb->data)`.
6. `free(task)`.

### 7.4 Inisialisasi Engine

```c
PipelineConfig cfg;
memset(&cfg, 0, sizeof(PipelineConfig));  // PENTING: nolkan seluruh config

cfg.num_workers              = num_workers;   // default 8
cfg.num_stages               = 8;
cfg.total_tasks              = numFrames;
cfg.queue_capacity_per_stage = 16;

cfg.stages[0..7] = cb_layer1..cb_layer8;
cfg.consumer     = fsrcnn_consumer_writer;

cfg.enable_calibration = 1;   // IC-RCE aktif
#ifdef __linux__
cfg.enable_affinity    = 1;   // Core pinning aktif
#endif

PipelineEngine *engine = pipeline_start(&cfg);
```

### 7.5 Feeding & Shutdown

```c
for (tiap frame) {
    double *lr_data = ...; // normalisasi 0..255 → 0..1
    MyVideoFrame *fb = malloc(sizeof(MyVideoFrame));
    fb->data = lr_data; fb->rows = inRows; ...
    pipeline_feed(engine, frame_id, fb);
}

pipeline_close_input(engine);   // Tutup pintu masuk
pipeline_wait(engine);          // Tunggu selesai

// Cetak hasil kalibrasi
if (pipeline_is_calibrated(engine)) {
    const double *costs = pipeline_get_stage_costs(engine);
    // print per-layer cost
}

pipeline_destroy(engine);
```

---

## 8. File Kunci

| File | Peran |
|---|---|
| `sync-pilot/framework/syncpilot.h` | Header publik (API, struct config, typedef). |
| `sync-pilot/framework/syncpilot.c` | Implementasi engine (worker, consumer, scheduler, IC-RCE, affinity). |
| `sync-pilot/example/fsrcnn/fsrcnn_syncpilot.c` | Implementasi lengkap FSRCNN menggunakan SyncPilot. |

---

## 9. Kompilasi

```bash
gcc -O3 -o fsrcnn_app \
    sync-pilot/example/fsrcnn/fsrcnn_syncpilot.c \
    sync-pilot/framework/syncpilot.c \
    -lpthread -Wall
```

---

## 10. Catatan Penting

1. **Memory Management:** Developer bertanggung jawab `free()` pada `task->data` di dalam `ConsumerWriterFn`. Framework hanya `free(PipelineTask*)`.
2. **Thread Safety:** Semua callback stage dijalankan **luar lock** utama. Hanya operasi pada `StageQueue` dan `ReorderBuffer` yang dilindungi mutex.
3. **In-Place Update:** Stage diperbolehkan mengganti `task->data` dengan buffer baru (seperti di FSRCNN), asalkan pointer aman.
4. **Backpressure:** Jika stage berikutnya penuh, worker menahan slot (`reserved_slots`) dan menunggu `cond_space`.
