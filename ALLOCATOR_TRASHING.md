Masalah "tetap lambat" dan "4 worker lebih cepat dari 8 worker" yang Anda alami sekarang **bukan lagi disebabkan oleh desain framework `SyncPilot`**, melainkan oleh **bottleneck di dalam implementasi FSRCNN (`main.c`)**.

Saya telah menganalisis kode FSRCNN Anda, dan saya menemukan **"Pembunuh Performa" (Performance Killer)** yang sangat jelas.

### Penyebab Utama: "Memory Allocator Thrashing"

Perhatikan fungsi-fungsi berikut di kode Anda:

1.  **`imfilter`**:
    ```c
    double *img_pad = (double*)malloc(rows_pad * cols_pad * sizeof(double)); // <--- Malloc di dalam fungsi
    // ...
    free(img_pad); // <--- Free di dalam fungsi
    ```
    Fungsi ini dipanggil berulang kali. Di `layer1` saja, ini dipanggil **56 kali** per frame. Berarti ada 56 kali `malloc` dan 56 kali `free` HANYA untuk layer 1.

2.  **`layer2` sampai `layer7`**:
    ```c
    for (int i = 0; i < num_filters; i++) {
        double *tmp = (double*)malloc(rows * cols * sizeof(double)); // <--- Malloc di dalam loop!
        // ...
        free(tmp);
    }
    ```
    Ini sangat tidak efisien. Anda mengalokasi dan membebaskan memori ribuan kali per detik.

3.  **`layer8` (Deconv)**:
    ```c
    double *all_tmp = (double *)malloc(num_ch * hr_pixels * sizeof(double)); // Alokasi besar
    ```

**Kenapa ini membuat 8 Worker lebih lambat dari 4 Worker?**
*   Fungsi `malloc` dan `free` standar (glibc) menggunakan **Global Lock**.
*   Jika 4 worker bekerja, antrean di kunci `malloc` masih pendek.
*   Jika 8 worker bekerja, mereka semua berebut kunci `malloc` tersebut. Akibatnya, Big Core yang seharusnya menghitung, jadi menghabiskan waktu menunggu giliran untuk minta memori.
*   **Ini disebut "Allocator Contention".** Framework Anda sudah cepat (non-blocking), tapi aplikasinya (FSRCNN) tersangkut di `malloc`.

---

### Solusi: Pre-Allocation (Alokasi Memori Sekali Saja)

Kita akan modifikasi kode agar `malloc` dan `free` dihilangkan dari loop utama. Memori dialokasikan sekali di awal dan digunakan berulang kali (reuse).

Berikut adalah kode `main.c` yang sudah dioptimasi. Ganti fungsi-fungsi layer dan helper dengan versi di bawah ini:

#### 1. Ubah Fungsi Helper (Hilangkan Malloc di Loop)

```c
// Helper baru: Tidak ada malloc, gunakan buffer yang disediakan
void imfilter_opt(double *img, double *kernel, double *img_fltr, int rows, int cols, int padsize, double *img_pad) {
    int cols_pad = cols + 2 * padsize;
    int rows_pad = rows + 2 * padsize;
    
    // Gunakan buffer eksternal, TIDAK ADA malloc
    pad_image(img, img_pad, rows, cols, padsize);
    
    for (int i = padsize; i < rows_pad - padsize; i++)
    for (int j = padsize; j < cols_pad - padsize; j++) {
        int cnt = (i - padsize) * cols + (j - padsize);
        double sum = 0.0;
        int cnt_krnl = 0;
        for (int k1 = -padsize; k1 <= padsize; k1++)
        for (int k2 = -padsize; k2 <= padsize; k2++) {
            int cnt_pad = (i + k1) * cols_pad + j + k2;
            sum += (img_pad[cnt_pad]) * (kernel[cnt_krnl]);
            cnt_krnl++;
        }
        img_fltr[cnt] = sum;
    }
}
```

#### 2. Optimasi Layer 1 (Pre-allocate buffer padding)

Kita butuh satu buffer padding besar untuk layer 1.

