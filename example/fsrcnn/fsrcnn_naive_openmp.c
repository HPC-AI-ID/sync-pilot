#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <omp.h>
#include <time.h>

// Dimensi FSRCNN (Suzie Sequence)
#define H_IN 144
#define W_IN 176
#define H_OUT 288
#define W_OUT 352
#define TOTAL_FRAMES 150
#define KERNEL_SIZE 9
#define UPSCALE_FACTOR 2

// Fungsi PSNR (Mengukur kualitas gambar vs Ground Truth)
double calculate_psnr(double* output, double* ground_truth, int size) {
    double mse = 0.0;
    for (int i = 0; i < size; i++) {
        double diff = output[i] - ground_truth[i];
        mse += diff * diff;
    }
    mse /= (double)size;
    
    if (mse == 0.0) return INFINITY; // Infinite PSNR (Gambar 100% sama)
    if (mse < 0.0) mse = 0.0;       // Error akibat race condition parah
    
    double max_pixel = 255.0;
    return 10.0 * log10((max_pixel * max_pixel) / mse);
}

// =======================================================
// LAYER 8: NAIVE DECONVOLUTION (RACE CONDITION ZONE)
// =======================================================
void naive_deconv_layer8(double* input, double* output, double* kernel) {
    // Reset output buffer ke 0 sebelum accumulation
    for (int i = 0; i < H_OUT * W_OUT; i++) output[i] = 0.0;

    // INI ADALAH REPRODUKSI BUG ANNISA 2025!
    // Paralelisasi loop input tanpa atomic/critical.
    // Karena kernel 9x9 overlapping saat upscale, 
    // thread yang berbeda akan menulis (+=) ke PIXEL OUTPUT YANG SAMA secara bersamaan.
    // Float accumulation yang bare-metal ini 100% akan kacau (race condition).
    
    #pragma omp parallel for schedule(dynamic) // CFS akan pindah-pindahkan thread ke LITTLE core
    for (int y_in = 0; y_in < H_IN; y_in++) {
        for (int x_in = 0; x_in < W_IN; x_in++) {
            double val = input[y_in * W_IN + x_in];
            
            // Transposed Convolution (Upscale factor 2)
            for (int k_y = 0; k_y < KERNEL_SIZE; k_y++) {
                for (int k_x = 0; k_x < KERNEL_SIZE; k_x++) {
                    int y_out = y_in * UPSCALE_FACTOR + k_y;
                    int x_out = x_in * UPSCALE_FACTOR + k_x;
                    
                    if (y_out < H_OUT && x_out < W_OUT) {
                        // **RACE CONDITION TRIGGER**
                        // Thread A (Big core) & Thread B (LITTLE core) 
                        // bisa hit index y_out * W_OUT + x_out ini secara concurrent!
                        output[y_out * W_OUT + x_out] += val * kernel[k_y * KERNEL_SIZE + k_x];
                    }
                }
            }
        }
    }
}

// =======================================================
// LAYER 1-7: Convolution Biasa (Aman secara default)
// =======================================================
void simple_conv_layer(double* input, double* output, double* kernel, int h, int w, int k_size) {
    #pragma omp parallel for schedule(dynamic)
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            double sum = 0.0;
            for (int k_y = 0; k_y < k_size; k_y++) {
                for (int k_x = 0; k_x < k_size; k_x++) {
                    int iy = y + k_y - k_size/2;
                    int ix = x + k_x - k_size/2;
                    if (iy >= 0 && iy < h && ix >= 0 && ix < w) {
                        sum += input[iy * w + ix] * kernel[k_y * k_size + k_x];
                    }
                }
            }
            // Ini aman, tidak ada overlap write antar thread
            output[y * w + x] = sum;
        }
    }
}

