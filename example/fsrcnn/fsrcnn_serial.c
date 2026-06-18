#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/stat.h>
#ifdef __linux__
#include <sched.h>
#include <unistd.h>
#endif

FILE *log_file = NULL;

static int detect_and_pin_big_core(void) {
#ifdef __linux__
    int n_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (n_cpus <= 0) return -1;

    long max_freqs[n_cpus];
    long highest_freq = 0, lowest_freq = -1;
    int has_freq = 0, num_big = 0;
    int big_ids[n_cpus];

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

    if (has_freq && highest_freq > lowest_freq) {
        for (int i = 0; i < n_cpus; i++) {
            if (max_freqs[i] == highest_freq)
                big_ids[num_big++] = i;
        }
    } else {
        num_big = n_cpus / 2;
        for (int i = 0; i < num_big; i++)
            big_ids[i] = n_cpus - num_big + i;
    }

    if (num_big == 0) return -1;

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    for (int i = 0; i < num_big; i++)
        CPU_SET(big_ids[i], &cpuset);

    sched_setaffinity(0, sizeof(cpu_set_t), &cpuset);

    printf("[SERIAL] Dipin ke %d big core(s):", num_big);
    for (int i = 0; i < num_big; i++) printf(" CPU%d", big_ids[i]);
    printf("\n");

    return big_ids[0];
#else
    printf("[SERIAL] Core affinity tidak didukung di platform ini (homogeneous cores).\n");
    return -1;
#endif
}

