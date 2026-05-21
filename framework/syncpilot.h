#ifndef SYNCPILOT_H
#define SYNCPILOT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <pthread.h>
#include <unistd.h>

/**
 * ==============================================================
 *  DYNAMIC LOAD BALANCING FRAMEWORK (SynCPilot)
 * ==============================================================
 *
 * Framework umum untuk memproses data berantai pipelining dengan
 * Load Balancing yang sangat asinkron menggunakan Worker Pool
 * dan pengawasan urutan (Reorder Buffer).
 *
 * Contoh Aplikasi: Video Encoding, Graphics Render Pipeline, dll.
 * ==============================================================
 */

/** Maksimum tahap pipeline/layer yang bisa didaftarkan */
#define MAX_STAGES 16

/** Maksimum core CPU yang bisa didaftarkan untuk affinity */
#define MAX_CORES  16

/**
 * Tipe data Item/Tugas Generik yang mengalir dari tahap 1 ke tahap akhir.
 * Developer menyuntikkan struct kastem mereka via `data` (void*).
 */
typedef struct {
    void *data;          // Payload data utama (ex: blok video / gambar)
    int task_id;         // ID frame berurutan (0, 1, 2, ...), untuk diurutkan ulang di akhir
    int current_stage;   // Berada di tahap ke berapa (0 = Tahap pertama)
} PipelineTask;

/**
 * Definisi *Callback* Tahapan Pipeline.
 * Fungsi ini akan dipanggil oleh segenap Worker Thread.
 *
 * @param task Item task saat ini yang sedang diproses
 * @return void
 * Catatan: Anda bebas membongkar memori di `task->data` dan
 * menyambungnya dengan memori baru sembari jalan asalkan *Pointer* tersebut aman.
 */
typedef void (*StageProcessorFn)(PipelineTask *task);

/**
 * Definisi *Callback* Hasil Urutan Akhir (Consumer).
 * Akan dipanggil SECARA BURURUTAN TEPAT oleh Consumer Thread.
 * (Contoh: Menulis file MP4 hasil render)
 */
typedef void (*ConsumerWriterFn)(PipelineTask *task);

/**
 * Konfigurasi Pembangunan Pipeline.
 */
typedef struct {
    int num_workers;            // Jumlah thread Worker (misal: 8 atau 16)
    int num_stages;             // Panjang proses (misal: 3 = Read -> Encode -> Mux)
    int total_tasks;            // Total Item yang akan dilempar ke sistem
    int queue_capacity_per_stage; // Kapasitas setiap antrean sebelum backpressure

    StageProcessorFn stages[MAX_STAGES]; // Deret fungsi pemroses per blok/tahap
    ConsumerWriterFn consumer;           // Fungsi penulis akhir yang sudah terjamin berurutan (Reorder Buffer)

    // === Asymmetric Core Affinity (Opsional, khusus Linux) ===
    int enable_affinity;              // 1 = aktifkan core pinning, 0 = biarkan OS scheduler
    int num_big_cores;                // Jumlah Big core yang tersedia
    int num_little_cores;             // Jumlah Little core yang tersedia
    int big_core_ids[MAX_CORES];      // Array ID CPU Big cores
    int little_core_ids[MAX_CORES];   // Array ID CPU Little cores

    // === Initial Calibration Runtime Cost Estimation (IC-RCE) ===
    int enable_calibration;           // 1 = ukur biaya stage di task pertama, 0 = skip

} PipelineConfig;

/**
 * Object Engine utama yang menyimpan *State* framework ini.
 */
typedef struct PipelineEngine PipelineEngine;


// ==================== API PUBLIC ====================

/**
 * Membangun dan mengaktifkan Engine Load Balancer dengan Thread-threadnya.
 * Semua worker akan diam (idle) menanti input.
 */
PipelineEngine* pipeline_start(PipelineConfig *config);

/**
 * Mendorong (Feed) masuk Tugas baru (data awal) ke dalam Tahap/Stage 0.
 * Method ini bersifat "Push" dan akan memblokir (Wait) jika
 * antrean Stage 0 kebetulan kepenuhan (pengaturan backpressure otomatis).
 *
 * @param engine Pointer engine
 * @param task_id ID frame berurutan
 * @param task_data Pointer data mentah buatan Developer untuk dikirim ke Stage-0
 */
void pipeline_feed(PipelineEngine *engine, int task_id, void *task_data);

/**
 * Sinyal untuk menutup Pintu Masuk. (Tidak ada data baru yang bisa di-push).
 * Memerintahkan Engine untuk membereskan sisa antrean terakhir.
 */
void pipeline_close_input(PipelineEngine *engine);

/**
 * Menunggu (*Join*) seluruh pekerjaan (Worker dan Consumer) benar-benar tamat.
 * Kemudian menghancurkan memori Engine (Cleanup).
 */
void pipeline_wait_and_destroy(PipelineEngine *engine);

/**
 * Mendapatkan hasil estimasi biaya per-stage dari kalibrasi awal (IC-RCE).
 * Berguna untuk logging dan analisis performa di paper.
 *
 * @param engine Pointer engine
 * @return Pointer ke array double[num_stages] berisi waktu eksekusi (detik),
 *         atau NULL jika kalibrasi belum selesai / tidak diaktifkan.
 */
const double* pipeline_get_stage_costs(PipelineEngine *engine);

/**
 * Mengecek apakah fase kalibrasi (IC-RCE) sudah selesai.
 *
 * @param engine Pointer engine
 * @return 1 jika sudah selesai, 0 jika belum/tidak diaktifkan.
 */
int pipeline_is_calibrated(PipelineEngine *engine);


#ifdef __cplusplus
}
#endif

#endif // SYNCPILOT_H