// =======================================================
// MAIN EXECUTION (NAIVE BASELINE)
// =======================================================
int main() {
    printf("Running Naive OpenMP FSRCNN Baseline (Annisa 2025 Reproduction)...\n");
    
    // Set OpenMP Threads ke 20 (Tanpa Affinity, CFS mengatur sepenuhnya)
    omp_set_num_threads(20);
    omp_set_schedule(omp_sched_dynamic, 1); // CFS akan migrasi thread ke LITTLE core

    // Alokasi Buffer
    double* ground_truth = (double*)malloc(H_OUT * W_OUT * sizeof(double));
    double* final_output = (double*)malloc(H_OUT * W_OUT * sizeof(double));
    double* stage_buffers[8];
    for(int i=0; i<8; i++) {
        if (i < 7) stage_buffers[i] = (double*)malloc(H_IN * W_IN * sizeof(double));
        else stage_buffers[i] = (double*)malloc(H_OUT * W_OUT * sizeof(double)); // Layer 8 output
    }

    // Inisialisasi Ground Truth & Dummy Weights
    for(int i=0; i < H_OUT * W_OUT; i++) ground_truth[i] = (double)(rand() % 256);
    double* kernels[8];
    for(int i=0; i<8; i++) {
        int k_size = (i == 7) ? 9 : 3; // Layer 8 = 9x9, lainnya = 3x3 or 1x1
        kernels[i] = (double*)malloc(k_size * k_size * sizeof(double));
        for(int j=0; j < k_size * k_size; j++) kernels[i][j] = 0.01; // Dummy weight
    }

    double total_psnr = 0.0;
    double total_time_ms = 0.0;

    for (int frame = 0; frame < TOTAL_FRAMES; frame++) {
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);

        // Simulasi FSRCNN 8 Layers per Frame
        double* input_img = stage_buffers[0];
        // Isi input dengan random data (simulasi frame video)
        for(int i=0; i < H_IN * W_IN; i++) input_img[i] = (double)(rand() % 256);

        // Layer 1-7 (Conv, aman)
        simple_conv_layer(stage_buffers[0], stage_buffers[1], kernels[0], H_IN, W_IN, 3);
        simple_conv_layer(stage_buffers[1], stage_buffers[2], kernels[1], H_IN, W_IN, 1); // 1x1
        simple_conv_layer(stage_buffers[2], stage_buffers[3], kernels[2], H_IN, W_IN, 3);
        simple_conv_layer(stage_buffers[3], stage_buffers[4], kernels[3], H_IN, W_IN, 1);
        simple_conv_layer(stage_buffers[4], stage_buffers[5], kernels[4], H_IN, W_IN, 1);
        simple_conv_layer(stage_buffers[5], stage_buffers[6], kernels[5], H_IN, W_IN, 3);
        simple_conv_layer(stage_buffers[6], stage_buffers[7], kernels[6], H_IN, W_IN, 3);

        // Layer 8 (Deconv 9x9, RACE CONDITION ZONE!)
        naive_deconv_layer8(stage_buffers[7], final_output, kernels[7]);

        clock_gettime(CLOCK_MONOTONIC, &end);
        double time_s = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
        total_time_ms += time_s * 1000.0;

        // Hitung PSNR frame ini vs Ground Truth
        double psnr = calculate_psnr(final_output, ground_truth, H_OUT * W_OUT);
        total_psnr += psnr;

        if (frame % 10 == 0) {
            printf("Frame %d | PSNR: %.2f dB\n", frame, psnr);
        }
    }

    double avg_time_ms = total_time_ms / TOTAL_FRAMES;
    double avg_psnr = total_psnr / TOTAL_FRAMES;
    
    // Hitung Speedup (Serial baseline ASUS GX10 = 10072ms, Intel = 10011ms)
    // GANTI angka 10072.0 dengan Serial Baseline mesin Anda!
    double speedup = 10072.0 / avg_time_ms;
    double fps = 1000.0 / avg_time_ms;

    printf("\n====================================================\n");
    printf("HASIL NAIVE OPENMP-20W (Annisa Reproduction Baseline)\n");
    printf("====================================================\n");
    printf("Avg Time  : %.2f ms\n", avg_time_ms);
    printf("FPS       : %.2f\n", fps);
    printf("Speedup   : %.2fx\n", speedup);
    printf("Avg PSNR  : %.2f dB  <-- (Harusnya DROP / tidak Infinite!)\n", avg_psnr);
    printf("====================================================\n");

    // Cleanup
    free(ground_truth);
    free(final_output);
    for(int i=0; i<8; i++) free(stage_buffers[i]);
    for(int i=0; i<8; i++) free(kernels[i]);

    return 0;
}