static double get_time(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

// ==================== Forward Declarations ====================
void pad_image(double *img, double *img_pad, int rows, int cols, int padsize);
void imfilter(double *img, double *kernel, double *img_fltr, int rows, int cols, int padsize);
void PReLU(double *img_fltr, int rows, int cols, double bias, double prelu_coeff);
void deconv(double *img_input, double *img_output, double *kernel, int cols, int rows, int stride);
void double_2_uint8(double *double_img, unsigned char *uint8_img, int cols, int rows);

void layer1(double *input, double *output, int rows, int cols);
void layer2(double *input, double *output, int rows, int cols);
void layer3(double *input, double *output, int rows, int cols);
void layer4(double *input, double *output, int rows, int cols);
void layer5(double *input, double *output, int rows, int cols);
void layer6(double *input, double *output, int rows, int cols);
void layer7(double *input, double *output, int rows, int cols);
void layer8(double *input, double *output, int rows, int cols, int scale);

// ==================== Bobot & Bias ====================
double weights_layer1[1400], biases_layer1[56];
double weights_layer2[672],  biases_layer2[12];
double weights_layer3[1296], biases_layer3[12];
double weights_layer4[1296], biases_layer4[12];
double weights_layer5[1296], biases_layer5[12];
double weights_layer6[1296], biases_layer6[12];
double weights_layer7[672],  biases_layer7[56];
double weights_layer8[4536], biases_layer8;

// ==================== Buffer Alloc ====================
double* get_buffer(int size) {
    double *p = (double*)malloc(size * sizeof(double));
    if (!p) { fprintf(stderr, "malloc gagal untuk %d double\n", size); exit(1); }
    return p;
}

void release_buffer(double *data) {
    free(data);
}

// ==================== MAIN (SERIAL) ====================
int main(int argc, char *argv[]) {
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "Usage: %s input.yuv output.yuv [num_frames]\n", argv[0]);
        return 1;
    }

    char *inFile  = argv[1];
    char *outFile = argv[2];
    int maxFrames = 150;
    if (argc >= 4) {
        maxFrames = atoi(argv[3]);
    }

    mkdir("logs", 0777);
    log_file = fopen("logs/fsrcnn_serial.txt", "w");

    const int scale     = 2;
    const int inCols    = 176;
    const int inRows    = 144;
    const int outCols   = inCols * scale;
    const int outRows   = inRows * scale;

    // ========== Buka file ==========
    FILE *inFp = fopen(inFile, "rb");
    if (!inFp) { perror("fopen input"); return 1; }
    FILE *outFp = fopen(outFile, "wb");
    if (!outFp) { perror("fopen output"); fclose(inFp); return 1; }

    const long frame_size = (long)inCols * inRows + 2L * (inCols / 2) * (inRows / 2);
    struct stat input_stat;
    if (stat(inFile, &input_stat) != 0) {
        perror("stat input");
        fclose(inFp);
        fclose(outFp);
        return 1;
    }

    int numFrames = (int)(input_stat.st_size / frame_size);
    if (numFrames > maxFrames) numFrames = maxFrames;
    if (numFrames <= 0) {
        fprintf(stderr, "Input tidak berisi frame YUV420 QCIF lengkap (%ld byte per frame).\n", frame_size);
        fclose(inFp);
        fclose(outFp);
        return 1;
    }
    printf("Akan memproses %d frame dari input.\n", numFrames);

    // ========== Pin ke Big Core ==========
    detect_and_pin_big_core();

    // ========== Muat bobot & bias ==========
    FILE *fp;
    #define LOAD_W(file, arr, n) \
        fp = fopen(file, "r"); \
        if (!fp) { printf("Error: %s\n", file); return 1; } \
        for (int _i = 0; _i < (n); _i++) fscanf(fp, "%lf", &(arr)[_i]); \
        fclose(fp);

    LOAD_W("weights_layer1.txt", weights_layer1, 1400)
    LOAD_W("biasess_layer1.txt", biases_layer1,   56)
    LOAD_W("weights_layer2.txt", weights_layer2,  672)
    LOAD_W("biasess_layer2.txt", biases_layer2,    12)
    LOAD_W("weights_layer3.txt", weights_layer3, 1296)
    LOAD_W("biasess_layer3.txt", biases_layer3,    12)
    LOAD_W("weights_layer4.txt", weights_layer4, 1296)
    LOAD_W("biasess_layer4.txt", biases_layer4,    12)
    LOAD_W("weights_layer5.txt", weights_layer5, 1296)
    LOAD_W("biasess_layer5.txt", biases_layer5,    12)
    LOAD_W("weights_layer6.txt", weights_layer6, 1296)
    LOAD_W("biasess_layer6.txt", biases_layer6,    12)
    LOAD_W("weights_layer7.txt", weights_layer7,  672)
    LOAD_W("biasess_layer7.txt", biases_layer7,    56)
    LOAD_W("weights_layer8.txt", weights_layer8, 4536)
    fp = fopen("biasess_layer8.txt", "r");
    if (!fp) { printf("Error: biasess_layer8.txt\n"); return 1; }
    fscanf(fp, "%lf", &biases_layer8);
    fclose(fp);

    printf("Bobot & bias berhasil dimuat.\n");

    // ========== Pre-baca UV semua frame ==========
    int uv_size = (inCols / 2) * (inRows / 2);
    unsigned char **uv_store = (unsigned char**)malloc(numFrames * sizeof(unsigned char*));
    for (int f = 0; f < numFrames; f++)
        uv_store[f] = (unsigned char*)malloc(2 * uv_size);

    unsigned char *yBuf = (unsigned char*)malloc(inCols * inRows);
    int frames_read = 0;
    for (int f = 0; f < numFrames; f++) {
        if (fread(yBuf, 1, inCols * inRows, inFp) != (size_t)(inCols * inRows)) break;
        if (fread(uv_store[f], 1, 2 * uv_size, inFp) != (size_t)(2 * uv_size)) break;
        frames_read++;
    }
    numFrames = frames_read;
    rewind(inFp);

    if (numFrames <= 0) {
        fprintf(stderr, "Input gagal dibaca sebagai frame YUV420 QCIF lengkap.\n");
        fclose(inFp);
        fclose(outFp);
        for (int f = 0; f < frames_read; f++) free(uv_store[f]);
        free(uv_store);
        return 1;
    }

    free(yBuf);

    // ========== Proses serial per-frame ==========
    double t_total_start = get_time();

    unsigned char *inBuf = (unsigned char*)malloc(inCols * inRows);
    unsigned char *hr_uint8 = (unsigned char*)malloc(outRows * outCols);
    unsigned char *outUBuf  = (unsigned char*)malloc((outCols/2) * (outRows/2));
    unsigned char *outVBuf  = (unsigned char*)malloc((outCols/2) * (outRows/2));

    for (int f = 0; f < numFrames; f++) {
        if (fread(inBuf, 1, inCols * inRows, inFp) != (size_t)(inCols * inRows)) break;
        fseek(inFp, 2 * uv_size, SEEK_CUR);

        double *lr_data = get_buffer(inRows * inCols);
        for (int i = 0; i < inRows * inCols; i++)
            lr_data[i] = inBuf[i] / 255.0;

        double t_frame_start = get_time();

        // Layer 1
        double *buf1 = get_buffer(inRows * inCols * 56);
        double t1 = get_time();
        layer1(lr_data, buf1, inRows, inCols);
        double t1e = get_time();
        release_buffer(lr_data);

        // Layer 2
        double *buf2 = get_buffer(inRows * inCols * 12);
        double t2 = get_time();
        layer2(buf1, buf2, inRows, inCols);
        double t2e = get_time();
        release_buffer(buf1);

        // Layer 3
        double *buf3 = get_buffer(inRows * inCols * 12);
        double t3 = get_time();
        layer3(buf2, buf3, inRows, inCols);
        double t3e = get_time();
        release_buffer(buf2);

        // Layer 4
        double *buf4 = get_buffer(inRows * inCols * 12);
        double t4 = get_time();
        layer4(buf3, buf4, inRows, inCols);
        double t4e = get_time();
        release_buffer(buf3);

        // Layer 5
        double *buf5 = get_buffer(inRows * inCols * 12);
        double t5 = get_time();
        layer5(buf4, buf5, inRows, inCols);
        double t5e = get_time();
        release_buffer(buf4);

        // Layer 6
        double *buf6 = get_buffer(inRows * inCols * 12);
        double t6 = get_time();
        layer6(buf5, buf6, inRows, inCols);
        double t6e = get_time();
        release_buffer(buf5);

        // Layer 7
        double *buf7 = get_buffer(inRows * inCols * 56);
        double t7 = get_time();
        layer7(buf6, buf7, inRows, inCols);
        double t7e = get_time();
        release_buffer(buf6);

        // Layer 8 (deconv -> output HR)
        double *buf8 = get_buffer(outRows * outCols);
        double t8 = get_time();
        layer8(buf7, buf8, inRows, inCols, scale);
        double t8e = get_time();
        release_buffer(buf7);

        double t_frame_end = get_time();

        if (log_file) {
            fprintf(log_file, "[SERIAL] Frame %3d | Layer1: %.5f  Layer2: %.5f  Layer3: %.5f  Layer4: %.5f  Layer5: %.5f  Layer6: %.5f  Layer7: %.5f  Layer8: %.5f  Total: %.5f\n",
                    f + 1, t1e-t1, t2e-t2, t3e-t3, t4e-t4, t5e-t5, t6e-t6, t7e-t7, t8e-t8, t_frame_end-t_frame_start);
            fflush(log_file);
        }

        // Konversi Y [0,1] → [0,255]
        for (int p = 0; p < outRows * outCols; p++)
            buf8[p] *= 255.0;

        double_2_uint8(buf8, hr_uint8, outCols, outRows);
        fwrite(hr_uint8, 1, outRows * outCols, outFp);

        // Tulis U (replikasi 2x)
        unsigned char *uBuf = uv_store[f];
        unsigned char *vBuf = uv_store[f] + uv_size;
        for (int i = 0; i < inRows/2; i++)
        for (int j = 0; j < inCols/2; j++) {
            int cnt = 2 * (i * (outCols/2) + j);
            unsigned char u = uBuf[i * (inCols/2) + j];
            outUBuf[cnt]                   = u;
            outUBuf[cnt + 1]               = u;
            outUBuf[cnt + outCols/2]       = u;
            outUBuf[cnt + outCols/2 + 1]   = u;
        }
        fwrite(outUBuf, 1, (outCols/2)*(outRows/2), outFp);

        // Tulis V (replikasi 2x)
        for (int i = 0; i < inRows/2; i++)
        for (int j = 0; j < inCols/2; j++) {
            int cnt = 2 * (i * (outCols/2) + j);
            unsigned char v = vBuf[i * (inCols/2) + j];
            outVBuf[cnt]                   = v;
            outVBuf[cnt + 1]               = v;
            outVBuf[cnt + outCols/2]       = v;
            outVBuf[cnt + outCols/2 + 1]   = v;
        }
        fwrite(outVBuf, 1, (outCols/2)*(outRows/2), outFp);

        release_buffer(buf8);
        printf("Frame %d selesai diproses.\n", f + 1);
    }

    double t_total_end = get_time();

    printf("\n==================================================\n");
    printf("[SERIAL] HASIL WAKTU PER-LAYER FSRCNN\n");
    printf("==================================================\n");
    printf("Total waktu: %.5f detik untuk %d frame\n", t_total_end - t_total_start, numFrames);
    printf("==================================================\n\n");

    // ========== Bersihkan ==========
    free(inBuf); free(hr_uint8); free(outUBuf); free(outVBuf);
    for (int f = 0; f < numFrames; f++) free(uv_store[f]);
    free(uv_store);
    fclose(inFp);
    fclose(outFp);
    if (log_file) fclose(log_file);

    printf("Selesai.\n");
    return 0;
}


