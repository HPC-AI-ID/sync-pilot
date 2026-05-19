#include <string.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "../../framework/syncpilot.h"

// =========================================================
// CONTOH PENGGUNAAN FRAMEWORK SYNCPILOT (Mock Video Encoder)
// =========================================================
// Pipeline ini meniru aplikasi render video yang terdiri dari:
// Tahap 0: Parsing & Decode Blur (Cepat)
// Tahap 1: Analisa Motion Vector (Sedang)
// Tahap 2: Kompresi H.265 / Render Berat (Sangat Lambat -> Bottleneck)
// Output : Consumer akan mengurutkan ulang hasil render berdasarkan frame.
// =========================================================

#include <sys/time.h>
#ifndef __linux__
#ifndef sched_getcpu
static inline int sched_getcpu(void) { return 0; }
#endif
#endif

static double get_time(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

// Struktur data kustom buatan developer
typedef struct {
    char data_buffer[256];
    int complexity_score;
    double render_quality;
} MyGraphicFrame;

// ========== TAHAP 0 (DECODE) ==========
void stage_0_decode(PipelineTask *task) {
    double t_start = get_time();
    // Ambil data kita dengan aman dari framework (casting void* -> kustom)
    MyGraphicFrame *frame = (MyGraphicFrame*)task->data;

    sprintf(frame->data_buffer, "[DECODED]");
    // Simulasi mikrosekon pemrosesan cepat (10ms)
    usleep(10000); 

    double t_end = get_time();
    printf("[Worker CPU %d] TAHAP 0 (Decode) memproses Frame %02d | Waktu: %.5f detik\n", 
           sched_getcpu(), task->task_id, t_end - t_start);
}

// ========== TAHAP 1 (MOTION ANALYSIS) ==========
void stage_1_motion(PipelineTask *task) {
    double t_start = get_time();
    MyGraphicFrame *frame = (MyGraphicFrame*)task->data;

    char temp[256];
    sprintf(temp, "%s -> [MOTION_ANALYZED]", frame->data_buffer);
    strcpy(frame->data_buffer, temp);
    
    // Simulasi pemrosesan sedang (30ms)
    usleep(30000); 
    
    double t_end = get_time();
    printf("[Worker CPU %d] TAHAP 1 (Motion) memproses Frame %02d | Waktu: %.5f detik\n", 
           sched_getcpu(), task->task_id, t_end - t_start);
}

// ========== TAHAP 2 (HEAVY ENCODE) ==========
void stage_2_encode(PipelineTask *task) {
    double t_start = get_time();
    MyGraphicFrame *frame = (MyGraphicFrame*)task->data;

    char temp[256];
    sprintf(temp, "%s -> [ENCODED_H265]", frame->data_buffer);
    strcpy(frame->data_buffer, temp);
    
    // Simulasi pemrosesan SANGAT LAMBAT (Bottleneck: 150ms)
    // Walaupun lambat, framework akan memerintahkan semua Worker 
    // untuk mengeroyok tahap ini sehingga tidak terjadi pipeline stall.
    usleep(150000); 
    
    double t_end = get_time();
    printf("[Worker CPU %d] TAHAP 2 (Encode) memproses Frame %02d | Waktu: %.5f detik\n", 
           sched_getcpu(), task->task_id, t_end - t_start);
}

// ========== KONSUMEN AKHIR (PENGURUT) ==========
void final_writer(PipelineTask *task) {
    MyGraphicFrame *frame = (MyGraphicFrame*)task->data;

    // Fungsi ini dijamin 100% dipanggil berurutan oleh Reorder Buffer 
    // dari ID 0, 1, 2, ... meskipun tahap Render H265 selesainya acak.
    printf("MENYIMPAN KE DISK -> Frame %02d | Isi: %s\n", task->task_id, frame->data_buffer);

    // Bebaskan memori payload yg kita ciptakan (wajib mencegah leak)
    free(frame);
}


// ================== PROGRAM UTAMA ==================
int main() {
    printf("=== MEMULAI TEST FRAMEWORK SYNCPILOT ===\n\n");

    int total_frames = 200;

    // 1. Definisikan Konfigurasi Pipeline
    PipelineConfig cfg;
    memset(&cfg, 0, sizeof(PipelineConfig)); // PENTING: Bersihkan garbage stack!

    cfg.num_workers              = 4;   // Kita pakai 4 Thread Pekerja
    cfg.num_stages               = 3;   // Decode, Motion, Encode
    cfg.total_tasks              = total_frames; 
    cfg.queue_capacity_per_stage = 10;  

    // Hubungkan fungsi kustom tahap kita ke Framework
    cfg.stages[0] = stage_0_decode;
    cfg.stages[1] = stage_1_motion;
    cfg.stages[2] = stage_2_encode;
    
    // Hubungkan Consumer Penulis
    cfg.consumer  = final_writer;

    // === Fitur Baru: IC-RCE & Asymmetric Core Affinity ===
    cfg.enable_calibration = 1; // Aktifkan kalibrasi awal (mengukur durasi per tahap)
#ifdef __linux__
    cfg.enable_affinity = 1;    // Aktifkan Core Pinning otomatis di Linux
#endif

    // 2. Start Engine Load Balancer Asinkron
    PipelineEngine *engine = pipeline_start(&cfg);
    if(!engine) {
        printf("Gagal memulai engine!\n");
        return 1;
    }

    printf("Pekerja %d siap. Mem-feeding %d Frame...\n\n", cfg.num_workers, total_frames);

    // 3. Masukkan Data Secara Berurutan (Thread Utama sbg Produser)
    for (int i = 0; i < total_frames; i++) {
        MyGraphicFrame *baru = (MyGraphicFrame*)malloc(sizeof(MyGraphicFrame));
        baru->complexity_score = i * 10; 
        
        // Lempar pekerjaan kita ke mulut tahapan 0 framework
        pipeline_feed(engine, i, baru);
    }

    // 4. Tutup pintu masuk (agar engine tahu kapan harus bunuh diri)
    pipeline_close_input(engine);

    // 5. Tunggu semuanya selesai dan bersihkan memori
    pipeline_wait_and_destroy(engine);

    // Tampilkan hasil kalibrasi IC-RCE
    if (pipeline_is_calibrated(engine)) {
        const double *costs = pipeline_get_stage_costs(engine);
        printf("\n==================================================\n");
        printf("🔥 [IC-RCE] HASIL ESTIMASI BIAYA PER-STAGE ENCODER MOCK\n");
        printf("==================================================\n");
        printf("Tahap 0 (Decode): %0.6f detik\n", costs[0]);
        printf("Tahap 1 (Motion): %0.6f detik\n", costs[1]);
        printf("Tahap 2 (Encode): %0.6f detik\n", costs[2]);
        printf("==================================================\n");
    }

    printf("\n=== PROSES RENDER SELESAI ===\n");
    return 0;
}
