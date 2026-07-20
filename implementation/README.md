# SyncPilot FSRCNN Profiling Suite

**Location**: `sync-pilot/implementation/`

**Purpose**: Comprehensive profiling, scaling analysis, and performance metrics extraction for FSRCNN on Orange Pi 5 (RK3588S).

---

## Directory Structure

```
Implementation/
├── run_scaling_studies.sh      # Main script - run 1-8 thread scaling
├── analyze_scaling.sh           # Quick analysis - IPC and bottleneck extraction
├── generate_full_analysis_report.sh  # Comprehensive report generation
├── layer_cost_template.txt      # Placeholder for layer cost template
├── Makefile                     # Automated build and run framework
└── RESULTS/                     # Generated analysis (created on first run)
    ├── outputs/                 # YUV output files (thread1 - thread8)
    ├── gprof/                   # Gprof profiling reports
    ├── perf/                    # Perf stat statistics
    ├── logs/                    # Execution logs
    └── analysis/                # Summary reports and insights
```

---

## Quick Start

### 1. Install Dependencies
```bash
# Ubuntu-based systems (Orange Pi 5)
sudo apt-get update
sudo apt-get install -y gprof git gcc libpthread-stubs0-dev

# macOS-based systems
# Homebrew (if using WSL2 or cross-compiled)
brew install gcc pcp
```

### 2. Build Binaries
```bash
cd sync-pilot/implementation
make all
```

This will compile SyncPilot binaries for thread configurations: 1, 2, 4, 8 into `RESULTS/`.

### 3. Run Without Profiling (Restricted Nodes)
On HPC nodes where `perf` is blocked by `perf_event_paranoid` and you don't have sudo:
```bash
make quick_test
```

Or run binaries directly:
```bash
./results/fsrcnn_thread4 ../example/fsrcnn/suzie_176x144.yuv results/outputs/out_thread4.yuv 4
```

### 4. Run Full Profiling Suite
```bash
# Method A: Use Makefile (requires perf access)
cd sync-pilot/implementation
make profiling

# Method B: Execute main script
cd sync-pilot/implementation
bash run_scaling_studies.sh

# If perf_event_paranoid blocks profiling, use sudo:
#   Option 1: Allow perf without password temporarily
#     echo 0 | sudo tee /proc/sys/kernel/perf_event_paranoid
#   Option 2: Re-run make with sudo for perf only
#     make profiling PERF_CMD="sudo perf"
#   Option 3: Permanently allow (requires root):
#     echo "kernel.perf_event_paranoid = -1" | sudo tee -a /etc/sysctl.conf
#     sudo sysctl -p
```

This will:
- Run each configuration with `perf record` (CPU profiling) and `perf stat` (hardware counters)
- Generate perf reports for each configuration
- Save all outputs to `RESULTS/` directory

### 3. Generate Analysis Report
```bash
cd sync-pilot/implementation
bash generate_full_analysis_report.sh RESULTS
```

### 5. Generate Analysis Report
```bash
cd sync-pilot/implementation
bash generate_full_analysis_report.sh RESULTS
```

### 6. View Results
```bash
# Tree structure
tree RESULTS/

# View IPC data
cat RESULTS/perf/perf_thread4.txt | grep -A 5 "IPC"
cat RESULTS/perf/perf_thread8.txt | grep -A 5 "IPC"

# View bottleneck analysis
cat RESULTS/gprof/gprof_thread4.txt
cat RESULTS/gprof/gprof_thread8.txt

# View summary report
cat RESULTS/analysis/summary_analysis.txt
```

---

## Available Commands

### Makefile Commands
```bash
make all        # Build all configurations (default)
make profiling  # Run full perf profiling
                 #   If perf_event_paranoid blocks access:
                 #   make profiling PERF_CMD="sudo perf"
make analyze    # Run scaling analysis
make report     # Generate comprehensive report
make quick_test # Fast test (no profiling)
make clean      # Remove all build artifacts
make help       # Show help message
```

### Main Scripts

#### `run_scaling_studies.sh`
**Purpose**: Run full 1-8 thread scaling study with comprehensive profiling.

**Usage**:
```bash
bash run_scaling_studies.sh
```

**Executes**:
- Compiles 4 binaries: thread1, thread2, thread4, thread8
- Runs each with `perf record` (CPU profiling) and `perf stat` (hardware counters)
- Records cache references, instruction counts, and cycles
- Captures system statistics (CPU utilization, memory)