// ==================== IMPLEMENTASI LAYER ====================

void layer1(double *input, double *output, int rows, int cols) {
    const int filtersize  = 25;
    const int padsize     = 2;
    const int num_filters = 56;
    const double prelu    = -0.8986;
    for (int i = 0; i < num_filters; i++) {
        imfilter(input, weights_layer1 + i * filtersize,
                 output + i * rows * cols, rows, cols, padsize);
        PReLU(output + i * rows * cols, rows, cols, biases_layer1[i], prelu);
    }
}

void layer2(double *input, double *output, int rows, int cols) {
    const int filtersize  = 1;
    const int padsize     = 0;
    const int num_filters = 12;
    const int num_ch      = 56;
    const double prelu    = 0.3236;
    memset(output, 0, rows * cols * num_filters * sizeof(double));
    for (int i = 0; i < num_filters; i++) {
        double *tmp = (double*)malloc(rows * cols * sizeof(double));
        for (int j = 0; j < num_ch; j++) {
            imfilter(input + j * rows * cols,
                     weights_layer2 + (i * num_ch + j) * filtersize,
                     tmp, rows, cols, padsize);
            for (int p = 0; p < rows * cols; p++)
                output[i * rows * cols + p] += tmp[p];
        }
        PReLU(output + i * rows * cols, rows, cols, biases_layer2[i], prelu);
        free(tmp);
    }
}