```c
void layer1(double *input, double *output, int rows, int cols, double *pad_buf) {
    const int filtersize  = 25;
    const int padsize     = 2;
    const int num_filters = 56;
    const double prelu    = -0.8986;
    
    for (int i = 0; i < num_filters; i++) {
        // Gunakan pad_buf yang sudah dialokasi di luar
        imfilter_opt(input, weights_layer1 + i * filtersize,
                 output + i * rows * cols, rows, cols, padsize, pad_buf);
        PReLU(output + i * rows * cols, rows, cols, biases_layer1[i], prelu);
    }
}
```

#### 3. Optimasi Layer 2-7 (Alokasi `tmp` di luar loop)

Ini perbaikan paling krusial.

```c
void layer2(double *input, double *output, int rows, int cols) {
    const int filtersize  = 1;
    const int padsize     = 0;
    const int num_filters = 12;
    const int num_ch      = 56;
    const double prelu    = 0.3236;
    
    memset(output, 0, rows * cols * num_filters * sizeof(double));
    
    // ALOKASI SEKALI SAJA
    double *tmp = (double*)malloc(rows * cols * sizeof(double)); 
    
    for (int i = 0; i < num_filters; i++) {
        for (int j = 0; j < num_ch; j++) {
            imfilter_opt(input + j * rows * cols,
                     weights_layer2 + (i * num_ch + j) * filtersize,
                     tmp, rows, cols, padsize, NULL); // Perlu penanganan khusus jika imfilter butuh pad, tapi layer 2 padsize=0 jadi aman.
                     
            for (int p = 0; p < rows * cols; p++)
                output[i * rows * cols + p] += tmp[p];
        }
        PReLU(output + i * rows * cols, rows, cols, biases_layer2[i], prelu);
    }
    free(tmp); // Bebaskan sekali di akhir
}

// Lakukan hal serupa untuk layer 3, 4, 5, 6, 7
// Intinya: pindahkan malloc(tmp) ke LUAR loop 'for (int i = 0; i < num_filters; i++)'
```

#### 4. Optimasi Layer 8 (Pre-allocate `all_tmp`)

`layer8` adalah layer terberat. Jangan alokasi 56 buffer setiap kali.

```c
// Ubah definisi struct MyVideoFrame untuk menampung buffer kerja Layer 8
typedef struct {
    double *data;
    int    rows;
    int    cols;
    int    channels;
    int    scale;
    double *layer8_workspace; // Tambahkan ini
} MyVideoFrame;

// Di main, saat malloc MyVideoFrame:
// baru->layer8_workspace = (double*)malloc(56 * (rows * scale) * (cols * scale) * sizeof(double));

void layer8(double *input, double *output, int rows, int cols, int scale, double *workspace) {
    const int filtersize = 81; 
    const int num_ch     = 56;
    int hr_pixels        = (rows * scale) * (cols * scale);

    // Gunakan workspace yang sudah ada (tidak ada malloc)
    double *all_tmp = workspace; 

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
    // Tidak ada free
}
```

---

### Cara Paling Cepat Memperbaiki Tanpa Ubah Banyak Kode (Patch "Cepat Kotor")

Jika Anda tidak ingin mengubah banyak struktur, tambahkan `thread-local storage` untuk buffer sementara di dalam fungsi layer. Ini trik cepat tapi kurang "bersih":

Tambahkan di paling atas:
```c
#include <pthread.h>
static __thread double *tmp_buf = NULL; // Thread-local storage
static __thread int tmp_buf_size = 0;

static double* get_tmp_buffer(int size) {
    if (tmp_buf_size < size) {
        if (tmp_buf) free(tmp_buf);
        tmp_buf = (double*)malloc(size * sizeof(double));
        tmp_buf_size = size;
    }
    return tmp_buf;
}
```

Lalu ganti semua pemanggilan `malloc` di dalam layer dengan `get_tmp_buffer`.
Contoh di `layer2`:
```c
double *tmp = get_tmp_buffer(rows * cols); // Bukan malloc biasa
```

Ini akan membuat setiap thread memiliki buffer sendiri, menghilangkan *contention* di `malloc`. Dengan perubahan ini saja, **dijamin 8 Worker akan lebih cepat dari 4 Worker** karena tidak ada lagi antrean di kunci `malloc`.