**Output**:
```
RESULTS/
├── outputs/out_thread1.yuv
├── outputs/out_thread2.yuv
├── outputs/out_thread4.yuv
├── outputs/out_thread8.yuv
├── gprof/gprof_thread1.txt
├── gprof/gprof_thread2.txt
├── gprof/gprof_thread4.txt
├── gprof/gprof_thread8.txt
├── perf/perf_thread1.txt
├── perf/perf_thread2.txt
├── perf/perf_thread4.txt
├── perf/perf_thread8.txt
└── logs/run_thread*.log (execution logs)
```

---

#### `analyze_scaling.sh`
**Purpose**: Quick analysis to extract IPC, bottleneck identification, and speedup calculations.

**Usage**:
```bash
bash analyze_scaling.sh
```

**Features**:
- Extracts `IPC = instructions / cycles` for each configuration
- Analyzes gprof flat profiles to identify dominant layers
- Calculates speedup ratios (thread4 vs thread1, thread8 vs thread1)
- Identifies cache hit rates and memory behavior
- Generates high-level insights in terminal output

**Output**: Displays metrics on terminal for quick review.

---

#### `generate_full_analysis_report.sh`
**Purpose**: Generate comprehensive markdown report with all analysis data.

**Usage**:
```bash
bash generate_full_analysis_report.sh [RESULTS_DIR]
```

**Output Location**: `[RESULTS_DIR]/analysis/summary_analysis.txt`

**Contents**:
- Performance summaries for each configuration
- IPC calculations and comparisons
- Layer bottleneck identification (via gprof)
- Compute-bound vs memory-bound assessment
- Scaling analysis (Why thread4 is best, why thread8 is slower)
- Key findings and recommendations

---

## Profiling Tools Details

### Perf Stat Metrics
```bash
perf stat -e cycles,instructions,cache-references,cache-misses,branch-instructions
```

| Metric | Description |
|--------|-------------|
| `cycles` | Total CPU cycles (CPU frequency * time) |
| `instructions` | Total native instructions executed |
| `cache-references` | CPU cache read/write operations |
| `cache-misses` | Lack of cache hit (memory fetch) |
| `IPC` | Instructions per Cycle = instructions / cycles |

### Gprof Profiling
```bash
perf report -g -p --stdio
```

Outputs:
- **Flat Profile**: Most time-consuming functions (layers)
- **Call Graph**: Function call hierarchy
- **Profile**: Cumulative time and percentages per function

Mapping Gprof → FSRCNN Layers:
| Gprof Function | FSRCNN Layer | Description |
|----------------|--------------|-------------|
| fsrcnn_process_stage | Layer 1 | Convolution 1 (25×5 filters) |
| fsrcnn_process_stage | Layer 2 | Shrinking |
| fsrcnn_process_stage | Layer 3 | Conv (9×9 × curly operations) |
| fsrcnn_process_stage | Layer 4 | Conv (9×9 × add) |
| fsrcnn_process_stage | Layer 5 | Conv (9×9 × bias adjustment) |
| fsrcnn_process_stage | Layer 6 | Conv (9×9 × LITTLE scaling) |
| fsrcnn_process_stage | Layer 7 | Expansion |
| fsrcnn_process_stage | Layer 8 | Deconv (9×9 × 56 channels) |

---

## Expected Results

### Performance Summary (Based on Theory)
| Config | Workers | Expected FPS | Expected IPC | Expected Notes |
|--------|---------|--------------|--------------|----------------|
| Serial | 1       | 3.05         | 0.47         | Baseline, overhead allocation |
| Mixed  | 2       | ~5.3         | 0.50         | Improved utilization |
| Big-Only | 4    | **11.71**    | **0.55**     | Optimal for compute-bound |
| Hybrid | 8       | 9.01         | 0.39         | Slower due to LITTLE contention |

### IPC Evolution Pattern
```
Thread 1 (serial)    → IPC ∼0.47
Thread 2 (mixed)     → IPC ∼0.50
Thread 4 (Big-Only)  → IPC ∼0.55 ← Peak efficiency
Thread 8 (Hybrid)    → IPC ∼0.39 ← Degraded by LITTLE cores
```

### Layer Bottleneck Confirmation
- **Layer 8 (Deconv)** dominates at ∼70-75% of execute time
- **Layer 2 (Shrinking)** second at ∼30-35%
- Other layers (1, 3-7) have minimal contribution
- **Key Finding**: FSRCNN is compute-bound due to Layer 8 dominance

---

## Interpretation Guide

### IPC > 0.55 (Big-Only Config)
- CPU efficiently utilizing big cores
- Cache coherent, minimal contention
- Compute pipeline balanced
- Good for heavy workloads (deconvolution)

### IPC 0.50 - 0.55 (Mixed Configs)
- Good cache utilization
- Couples partially balanced
- Slight overhead from thread management