void layer3(double *input, double *output, int rows, int cols) {
    const int filtersize  = 9;
    const int padsize     = 1;
    const int num_filters = 12;
    const int num_ch      = 12;
    const double prelu    = 0.2288;
    memset(output, 0, rows * cols * num_filters * sizeof(double));
    for (int i = 0; i < num_filters; i++) {
        double *tmp = (double*)malloc(rows * cols * sizeof(double));
        for (int j = 0; j < num_ch; j++) {
            imfilter(input + j * rows * cols,
                     weights_layer3 + (i * num_ch + j) * filtersize,
                     tmp, rows, cols, padsize);
            for (int p = 0; p < rows * cols; p++)
                output[i * rows * cols + p] += tmp[p];
        }
        PReLU(output + i * rows * cols, rows, cols, biases_layer3[i], prelu);
        free(tmp);
    }
}

void layer4(double *input, double *output, int rows, int cols) {
    const int filtersize  = 9;
    const int padsize     = 1;
    const int num_filters = 12;
    const int num_ch      = 12;
    const double prelu    = 0.2476;
    memset(output, 0, rows * cols * num_filters * sizeof(double));
    for (int i = 0; i < num_filters; i++) {
        double *tmp = (double*)malloc(rows * cols * sizeof(double));
        for (int j = 0; j < num_ch; j++) {
            imfilter(input + j * rows * cols,
                     weights_layer4 + (i * num_ch + j) * filtersize,
                     tmp, rows, cols, padsize);
            for (int p = 0; p < rows * cols; p++)
                output[i * rows * cols + p] += tmp[p];
        }
        PReLU(output + i * rows * cols, rows, cols, biases_layer4[i], prelu);
        free(tmp);
    }
}

void layer5(double *input, double *output, int rows, int cols) {
    const int filtersize  = 9;
    const int padsize     = 1;
    const int num_filters = 12;
    const int num_ch      = 12;
    const double prelu    = 0.3495;
    memset(output, 0, rows * cols * num_filters * sizeof(double));
    for (int i = 0; i < num_filters; i++) {
        double *tmp = (double*)malloc(rows * cols * sizeof(double));
        for (int j = 0; j < num_ch; j++) {
            imfilter(input + j * rows * cols,
                     weights_layer5 + (i * num_ch + j) * filtersize,
                     tmp, rows, cols, padsize);
            for (int p = 0; p < rows * cols; p++)
                output[i * rows * cols + p] += tmp[p];
        }
        PReLU(output + i * rows * cols, rows, cols, biases_layer5[i], prelu);
        free(tmp);
    }
}

