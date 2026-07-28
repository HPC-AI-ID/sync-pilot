
import threading
import time
import os
import sys

try:
    import numpy as np
except ImportError:
    print("Error: numpy is required. Install with: pip3 install numpy")
    sys.exit(1)

MAX_STAGES = 16
MAX_CORES = 20

_cpu_proxy_counter = 0
_cpu_proxy_lock = threading.Lock()


def sched_getcpu():
    if sys.platform.startswith('linux'):
        try:
            import ctypes
            libc = ctypes.CDLL('libc.so.6', use_errno=True)
            return libc.sched_getcpu()
        except Exception:
            pass

    with _cpu_proxy_lock:
        tid = threading.current_thread()
        if not hasattr(tid, '_cpu_proxy_id'):
            global _cpu_proxy_counter
            tid._cpu_proxy_id = _cpu_proxy_counter
            _cpu_proxy_counter += 1
        return tid._cpu_proxy_id


def get_buffer(size):
    return np.zeros(size, dtype=np.float64)

def release_buffer(data):
    del data

# =========================================================
#  S T R U K T U R  D A T A   C U S T O M
# =========================================================

class MyVideoFrame:
    __slots__ = ['data', 'rows', 'cols', 'channels', 'scale']
    def __init__(self, data, rows, cols, channels, scale):
        self.data = data
        self.rows = rows
        self.cols = cols
        self.channels = channels
        self.scale = scale


# =========================================================
#  F R A M E W O R K   S Y N C P I L O T   (PyPort)
# =========================================================

class StageQueue:
    def __init__(self, cap):
        self.items = [None] * cap
        self.head = 0
        self.tail = 0
        self.count = 0
        self.cap = cap
        self.lock = threading.Lock()

    def push(self, task):
        if self.count >= self.cap:
            return 0
        self.items[self.tail] = task
        self.tail = (self.tail + 1) % self.cap
        self.count += 1
        return 1

    def pop(self):
        if self.count == 0:
            return None
        task = self.items[self.head]
        self.head = (self.head + 1) % self.cap
        self.count -= 1
        return task


class FinalReorderBuffer:
    def __init__(self, size):
        self.slots = [None] * size
        self.size = size
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)