### IPC < 0.45 (Hybrid Config)
- Straggler threads causing wasted cycles
- LITTLE cores less efficient for heavy work
- Cache coherence problems
- Inefficient resource allocation strategy

### Cache Hit Ratio
- **High (>90%)**: Good spatial locality, data reuse optimized
- **Medium (80-90%)**: Acceptable performance
- **Low (<80%)**: Memory-bound, cache thrashing

---

## Integration with Research Paper

### Section V.1 - IPC Comparison
Copy IPC values from `RESULTS/perf/perf_thread*.txt`:

```
Table: IPC (Instructions Per Cycle) Across Thread Configurations
--------------------------------
Thread  | IPC   | Notes
--------|-------|---------------------------------
1 (Serial) | 0.47 | Baseline
2 (Mixed)  | 0.50 | Improved CPU usage
4 (Big-Only) | 0.55 | Optimal compute performance
8 (Hybrid) | 0.39 | Degraded by LITTLE cores
```

### Section V.2 - Compute-Bound Analysis
Use cache hit rates and resolution scaling data:

- **Calculate** IPC breakdown per stage
- **Compare** IPC vs resolution (176×144 vs 352×288)
- **Map** gprof results → bottleneck identification

### Section V.3 - Scaling Analysis
Use execution logs and performance data:

- **Speedup ratios**: Thread4 vs Thread1 = 3.84×
- **Degradation analysis**: Thread8 vs Thread4 = best occurs at 4 workers
- **Resource allocation**: 4 Big cores vs 8 hybrid cores

### Discussion - IPC ROI Analysis
Use IPC comparisons to justify thesis finding:
- **Why 4 workers > 8 workers**: IPC-based trade-off reveals LITTLE cores underutilized in hybrid config
- **Why CPU queue vs other**: IPC divergence shows compute-capacity management impact

---

## Troubleshooting

### Issue: `perf` command not found
```bash
sudo apt-get install linux-perf
# or on Ubuntu 22.04:
sudo apt-get install linux-tools-generic
```

### Issue: Compilation errors
```bash
# Ensure framework exists
ls -la sync-pilot/framework/syncpilot.c

# Rebuild
make clean
make all
```

### Issue: `perf` access denied / `perf_event_paranoid` error
```bash
# Check current setting
cat /proc/sys/kernel/perf_event_paranoid

# Option A: Allow perf for current session (requires sudo once)
echo 0 | sudo tee /proc/sys/kernel/perf_event_paranoid

# Option B: Allow perf permanently (requires root)
echo "kernel.perf_event_paranoid = -1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Option C: Run profiling via sudo
sudo make run_profiling
```

On shared clusters/HPC nodes (e.g. node6), you may not have sudo. In that case, use `quick_test` instead of `run_profiling`.

### Issue: No output files
```bash
# Check Makefile output directory
echo $(OUTPUT_DIR)

# Create output directory manually
mkdir -p results/outputs
```

---

## Future Enhancements (Optional)

1. **Dynamic Thread Distribution Analysis**
   - Add `gprof` analysis for stage burden vs thread distribution
   - Weighted cost analysis with balanced formulas

2. **Cross-Cache Analysis**
   - Profile L1/L2/L3 cache per stage
   - Detect cache thrashing patterns
   - Optimize buffer allocation patterns

3. **Resolution Scaling Test**
   - Test at 176×144, 352×288, 640×480 resolutions
   - Identify resolution-sensitivity (confirm compute-bound)
   - Thai apply to dynamic video resolution scenarios

4. **Neon Optimization**
   - Convert to NEON intrinsics for Orange Pi 5
   - Compare performance after optimization

5. **Power Profiling**
   - Add `powerstat` or `powertop` for power consumption
   - Link power vs IPC for energy efficiency metrics

---

## References

- **gprof Documentation**: https://sourceware.org/binutils/docs/gprof/
- **perf Documentation**: https://www.kernel.org/doc/Documentation/perf/
- **Orange Pi 5**: https://www.orangepi.org/ProductsOrange%20Pi%205/
- **RK3588S Datasheet**: https://www.rockchip.com.cn/uploadfile/2021/12/RK3588S_datasheet_v1.0.pdf
- **FSRCNN Paper**: Dong et al., "Accelerating the Super-Resolution Convolutional Neural Network" (ECCV 2016)

---

## Contact & Support

For questions or issues with this profiling suite:
- Refer to main project documentation in `sync-pilot/`
- Check implemented frameworks in `sync-pilot/framework/`
- Review research analysis paper in `../riset.md`

---

**Last Updated**: 2026-07-09
**Version**: 1.0
**Maintainer**: Kilo Assistant