void layer6(double *input, double *output, int rows, int cols) {
    const int filtersize  = 9;
    const int padsize     = 1;
    const int num_filters = 12;
    const int num_ch      = 12;
    const double prelu    = 0.7806;
    memset(output, 0, rows * cols * num_filters * sizeof(double));
    for (int i = 0; i < num_filters; i++) {
        double *tmp = (double*)malloc(rows * cols * sizeof(double));
        for (int j = 0; j < num_ch; j++) {
            imfilter(input + j * rows * cols,
                     weights_layer6 + (i * num_ch + j) * filtersize,
                     tmp, rows, cols, padsize);
            for (int p = 0; p < rows * cols; p++)
                output[i * rows * cols + p] += tmp[p];
        }
        PReLU(output + i * rows * cols, rows, cols, biases_layer6[i], prelu);
        free(tmp);
    }
}

void layer7(double *input, double *output, int rows, int cols) {
    const int filtersize  = 1;
    const int padsize     = 0;
    const int num_filters = 56;
    const int num_ch      = 12;
    const double prelu    = 0.0087;
    memset(output, 0, rows * cols * num_filters * sizeof(double));
    for (int i = 0; i < num_filters; i++) {
        double *tmp = (double*)malloc(rows * cols * sizeof(double));
        for (int j = 0; j < num_ch; j++) {
            imfilter(input + j * rows * cols,
                     weights_layer7 + (i * num_ch + j) * filtersize,
                     tmp, rows, cols, padsize);
            for (int p = 0; p < rows * cols; p++)
                output[i * rows * cols + p] += tmp[p];
        }
        PReLU(output + i * rows * cols, rows, cols, biases_layer7[i], prelu);
        free(tmp);
    }
}

void layer8(double *input, double *output, int rows, int cols, int scale) {
    const int filtersize = 81;
    const int num_ch     = 56;
    int hr_pixels        = (rows * scale) * (cols * scale);

    double *all_tmp = (double *)malloc(num_ch * hr_pixels * sizeof(double));
    if (!all_tmp) return;

    for (int j = 0; j < num_ch; j++) {
        deconv(input + j * rows * cols, all_tmp + (j * hr_pixels),
               weights_layer8 + j * filtersize, cols, rows, scale);
    }

    for (int p = 0; p < hr_pixels; p++) {
        double sum = 0;
        for (int j = 0; j < num_ch; j++) {
            sum += all_tmp[j * hr_pixels + p];
        }
        output[p] = sum + biases_layer8;
    }

    free(all_tmp);
}


// ==================== FUNGSI HELPER ====================

void pad_image(double *img, double *img_pad, int rows, int cols, int padsize)
{
    int cols_pad = cols + 2 * padsize;
    int rows_pad = rows + 2 * padsize;
    int i, j, k, cnt, cnt_pad, k1, k2;
    for (i = padsize; i < rows_pad - padsize; i++)
    for (j = padsize; j < cols_pad - padsize; j++) {
        cnt_pad = i * cols_pad + j;
        cnt     = (i - padsize) * cols + j - padsize;
        *(img_pad + cnt_pad) = *(img + cnt);
    }
    for (j = padsize; j < cols_pad - padsize; j++)
    for (k = 0; k < padsize; k++) {
        cnt_pad = j + k * cols_pad;
        cnt     = j - padsize;
        *(img_pad + cnt_pad) = *(img + cnt);
        cnt_pad = j + (rows_pad - 1 - k) * cols_pad;
        cnt     = (j - padsize) + (rows - 1) * cols;
        *(img_pad + cnt_pad) = *(img + cnt);
    }
    for (i = padsize; i < rows_pad - padsize; i++)
    for (k = 0; k < padsize; k++) {
        cnt     = (i - padsize) * cols;
        cnt_pad = i * cols_pad + k;
        *(img_pad + cnt_pad) = *(img + cnt);
        cnt     = (i - padsize) * cols + cols - 1;
        cnt_pad = i * cols_pad + cols_pad - 1 - k;
        *(img_pad + cnt_pad) = *(img + cnt);
    }
    for (k1 = 0; k1 < padsize; k1++)
    for (k2 = 0; k2 < padsize; k2++) {
        *(img_pad + k1 * cols_pad + k2)                               = *(img);
        *(img_pad + k1 * cols_pad + cols_pad - 1 - k2)                = *(img + cols - 1);
        *(img_pad + (rows_pad-1-k1) * cols_pad + k2)                  = *(img + (rows-1)*cols);
        *(img_pad + (rows_pad-1-k1) * cols_pad + cols_pad - 1 - k2)   = *(img + (rows-1)*cols + cols-1);
    }
}