class PipelineEngine:
    def __init__(self, config):
        self.config = config
        self.stage_qs = [StageQueue(config['queue_capacity_per_stage']) for _ in range(config['num_stages'])]

        self.lock = threading.Lock()
        self.cond_work = threading.Condition(self.lock)
        self.cond_space = threading.Condition(self.lock)

        self.input_done = False
        self.shutdown = False
        self.tasks_in_flight = 0
        self.work_seq = 0
        self.reserved_slots = [0] * MAX_STAGES

        self.reorder = FinalReorderBuffer(config['total_tasks'])
        self.workers = []
        self.t_consumer = None

        self.worker_core_classes = [-1] * MAX_CORES
        self.auto_big_cores = []
        self.auto_little_cores = []

        self.stage_cost_estimates = [0.0] * config['num_stages']
        self.stage_calibrated = [0] * config['num_stages']
        self.calibration_done = False
        self.stages_calibrated = 0
        self.calib_lock = threading.Lock()
        self.calib_cond = threading.Condition(self.calib_lock)

        self._setup_affinity(config)

    def _setup_affinity(self, config):
        if not config.get('enable_affinity', 0):
            return

        n_cpus = os.cpu_count() or 1
        if n_cpus > MAX_CORES:
            n_cpus = MAX_CORES

        if sys.platform.startswith('linux'):
            max_freqs = [0] * n_cpus
            highest_freq = 0
            lowest_freq = -1
            has_freq = False

            for i in range(n_cpus):
                path = "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq" % i
                try:
                    with open(path, 'r') as f:
                        freq = int(f.read().strip())
                        max_freqs[i] = freq
                        has_freq = True
                        if freq > highest_freq:
                            highest_freq = freq
                        if lowest_freq == -1 or freq < lowest_freq:
                            lowest_freq = freq
                except (FileNotFoundError, ValueError):
                    max_freqs[i] = 0

            if has_freq and highest_freq > lowest_freq:
                for i in range(n_cpus):
                    if max_freqs[i] == highest_freq:
                        self.auto_big_cores.append(i)
                    else:
                        self.auto_little_cores.append(i)
            else:
                for i in range(n_cpus):
                    if i < n_cpus // 2:
                        self.auto_little_cores.append(i)
                    else:
                        self.auto_big_cores.append(i)
        else:
            for i in range(n_cpus):
                if i < n_cpus // 2:
                    self.auto_little_cores.append(i)
                else:
                    self.auto_big_cores.append(i)

        num_workers = config['num_workers']
        for i in range(min(num_workers, MAX_CORES)):
            if i < len(self.auto_big_cores):
                self.worker_core_classes[i] = 1
            elif i < len(self.auto_big_cores) + len(self.auto_little_cores):
                self.worker_core_classes[i] = 0

    def _signal_work_locked(self):
        self.work_seq += 1
        self.cond_work.notify_all()

    def average_stage_cost_locked(self):
        total = 0.0
        counted = 0
        for cost in self.stage_cost_estimates:
            if cost > 0.0:
                total += cost
                counted += 1
        return total / counted if counted > 0 else 0.0

    def stage_matches_worker_preference(self, stage_id, core_class, steal_mode, urgent_backlog):
        if self.config.get('enable_two_pool', 0) and self.calibration_done and core_class >= 0:
            heavy_threshold = self.average_stage_cost_locked() * 0.75
            if heavy_threshold > 0.0:
                estimated_cost = self.stage_cost_estimates[stage_id]
                if estimated_cost <= 0.0:
                    estimated_cost = 1.0
                is_heavy = estimated_cost >= heavy_threshold

                if steal_mode == 0:
                    if core_class == 1 and not is_heavy:
                        return False
                    if core_class == 0 and is_heavy:
                        return False
                elif steal_mode == 1:
                    if core_class == 0 and is_heavy and not urgent_backlog:
                        return False
        return True

    def try_take_task_from_stages(self, core_class, steal_mode):
        num_stages = self.config['num_stages']

        for stage_id in range(num_stages - 1, -1, -1):
            sq = self.stage_qs[stage_id]
            if not sq.lock.acquire(blocking=False):
                continue

            if sq.count == 0:
                sq.lock.release()
                continue

            urgent_backlog = sq.count > (sq.cap // 2)

            preferred = True
            with self.calib_lock:
                preferred = self.stage_matches_worker_preference(stage_id, core_class, steal_mode, urgent_backlog)

            if not preferred:
                sq.lock.release()
                continue

            next_stage = stage_id + 1
            can_take = True
            reserved_next_idx = -1

            if next_stage < num_stages:
                next_sq = self.stage_qs[next_stage]
                if not next_sq.lock.acquire(blocking=False):
                    sq.lock.release()
                    continue

                with self.lock:
                    can_take = (next_sq.count + self.reserved_slots[next_stage]) < next_sq.cap
                    if can_take:
                        self.reserved_slots[next_stage] += 1
                        reserved_next_idx = next_stage

                next_sq.lock.release()

            if not can_take:
                sq.lock.release()
                continue

            task = sq.pop()
            current_idx = stage_id
            if task is not None:
                with self.lock:
                    self.tasks_in_flight += 1
                    self.cond_space.notify()

            sq.lock.release()

            if task is not None:
                return task, current_idx, reserved_next_idx

        return None, -1, -1

    def all_stage_queues_empty(self):
        num_stages = self.config['num_stages']
        all_empty = True

        for i in range(num_stages):
            sq = self.stage_qs[i]
            with sq.lock:
                if sq.count > 0:
                    all_empty = False
                    break

        return all_empty

    def worker_loop(self, core_class):
        while True:
            my_task, current_idx, reserved_next_idx = self.try_take_task_from_stages(core_class, 0)
            if my_task is None:
                my_task, current_idx, reserved_next_idx = self.try_take_task_from_stages(core_class, 1)

            if my_task is None:
                with self.lock:
                    can_shutdown = self.input_done and self.tasks_in_flight == 0

                if can_shutdown and self.all_stage_queues_empty():
                    with self.lock:
                        if self.input_done and self.tasks_in_flight == 0:
                            self.shutdown = True
                            self._signal_work_locked()

                with self.lock:
                    if self.shutdown:
                        break

                    seen_work_seq = self.work_seq
                    while not self.shutdown and seen_work_seq == self.work_seq:
                        self.cond_work.wait()

                continue

            process_step = self.config['stages'][current_idx]

            should_calibrate = False
            if self.config.get('enable_calibration', 0) and my_task['task_id'] == 0:
                with self.calib_lock:
                    should_calibrate = not self.stage_calibrated[current_idx]

            if should_calibrate:
                start = time.perf_counter()
                if process_step:
                    process_step(my_task)
                end = time.perf_counter()
                duration = end - start

                with self.calib_lock:
                    if not self.stage_calibrated[current_idx]:
                        self.stage_calibrated[current_idx] = 1
                        self.stage_cost_estimates[current_idx] = duration
                        self.stages_calibrated += 1

                    if self.stages_calibrated >= self.config['num_stages']:
                        self.calibration_done = True
                        self.calib_cond.notify_all()
                        with self.lock:
                            self._signal_work_locked()
            else:
                if process_step:
                    process_step(my_task)

            my_task['current_stage'] = current_idx + 1

            if my_task['current_stage'] == self.config['num_stages']:
                with self.reorder.lock:
                    self.reorder.slots[my_task['task_id']] = my_task
                    self.reorder.cond.notify()

                with self.lock:
                    self.tasks_in_flight -= 1
                    can_shutdown = self.input_done and self.tasks_in_flight == 0

                if can_shutdown and self.all_stage_queues_empty():
                    with self.lock:
                        if self.input_done and self.tasks_in_flight == 0:
                            self.shutdown = True
                            self._signal_work_locked()

                with self.lock:
                    self.cond_space.notify()
            else:
                next_stage = current_idx + 1
                next_sq = self.stage_qs[next_stage]
                with next_sq.lock:
                    if not next_sq.push(my_task):
                        raise RuntimeError("SyncPilot internal error")

                with self.lock:
                    if reserved_next_idx == next_stage and self.reserved_slots[next_stage] > 0:
                        self.reserved_slots[next_stage] -= 1
                    self.tasks_in_flight -= 1
                    self._signal_work_locked()
                    self.cond_space.notify()

    def consumer_loop(self):
        total_tasks = self.config['total_tasks']
        consumer_fn = self.config['consumer']
        next_req_id = 0

        while next_req_id < total_tasks:
            with self.reorder.lock:
                while self.reorder.slots[next_req_id] is None:
                    self.reorder.cond.wait()
                ready_task = self.reorder.slots[next_req_id]
                self.reorder.slots[next_req_id] = None

            if consumer_fn:
                consumer_fn(ready_task)

            next_req_id += 1

    def start_threads(self):
        self.t_consumer = threading.Thread(target=self.consumer_loop)
        self.t_consumer.start()

        for i in range(self.config['num_workers']):
            core_class = self.worker_core_classes[i]
            t = threading.Thread(target=self.worker_loop, args=(core_class,))
            t.start()
            self.workers.append(t)

        if self.config.get('enable_affinity', 0) and sys.platform.startswith('linux'):
            try:
                for i, t in enumerate(self.workers):
                    if hasattr(t, 'native_id'):
                        if i < len(self.auto_big_cores):
                            os.sched_setaffinity(t.native_id, {self.auto_big_cores[i]})
                        elif i < len(self.auto_big_cores) + len(self.auto_little_cores):
                            little_idx = (i - len(self.auto_big_cores)) % len(self.auto_little_cores)
                            os.sched_setaffinity(t.native_id, {self.auto_little_cores[little_idx]})
            except (AttributeError, OSError):
                pass


def pipeline_start(config):
    if not config or config.get('num_stages', 0) <= 0 or config.get('num_workers', 0) <= 0:
        return None
    engine = PipelineEngine(config)
    engine.start_threads()
    return engine


def pipeline_feed(engine, task_id, raw_data):
    task = {'task_id': task_id, 'current_stage': 0, 'data': raw_data}

    while True:
        sq = engine.stage_qs[0]
        with sq.lock:
            pushed = sq.push(task)
            if pushed:
                break

        if not pushed:
            with engine.lock:
                engine.cond_space.wait()

    with engine.lock:
        engine._signal_work_locked()


def pipeline_close_input(engine):
    with engine.lock:
        engine.input_done = True
        engine._signal_work_locked()


def pipeline_wait(engine):
    for t in engine.workers:
        t.join()
    engine.t_consumer.join()


def pipeline_destroy(engine):
    for i in range(engine.config['num_stages']):
        sq = engine.stage_qs[i]
        with sq.lock:
            pass
    del engine.stage_qs[:]
    del engine.workers[:]

    with engine.reorder.lock:
        pass
    del engine.reorder


def pipeline_wait_and_destroy(engine):
    pipeline_wait(engine)
    pipeline_destroy(engine)


def pipeline_get_stage_costs(engine):
    if not engine or not engine.calibration_done:
        return None
    return engine.stage_cost_estimates


def pipeline_is_calibrated(engine):
    if not engine:
        return False
    return engine.calibration_done


# =========================================================
#  F S R C N N  --  L A Y E R S
# =========================================================

def pad_image(img, padsize):
    rows, cols = img.shape
    rows_pad = rows + 2 * padsize
    cols_pad = cols + 2 * padsize
    img_pad = np.zeros((rows_pad, cols_pad), dtype=np.float64)

    img_pad[padsize:padsize+rows, padsize:padsize+cols] = img

    for j in range(padsize, cols_pad - padsize):
        for k in range(padsize):
            img_pad[k, j] = img[0, j - padsize]
            img_pad[rows_pad - 1 - k, j] = img[rows - 1, j - padsize]

    for i in range(padsize, rows_pad - padsize):
        for k in range(padsize):
            img_pad[i, k] = img[i - padsize, 0]
            img_pad[i, cols_pad - 1 - k] = img[i - padsize, cols - 1]

    for k1 in range(padsize):
        for k2 in range(padsize):
            img_pad[k1, k2] = img[0, 0]
            img_pad[k1, cols_pad - 1 - k2] = img[0, cols - 1]
            img_pad[rows_pad - 1 - k1, k2] = img[rows - 1, 0]
            img_pad[rows_pad - 1 - k1, cols_pad - 1 - k2] = img[rows - 1, cols - 1]

    return img_pad


def imfilter(img, kernel, rows, cols, padsize):
    rows_pad = rows + 2 * padsize
    cols_pad = cols + 2 * padsize
    img_padded = pad_image(img, padsize)
    kernel = kernel.flatten()
    result = np.zeros((rows, cols), dtype=np.float64)

    for i in range(padsize, rows_pad - padsize):
        for j in range(padsize, cols_pad - padsize):
            patch = img_padded[i - padsize:i + padsize + 1, j - padsize:j + padsize + 1]
            result[i - padsize, j - padsize] = np.dot(patch.flatten(), kernel)

    return result


def PReLU(img, bias, prelu_coeff):
    v = img + bias
    return np.maximum(v, 0.0) + prelu_coeff * np.minimum(v, 0.0)


def deconv(img_input, img_output, kernel, cols, rows, stride):
    border = 1
    fsize = 9
    rows_pad = rows + 2 * border
    cols_pad = cols + 2 * border

    img_input_padded = pad_image(img_input.reshape(rows, cols), border)

    rows_out_pad = rows_pad * stride
    cols_out_pad = cols_pad * stride
    img_output_tmp = np.zeros((rows_out_pad + fsize - 1, cols_out_pad + fsize - 1), dtype=np.float64)
    kernel_flat = kernel.flatten()

    for i in range(rows_pad):
        for j in range(cols_pad):
            cnt_img_output_row = i * stride
            cnt_img_output_col = j * stride
            for k_r in range(fsize):
                for k_c in range(fsize):
                    ck = k_r * fsize + k_c
                    val = kernel_flat[ck] * img_input_padded[i, j]
                    img_output_tmp[cnt_img_output_row + k_r, cnt_img_output_col + k_c] += val

    rows_out = rows * stride
    cols_out = cols * stride
    for i in range(rows_out):
        for j in range(cols_out):
            i_tmp = i + ((fsize + 1) // 2) + stride * border - 1
            j_tmp = j + ((fsize + 1) // 2) + stride * border - 1
            img_output[i * cols_out + j] = img_output_tmp.flat[i_tmp * (cols_out_pad + fsize - 1) + j_tmp]


def double_2_uint8(double_img, cols, rows):
    img = double_img.reshape(rows, cols)
    clipped = np.clip(img, 0.0, 255.0)
    return (clipped + 0.5).astype(np.uint8)


# ==================== LAYERS ====================

def layer1(input_data, output, rows, cols):
    num_filters = 56
    prelu = -0.8986
    for i in range(num_filters):
        k = weights_layer1[i*25:(i+1)*25].reshape(5, 5)
        out_i = imfilter(input_data, k, rows, cols, 2)
        output[i] = PReLU(out_i, biases_layer1[i], prelu)


def layer2(input_data, output, rows, cols):
    num_filters = 12
    num_ch = 56
    prelu = 0.3236
    output.fill(0.0)
    for i in range(num_filters):
        tmp = np.zeros((rows, cols), dtype=np.float64)
        for j in range(num_ch):
            k = weights_layer2[(i*num_ch + j):(i*num_ch + j + 1)].reshape(1, 1)
            tmp += imfilter(input_data[j], k, rows, cols, 0)
        output[i] = PReLU(tmp, biases_layer2[i], prelu)


def layer3(input_data, output, rows, cols):
    num_filters = 12
    num_ch = 12
    prelu = 0.2288
    output.fill(0.0)
    for i in range(num_filters):
        tmp = np.zeros((rows, cols), dtype=np.float64)
        for j in range(num_ch):
            k = weights_layer3[(i*num_ch + j)*9:(i*num_ch + j + 1)*9].reshape(3, 3)
            tmp += imfilter(input_data[j], k, rows, cols, 1)
        output[i] = PReLU(tmp, biases_layer3[i], prelu)


def layer4(input_data, output, rows, cols):
    num_filters = 12
    num_ch = 12
    prelu = 0.2476
    output.fill(0.0)
    for i in range(num_filters):
        tmp = np.zeros((rows, cols), dtype=np.float64)
        for j in range(num_ch):
            k = weights_layer4[(i*num_ch + j)*9:(i*num_ch + j + 1)*9].reshape(3, 3)
            tmp += imfilter(input_data[j], k, rows, cols, 1)
        output[i] = PReLU(tmp, biases_layer4[i], prelu)


def layer5(input_data, output, rows, cols):
    num_filters = 12
    num_ch = 12
    prelu = 0.3495
    output.fill(0.0)
    for i in range(num_filters):
        tmp = np.zeros((rows, cols), dtype=np.float64)
        for j in range(num_ch):
            k = weights_layer5[(i*num_ch + j)*9:(i*num_ch + j + 1)*9].reshape(3, 3)
            tmp += imfilter(input_data[j], k, rows, cols, 1)
        output[i] = PReLU(tmp, biases_layer5[i], prelu)


def layer6(input_data, output, rows, cols):
    num_filters = 12
    num_ch = 12
    prelu = 0.7806
    output.fill(0.0)
    for i in range(num_filters):
        tmp = np.zeros((rows, cols), dtype=np.float64)
        for j in range(num_ch):
            k = weights_layer6[(i*num_ch + j)*9:(i*num_ch + j + 1)*9].reshape(3, 3)
            tmp += imfilter(input_data[j], k, rows, cols, 1)
        output[i] = PReLU(tmp, biases_layer6[i], prelu)


def layer7(input_data, output, rows, cols):
    num_filters = 56
    num_ch = 12
    prelu = 0.0087
    output.fill(0.0)
    for i in range(num_filters):
        tmp = np.zeros((rows, cols), dtype=np.float64)
        for j in range(num_ch):
            k = weights_layer7[(i*num_ch + j):(i*num_ch + j + 1)].reshape(1, 1)
            tmp += imfilter(input_data[j], k, rows, cols, 0)
        output[i] = PReLU(tmp, biases_layer7[i], prelu)


def imadd(img_sum, img_crnt, cols, rows):
    for i in range(rows):
        for j in range(cols):
            cnt = i * cols + j
            img_sum[cnt] = img_sum[cnt] + img_crnt[cnt]


def layer8(input_data, output, rows, cols, scale):
    filtersize = 81
    num_ch = 56
    hr_pixels = (rows * scale) * (cols * scale)

    all_tmp = np.zeros((num_ch, hr_pixels), dtype=np.float64)

    for j in range(num_ch):
        deconv(input_data[j], all_tmp[j],
               weights_layer8[j*filtersize:(j+1)*filtersize].reshape(9, 9),
               cols, rows, scale)

    for p in range(hr_pixels):
        s = 0.0
        for j in range(num_ch):
            s += all_tmp[j, p]
        output.flat[p] = s + biases_layer8


# ==================== STAGE CALLBACKS ====================

def fsrcnn_process_stage(task, layer_num):
    fb = task['data']
    t_start = time.perf_counter()

    rows_in = fb.rows
    cols_in = fb.cols
    scale = fb.scale

    if layer_num == 8:
        out_rows = rows_in * scale
        out_cols = cols_in * scale
        out_ch = 1
    elif layer_num in (1, 7):
        out_rows = rows_in
        out_cols = cols_in
        out_ch = 56
    else:
        out_rows = rows_in
        out_cols = cols_in
        out_ch = 12

    out_data = np.zeros((out_ch, out_rows, out_cols), dtype=np.float64)

    if layer_num == 1:
        layer1(fb.data, out_data, rows_in, cols_in)
    elif layer_num == 2:
        layer2(fb.data, out_data, rows_in, cols_in)
    elif layer_num == 3:
        layer3(fb.data, out_data, rows_in, cols_in)
    elif layer_num == 4:
        layer4(fb.data, out_data, rows_in, cols_in)
    elif layer_num == 5:
        layer5(fb.data, out_data, rows_in, cols_in)
    elif layer_num == 6:
        layer6(fb.data, out_data, rows_in, cols_in)
    elif layer_num == 7:
        layer7(fb.data, out_data, rows_in, cols_in)
    elif layer_num == 8:
        layer8(fb.data, out_data, rows_in, cols_in, scale)

    t_end = time.perf_counter()
    if log_file is not None:
        cpu_id = sched_getcpu()
        log_file.write("[SYNCPILOT | CPU %2d] Layer %d memproses Frame %3d | Waktu: %.5f detik\n" %
                       (cpu_id, layer_num, task['task_id'] + 1, t_end - t_start))
        log_file.flush()

    fb.data = out_data
    fb.rows = out_rows
    fb.cols = out_cols
    fb.channels = out_ch


def cb_layer1(task): fsrcnn_process_stage(task, 1)
def cb_layer2(task): fsrcnn_process_stage(task, 2)
def cb_layer3(task): fsrcnn_process_stage(task, 3)
def cb_layer4(task): fsrcnn_process_stage(task, 4)
def cb_layer5(task): fsrcnn_process_stage(task, 5)
def cb_layer6(task): fsrcnn_process_stage(task, 6)
def cb_layer7(task): fsrcnn_process_stage(task, 7)
def cb_layer8(task): fsrcnn_process_stage(task, 8)


# ==================== CONSUMER ====================

g_outFp = None
g_uv_store = None
g_uv_size = 0
g_inRows = 0
g_inCols = 0
g_outRows = 0
g_outCols = 0
g_frames_out = 0


def fsrcnn_consumer_writer(task):
    global g_frames_out
    fb = task['data']
    next_id = task['task_id']

    hr_uint8 = double_2_uint8(fb.data, g_outCols, g_outRows)
    g_outFp.write(hr_uint8.tobytes())

    outUBuf = np.zeros((g_outRows // 2, g_outCols // 2), dtype=np.uint8)
    outVBuf = np.zeros((g_outRows // 2, g_outCols // 2), dtype=np.uint8)

    uBuf = g_uv_store[next_id][:g_uv_size]
    vBuf = g_uv_store[next_id][g_uv_size:]

    for i in range(g_inRows // 2):
        for j in range(g_inCols // 2):
            cnt = 2 * (i * (g_outCols // 2) + j)
            u = uBuf[i * (g_inCols // 2) + j]
            outUBuf.flat[cnt] = u
            outUBuf.flat[cnt + 1] = u
            outUBuf.flat[cnt + g_outCols // 2] = u
            outUBuf.flat[cnt + g_outCols // 2 + 1] = u

            v = vBuf[i * (g_inCols // 2) + j]
            outVBuf.flat[cnt] = v
            outVBuf.flat[cnt + 1] = v
            outVBuf.flat[cnt + g_outCols // 2] = v
            outVBuf.flat[cnt + g_outCols // 2 + 1] = v

    g_outFp.write(outUBuf.tobytes())
    g_outFp.write(outVBuf.tobytes())

    g_frames_out += 1
    print("Frame %d selesai diproses." % (next_id + 1))


# ==================== WEIGHT LOADING ====================

script_dir = os.path.dirname(os.path.abspath(__file__))
weights_dir = os.path.join(script_dir, '..', 'fsrcnn')
if not os.path.isdir(weights_dir):
    weights_dir = script_dir

weights_layer1 = np.loadtxt(os.path.join(weights_dir, 'weights_layer1.txt'))
biases_layer1 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer1.txt'))
weights_layer2 = np.loadtxt(os.path.join(weights_dir, 'weights_layer2.txt'))
biases_layer2 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer2.txt'))
weights_layer3 = np.loadtxt(os.path.join(weights_dir, 'weights_layer3.txt'))
biases_layer3 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer3.txt'))
weights_layer4 = np.loadtxt(os.path.join(weights_dir, 'weights_layer4.txt'))
biases_layer4 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer4.txt'))
weights_layer5 = np.loadtxt(os.path.join(weights_dir, 'weights_layer5.txt'))
biases_layer5 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer5.txt'))
weights_layer6 = np.loadtxt(os.path.join(weights_dir, 'weights_layer6.txt'))
biases_layer6 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer6.txt'))
weights_layer7 = np.loadtxt(os.path.join(weights_dir, 'weights_layer7.txt'))
biases_layer7 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer7.txt'))
weights_layer8 = np.loadtxt(os.path.join(weights_dir, 'weights_layer8.txt'))
biases_layer8 = np.loadtxt(os.path.join(weights_dir, 'biasess_layer8.txt'))

print("Bobot & bias berhasil dimuat.")


# ==================== MAIN ====================

def main():
    global log_file, g_outFp, g_uv_store, g_uv_size
    global g_inRows, g_inCols, g_outRows, g_outCols, g_frames_out

    if len(sys.argv) < 3 or len(sys.argv) > 4:
        print("Usage: %s input.yuv output.yuv [num_workers]" % sys.argv[0])
        return 1

    inFile = sys.argv[1]
    outFile = sys.argv[2]
    num_workers = 8
    if len(sys.argv) >= 4:
        num_workers = int(sys.argv[3])

    os.makedirs("logs", exist_ok=True)
    log_file = open("logs/fsrcnn_syncpilot.txt", "w")

    scale = 2
    inCols = 176
    inRows = 144
    outCols = inCols * scale
    outRows = inRows * scale
    maxFrames = 150

    g_inCols = inCols
    g_inRows = inRows
    g_outCols = outCols
    g_outRows = outRows

    inFp = open(inFile, 'rb')
    if not inFp:
        print("Error: cannot open input")
        return 1
    g_outFp = open(outFile, 'wb')
    if not g_outFp:
        print("Error: cannot open output")
        inFp.close()
        return 1

    frame_size = inCols * inRows + 2 * (inCols // 2) * (inRows // 2)
    file_size = os.path.getsize(inFile)
    numFrames = file_size // frame_size
    if numFrames > maxFrames:
        numFrames = maxFrames
    if numFrames <= 0:
        print("Input tidak berisi frame YUV420 QCIF lengkap")
        inFp.close()
        g_outFp.close()
        return 1
    print("Akan memproses %d frame dari input." % numFrames)

    uv_size = (inCols // 2) * (inRows // 2)
    g_uv_size = uv_size
    allocatedFrames = numFrames
    g_uv_store = [None] * numFrames
    for f in range(numFrames):
        g_uv_store[f] = bytearray(2 * uv_size)

    inFp.seek(0)
    yBuf = bytearray(inCols * inRows)
    frames_uv_read = 0
    for f in range(numFrames):
        if inFp.readinto(yBuf) != len(yBuf):
            break
        if inFp.readinto(g_uv_store[f]) != len(g_uv_store[f]):
            break
        frames_uv_read += 1
    numFrames = frames_uv_read
    inFp.seek(0)

    if numFrames <= 0:
        print("Input gagal dibaca sebagai frame YUV420 QCIF lengkap.")
        inFp.close()
        g_outFp.close()
        return 1

    cfg = {
        'num_workers': num_workers,
        'num_stages': 8,
        'total_tasks': numFrames,
        'queue_capacity_per_stage': 16,
        'stages': [cb_layer1, cb_layer2, cb_layer3, cb_layer4,
                   cb_layer5, cb_layer6, cb_layer7, cb_layer8],
        'consumer': fsrcnn_consumer_writer,
        'enable_calibration': 1,
        'enable_affinity': 0,
    }

    if sys.platform.startswith('linux'):
        cfg['enable_affinity'] = 1

    print("Memulai Engine SyncPilot...")
    engine = pipeline_start(cfg)

    inBuf = bytearray(inCols * inRows)
    frames_in = 0
    for frames_in in range(numFrames):
        if inFp.readinto(inBuf) != len(inBuf):
            break
        inFp.seek(2 * uv_size, 1)

        lr_data = np.frombuffer(inBuf, dtype=np.uint8).astype(np.float64) / 255.0
        lr_data = lr_data.reshape(inRows, inCols)

        baru = MyVideoFrame(lr_data, inRows, inCols, 1, scale)
        pipeline_feed(engine, frames_in, baru)

    print("Total %d frame dimasukkan ke pipeline." % frames_in)

    pipeline_close_input(engine)
    pipeline_wait(engine)

    if pipeline_is_calibrated(engine):
        costs = pipeline_get_stage_costs(engine)
        print("\n==================================================")
        print("[IC-RCE] HASIL ESTIMASI BIAYA PER-STAGE/LAYER FSRCNN")
        print("==================================================")
        for i in range(cfg['num_stages']):
            print("Layer %d: %0.6f detik" % (i + 1, costs[i]))
        print("==================================================\n")

    pipeline_destroy(engine)
    print("Pipeline SyncPilot selesai, %d frame ditulis ke disk." % g_frames_out)

    inFp.close()
    g_outFp.close()
    print("Selesai.")
    return 0


if __name__ == '__main__':
    exit(main())