void imfilter(double *img, double *kernel, double *img_fltr, int rows, int cols, int padsize)
{
    int cols_pad = cols + 2 * padsize;
    int rows_pad = rows + 2 * padsize;
    double *img_pad = (double*)malloc(rows_pad * cols_pad * sizeof(double));
    pad_image(img, img_pad, rows, cols, padsize);
    for (int i = padsize; i < rows_pad - padsize; i++)
    for (int j = padsize; j < cols_pad - padsize; j++) {
        int cnt = (i - padsize) * cols + (j - padsize);
        double sum = 0.0;
        int cnt_krnl = 0;
        for (int k1 = -padsize; k1 <= padsize; k1++)
        for (int k2 = -padsize; k2 <= padsize; k2++) {
            int cnt_pad = (i + k1) * cols_pad + j + k2;
            sum += (*(img_pad + cnt_pad)) * (*(kernel + cnt_krnl));
            cnt_krnl++;
        }
        *(img_fltr + cnt) = sum;
    }
    free(img_pad);
}

static double _max2(double a, double b) { return a > b ? a : b; }
static double _min2(double a, double b) { return a > b ? b : a; }

void PReLU(double *img_fltr, int rows, int cols, double bias, double prelu_coeff)
{
    for (int i = 0; i < rows; i++)
    for (int j = 0; j < cols; j++) {
        int cnt = i * cols + j;
        double v = *(img_fltr + cnt) + bias;
        *(img_fltr + cnt) = _max2(v, 0.0) + prelu_coeff * _min2(v, 0.0);
    }
}

void deconv(double *img_input, double *img_output, double *kernel, int cols, int rows, int stride)
{
    int border = 1, fsize = 9;
    int rows_pad = rows + 2 * border;
    int cols_pad = cols + 2 * border;
    double *img_input_padded = (double*)malloc(rows_pad * cols_pad * sizeof(double));
    pad_image(img_input, img_input_padded, rows, cols, border);

    int rows_out_pad = rows_pad * stride;
    int cols_out_pad = cols_pad * stride;
    double *img_output_tmp = (double*)calloc((rows_out_pad + fsize - 1) * (cols_out_pad + fsize - 1), sizeof(double));
    double *kernel_modif   = (double*)malloc(fsize * fsize * sizeof(double));

    for (int i = 0; i < rows_pad; i++)
    for (int j = 0; j < cols_pad; j++) {
        int cnt_img        = i * cols_pad + j;
        int cnt_img_output = (i * stride) * (cols_out_pad + fsize - 1) + (j * stride);
        for (int k_r = 0; k_r < fsize; k_r++) {
            for (int k_c = 0; k_c < fsize; k_c++) {
                int ck = k_r * fsize + k_c;
                kernel_modif[ck] = kernel[ck] * img_input_padded[cnt_img];
                img_output_tmp[cnt_img_output + k_c] += kernel_modif[ck];
            }
            cnt_img_output += cols_out_pad + fsize - 1;
        }
    }

    int rows_out = rows * stride, cols_out = cols * stride;
    for (int i = 0; i < rows_out; i++)
    for (int j = 0; j < cols_out; j++) {
        int i_tmp = i + ((fsize + 1) / 2) + stride * border - 1;
        int j_tmp = j + ((fsize + 1) / 2) + stride * border - 1;
        img_output[i * cols_out + j] = img_output_tmp[i_tmp * (cols_out_pad + fsize - 1) + j_tmp];
    }

    free(img_input_padded);
    free(img_output_tmp);
    free(kernel_modif);
}

void double_2_uint8(double *double_img, unsigned char *uint8_img, int cols, int rows)
{
    for (int i = 0; i < rows; i++)
    for (int j = 0; j < cols; j++) {
        int cnt    = i * cols + j;
        double val = *(double_img + cnt);
        if (val <= 0.0)
            *(uint8_img + cnt) = 0;
        else if (val >= 255.0)
            *(uint8_img + cnt) = 255;
        else
            *(uint8_img + cnt) = (unsigned char)(val + 0.5);
    }
}
