# Makefile for FSRCNN Profiling & Testing Suite
# Supported: gprof profiling, perf stat, progressive scaling

CC = gcc
CFLAGS = -O3 -Wall -march=native -fno-inline-functions -mtune=native -pg
LDFLAGS = -lm -lrt -lpthread

# Directories
PROJECT_DIR = $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
SRC_DIR = $(PROJECT_DIR)/example/fsrcnn
FRAMEWORK_DIR = $(PROJECT_DIR)/framework
IMPLEMENTATION_DIR = $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Input YUV file (QCIF 176x144)
INPUT_YUV = $(SRC_DIR)/suzie_qcif.yuv

# Output directories (relative to project root)
PYTHON_TEMPLATES = ./scripts/templates
RESULTS_DIR = $(PROJECT_DIR)/results
OUTPUT_DIR = $(RESULTS_DIR)/outputs
GPROF_DIR = $(RESULTS_DIR)/gprof
PERF_DIR = $(RESULTS_DIR)/perf

# Source files
SOURCES = $(SRC_DIR)/fsrcnn_syncpilot.c $(FRAMEWORK_DIR)/syncpilot.c

# Target binaries
TARGETS = $(RESULTS_DIR)/fsrcnn_thread1 $(RESULTS_DIR)/fsrcnn_thread2 \
          $(RESULTS_DIR)/fsrcnn_thread4 $(RESULTS_DIR)/fsrcnn_thread8 \
          $(RESULTS_DIR)/fsrcnn_thread10 $(RESULTS_DIR)/fsrcnn_thread20

# Default target: only build binaries
all: $(TARGETS)

# Compile all configurations
$(RESULTS_DIR)/fsrcnn_thread1: $(SOURCES)
	@echo "Building thread1..."
	mkdir -p $(RESULTS_DIR)
	$(CC) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

$(RESULTS_DIR)/fsrcnn_thread2: $(SOURCES)
	@echo "Building thread2..."
	mkdir -p $(RESULTS_DIR)
	$(CC) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

$(RESULTS_DIR)/fsrcnn_thread4: $(SOURCES)
	@echo "Building thread4..."
	mkdir -p $(RESULTS_DIR)
	$(CC) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

$(RESULTS_DIR)/fsrcnn_thread8: $(SOURCES)
	@echo "Building thread8..."
	mkdir -p $(RESULTS_DIR)
	$(CC) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

$(RESULTS_DIR)/fsrcnn_thread10: $(SOURCES)
	@echo "Building thread10..."
	mkdir -p $(RESULTS_DIR)
	$(CC) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

$(RESULTS_DIR)/fsrcnn_thread20: $(SOURCES)
	@echo "Building thread20..."
	mkdir -p $(RESULTS_DIR)
	$(CC) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

# Run Full Profiling Suite
run_profiling: $(TARGETS)
	@echo "=========================================="
	@echo "Running Full Profiling Suite..."
	@echo "=========================================="
	@mkdir -p $(OUTPUT_DIR) $(GPROF_DIR) $(PERF_DIR)
	@for workers in 1 2 4 8 10 20; do \
		echo "Running thread$$workers..." ; \
		perf record -F 99 \
			--output $(RESULTS_DIR)/fsrcnn_thread$$workers.perf_data \
			$(RESULTS_DIR)/fsrcnn_thread$$workers $(INPUT_YUV) \
			$(OUTPUT_DIR)/out_thread$$workers.yuv $$workers 2>&1 | \
			grep -v "CPU\|Power\|Hot Plug" || echo "perf record failed, continuing..." ; \
		if [ -f $(RESULTS_DIR)/fsrcnn_thread$$workers.perf_data ]; then \
			perf report -i $(RESULTS_DIR)/fsrcnn_thread$$workers.perf_data \
				--stdio > $(GPROF_DIR)/gprof_thread$$workers.txt || echo "perf report failed" ; \
		else \
			echo "Skipping perf report (no perf_data)"; \
		fi; \
		perf stat -e cycles,instructions,cache-references,cache-misses \
			$(RESULTS_DIR)/fsrcnn_thread$$workers $(INPUT_YUV) \
			$(OUTPUT_DIR)/out_thread$$workers.yuv $$workers 2> $(PERF_DIR)/perf_thread$$workers.txt || echo "perf stat failed" ; \
	done

# Alias for run_profiling
profiling: run_profiling

# -------------------------------------------------------
# gprof Flat Profile for SyncPilot-10W (all-Big baseline)
# Usage: make gprof_10w
# Produces: $(GPROF_DIR)/gprof_thread10_flat.txt
# -------------------------------------------------------
gprof_10w: $(RESULTS_DIR)/fsrcnn_thread10
	@echo "=== gprof profiling: SyncPilot-10W (all-Big baseline) ==="
	@mkdir -p $(OUTPUT_DIR) $(GPROF_DIR)
	@echo "Running binary with 10 workers (gmon.out will be generated)..."
	@cd $(SRC_DIR) && \
		$(RESULTS_DIR)/fsrcnn_thread10 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_thread10_gprof.yuv 10
	@echo "Analyzing gmon.out..."
	@if [ -f $(SRC_DIR)/gmon.out ]; then \
		gprof $(RESULTS_DIR)/fsrcnn_thread10 $(SRC_DIR)/gmon.out \
			-p > $(GPROF_DIR)/gprof_thread10_flat.txt && \
		gprof $(RESULTS_DIR)/fsrcnn_thread10 $(SRC_DIR)/gmon.out \
			-q > $(GPROF_DIR)/gprof_thread10_callgraph.txt && \
		echo "gprof 10W output saved to $(GPROF_DIR)/gprof_thread10_flat.txt" ; \
	elif [ -f gmon.out ]; then \
		gprof $(RESULTS_DIR)/fsrcnn_thread10 gmon.out \
			-p > $(GPROF_DIR)/gprof_thread10_flat.txt && \
		gprof $(RESULTS_DIR)/fsrcnn_thread10 gmon.out \
			-q > $(GPROF_DIR)/gprof_thread10_callgraph.txt && \
		echo "gprof 10W output saved to $(GPROF_DIR)/gprof_thread10_flat.txt" ; \
	else \
		echo "ERROR: gmon.out not found. Make sure binary was compiled with -pg" ; \
	fi

# -------------------------------------------------------
# gprof Flat Profile for SyncPilot-20W
# Usage: make gprof_20w
# Produces: $(GPROF_DIR)/gprof_thread20_flat.txt
# -------------------------------------------------------
gprof_20w: $(RESULTS_DIR)/fsrcnn_thread20
	@echo "=== gprof profiling: SyncPilot-20W ==="
	@mkdir -p $(OUTPUT_DIR) $(GPROF_DIR)
	@echo "Running binary with 20 workers (gmon.out will be generated)..."
	@cd $(SRC_DIR) && \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_thread20_gprof.yuv 20
	@echo "Analyzing gmon.out..."
	@if [ -f $(SRC_DIR)/gmon.out ]; then \
		gprof $(RESULTS_DIR)/fsrcnn_thread20 $(SRC_DIR)/gmon.out \
			-p > $(GPROF_DIR)/gprof_thread20_flat.txt && \
		gprof $(RESULTS_DIR)/fsrcnn_thread20 $(SRC_DIR)/gmon.out \
			-q > $(GPROF_DIR)/gprof_thread20_callgraph.txt && \
		echo "gprof output saved to $(GPROF_DIR)/gprof_thread20_flat.txt" ; \
	elif [ -f gmon.out ]; then \
		gprof $(RESULTS_DIR)/fsrcnn_thread20 gmon.out \
			-p > $(GPROF_DIR)/gprof_thread20_flat.txt && \
		gprof $(RESULTS_DIR)/fsrcnn_thread20 gmon.out \
			-q > $(GPROF_DIR)/gprof_thread20_callgraph.txt && \
		echo "gprof output saved to $(GPROF_DIR)/gprof_thread20_flat.txt" ; \
	else \
		echo "ERROR: gmon.out not found. Make sure binary was compiled with -pg" ; \
	fi

# -------------------------------------------------------
# Detailed IPC Degradation Analysis for SyncPilot-20W
# Measures: stall cycles, L1/L2 cache refills, branch misses, OS overhead
# Usage: make ipc_analysis_20w
# Produces: $(PERF_DIR)/ipc_analysis_thread20.txt
# -------------------------------------------------------
ipc_analysis_20w: $(RESULTS_DIR)/fsrcnn_thread20
	@echo "=== IPC Degradation Analysis: SyncPilot-20W ==="
	@mkdir -p $(OUTPUT_DIR) $(PERF_DIR)
	@rm -f $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "--- Pass 1: Baseline IPC (known-good events) ---"
	@echo "=== PASS 1: Baseline IPC ===" >> $(PERF_DIR)/ipc_analysis_thread20.txt
	perf stat -e "cycles,instructions,cache-references,cache-misses" \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass1.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "" >> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "--- Pass 2: ARM L1/L2 cache refill counters ---"
	@echo "=== PASS 2: ARM L1/L2 Cache Counters ===" >> $(PERF_DIR)/ipc_analysis_thread20.txt
	perf stat -e "armv8_pmuv3_1/l1d_cache/,armv8_pmuv3_1/l1d_cache_refill/,armv8_pmuv3_1/l2d_cache/,armv8_pmuv3_1/l2d_cache_refill/,armv8_pmuv3_1/bus_cycles/" \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass2.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt || \
	echo "SKIP: ARM cache PMU events not available, try: perf list | grep armv8" \
		>> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "" >> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "--- Pass 2b: ARM L3 (LLC/DSU) cache counters ---"
	@echo "=== PASS 2b: ARM L3/LLC Cache Counters ===" >> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "# Note: cache-references/cache-misses (Pass 1) = L3/LLC on ARM" \
		>> $(PERF_DIR)/ipc_analysis_thread20.txt
	perf stat -e "armv8_pmuv3_1/l3d_cache/,armv8_pmuv3_1/l3d_cache_refill/" \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass2b.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt || \
	perf stat -e "armv8_pmuv3_1/l3d_cache_rd/,armv8_pmuv3_1/l3d_cache_refill_rd/" \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass2b.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt || \
	echo "SKIP: L3 PMU events not exposed on this kernel (check: perf list | grep l3)" \
		>> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "" >> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "--- Pass 3: Branch misses & OS overhead ---"
	@echo "=== PASS 3: Branch + OS Overhead ===" >> $(PERF_DIR)/ipc_analysis_thread20.txt
	perf stat -e "cycles,instructions,branch-misses,context-switches,cpu-migrations,task-clock" \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass3.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo ""
	@echo "IPC analysis saved to $(PERF_DIR)/ipc_analysis_thread20.txt"
	@echo ""
	@echo "=== QUICK SUMMARY ==="
	@grep -E "insn per cycle|l1d_cache|l2d_cache|l3d_cache|refill|miss|migration|switch|branch" \
		$(PERF_DIR)/ipc_analysis_thread20.txt || true

# -------------------------------------------------------
# CFS Baseline vs SyncPilot IC-RCE Performance Comparison
#
# Prinsip: binary yang SAMA, worker yang SAMA (20W), tapi:
#   - CFS baseline : pthread_setaffinity_np di-no-op via LD_PRELOAD
#                    → CFS Linux bebas memilih core mana saja
#   - SyncPilot    : IC-RCE aktif, affinity ke Big/LITTLE sesuai profil
#
# Cara: buat no_affinity.so yang intercept setaffinity → jadi no-op
# Usage: make cfs_comparison
# -------------------------------------------------------
NO_AFF_SRC = $(IMPLEMENTATION_DIR)/no_affinity.c
NO_AFF_LIB = $(IMPLEMENTATION_DIR)/no_affinity.so
CFS_LOG     = $(PERF_DIR)/cfs_comparison.txt

# Compile intercept library (no_affinity.c must exist in implementation dir)
$(NO_AFF_LIB): $(NO_AFF_SRC)
	gcc -shared -fPIC -o $(NO_AFF_LIB) $(NO_AFF_SRC)
	@echo "Built: $(NO_AFF_LIB)"

cfs_comparison: $(RESULTS_DIR)/fsrcnn_thread20 $(NO_AFF_LIB)
	@echo "======================================================="
	@echo "  CFS vs SyncPilot IC-RCE: True Wall-clock Comparison"
	@echo "======================================================="
	@echo "Prinsip: binary sama, 20W, bedanya IC-RCE aktif vs tidak"
	@mkdir -p $(OUTPUT_DIR) $(PERF_DIR)
	@rm -f $(CFS_LOG)
	@echo "=== CFS vs SyncPilot IC-RCE Comparison ===" > $(CFS_LOG)
	@echo "Date: $$(date)" >> $(CFS_LOG)
	@echo "Frames: 150" >> $(CFS_LOG)
	@echo "" >> $(CFS_LOG)
	@echo "--- Run 1: CFS murni (pthread_setaffinity_np = no-op via LD_PRELOAD) ---"
	@echo "=== Run 1: CFS baseline (IC-RCE affinity disabled) ===" >> $(CFS_LOG)
	@echo "CFS bebas distribute 20 threads ke core mana pun tanpa hint"
	@START=$$(date +%s%N); \
		LD_PRELOAD=$(NO_AFF_LIB) \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_cfs_noaffinity.yuv 20 2>/dev/null; \
		END=$$(date +%s%N); \
		MS=$$(( ($$END - $$START) / 1000000 )); \
		FPS=$$(echo "scale=2; 150 * 1000 / $$MS" | bc 2>/dev/null || echo "N/A"); \
		SPEEDUP=$$(echo "scale=2; 10445 / $$MS" | bc 2>/dev/null || echo "N/A"); \
		echo "  Time    : $${MS} ms" | tee -a $(CFS_LOG); \
		echo "  FPS     : $${FPS}" | tee -a $(CFS_LOG); \
		echo "  Speedup : $${SPEEDUP}x (vs serial 10445ms)" | tee -a $(CFS_LOG)
	@echo "" >> $(CFS_LOG)
	@echo "--- Run 2: SyncPilot IC-RCE aktif (our contribution) ---"
	@echo "=== Run 2: SyncPilot IC-RCE (affinity aktif) ===" >> $(CFS_LOG)
	@echo "IC-RCE profiles dan routing heavy stages ke Big cores"
	@START=$$(date +%s%N); \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_cfs_syncpilot.yuv 20 2>/dev/null; \
		END=$$(date +%s%N); \
		MS=$$(( ($$END - $$START) / 1000000 )); \
		FPS=$$(echo "scale=2; 150 * 1000 / $$MS" | bc 2>/dev/null || echo "N/A"); \
		SPEEDUP=$$(echo "scale=2; 10445 / $$MS" | bc 2>/dev/null || echo "N/A"); \
		echo "  Time    : $${MS} ms" | tee -a $(CFS_LOG); \
		echo "  FPS     : $${FPS}" | tee -a $(CFS_LOG); \
		echo "  Speedup : $${SPEEDUP}x (vs serial 10445ms)" | tee -a $(CFS_LOG)
	@echo ""
	@echo "======================================================="
	@echo "  RINGKASAN"
	@echo "======================================================="
	@grep -E "Time|FPS|Speedup" $(CFS_LOG) | grep -v "==" || true
	@echo "Full log: $(CFS_LOG)"


#
# PREREQUISITE: Tentukan CPU mana Big dan mana LITTLE dulu:
#   cat /sys/devices/system/cpu/cpu*/cpu_capacity
#   (nilai lebih besar = Big core)
#
# Usage:
#   make ipc_proof_20w BIG_CPUS=10-19 LITTLE_CPUS=0-9
#   (sesuaikan setelah lihat hasil EXP-1)
#
# Hipotesa yang diuji:
#   H1: LITTLE core inclusion = penyebab utama IPC turun (bukan cache thrashing)
#   H2: LITTLE inherent IPC lebih rendah dari Big secara arsitektur
#   H3: Cross-cluster L3 contention ikut menurunkan Big core IPC
# -------------------------------------------------------
BIG_CPUS    ?= 10-19
LITTLE_CPUS ?= 0-9
PROOF_DIR    = $(PERF_DIR)/ipc_proof

ipc_proof_20w: $(RESULTS_DIR)/fsrcnn_thread20 $(RESULTS_DIR)/fsrcnn_thread10
	@echo "======================================================="
	@echo "  IPC DROP PROOF: Controlled Experiments (SyncPilot)"
	@echo "======================================================="
	@mkdir -p $(PROOF_DIR) $(OUTPUT_DIR)
	@rm -f $(PROOF_DIR)/*.txt
	@echo "Big CPUs   : $(BIG_CPUS)"
	@echo "LITTLE CPUs: $(LITTLE_CPUS)"
	@echo ""
	@echo "--- EXP-1: CPU Topology Detection ---"
	@echo "=== EXP-1: CPU Topology ===" > $(PROOF_DIR)/exp1_topology.txt
	@echo "cpu_capacity (lebih besar = Big core):" >> $(PROOF_DIR)/exp1_topology.txt
	@for i in $$(seq 0 19); do \
		cap=$$(cat /sys/devices/system/cpu/cpu$$i/cpu_capacity 2>/dev/null || echo "N/A"); \
		echo "  cpu$$i: $$cap" >> $(PROOF_DIR)/exp1_topology.txt; \
	done
	@echo "cluster_id per CPU:" >> $(PROOF_DIR)/exp1_topology.txt
	@for i in $$(seq 0 19); do \
		cid=$$(cat /sys/devices/system/cpu/cpu$$i/topology/cluster_id 2>/dev/null || echo "N/A"); \
		echo "  cpu$$i: cluster $$cid" >> $(PROOF_DIR)/exp1_topology.txt; \
	done
	@cat $(PROOF_DIR)/exp1_topology.txt
	@echo ""
	@echo "--- EXP-2: 20W pinned ke Big cores saja (taskset -c $(BIG_CPUS)) ---"
	@echo "Jika IPC ~ 3.6 = LITTLE-inclusion adalah penyebab IPC turun (H1 terbukti)"
	@echo "=== EXP-2: 20W Big-only ===" > $(PROOF_DIR)/exp2_20w_bigonly.txt
	perf stat -e "cycles,instructions,cache-references,cache-misses" \
		taskset -c $(BIG_CPUS) \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_proof_exp2.yuv 20 \
		2>> $(PROOF_DIR)/exp2_20w_bigonly.txt
	@echo "EXP-2 IPC:"; grep "insn per cycle" $(PROOF_DIR)/exp2_20w_bigonly.txt || true
	@echo ""
	@echo "--- EXP-3: 10W pinned ke LITTLE cores saja (taskset -c $(LITTLE_CPUS)) ---"
	@echo "Mengukur inherent LITTLE IPC tanpa Big core interference (H2)"
	@echo "=== EXP-3: 10W LITTLE-only ===" > $(PROOF_DIR)/exp3_10w_littleonly.txt
	perf stat -e "cycles,instructions,cache-references,cache-misses" \
		taskset -c $(LITTLE_CPUS) \
		$(RESULTS_DIR)/fsrcnn_thread10 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_proof_exp3.yuv 10 \
		2>> $(PROOF_DIR)/exp3_10w_littleonly.txt
	@echo "EXP-3 IPC:"; grep "insn per cycle" $(PROOF_DIR)/exp3_10w_littleonly.txt || true
	@echo ""
	@echo "--- EXP-4: Monitor Big IPC saja saat 20W jalan (perf -C $(BIG_CPUS)) ---"
	@echo "Jika Big IPC turun vs EXP-2 = LITTLE thrash L3 (H3 terbukti)"
	@echo "Jika Big IPC sama = L3 contention tidak terbukti"
	@echo "=== EXP-4: Big core IPC saat 20W+LITTLE aktif ===" \
		> $(PROOF_DIR)/exp4_big_during_20w.txt
	perf stat -C $(BIG_CPUS) \
		-e "cycles,instructions,cache-references,cache-misses" \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_proof_exp4.yuv 20 \
		2>> $(PROOF_DIR)/exp4_big_during_20w.txt
	@echo "EXP-4 IPC:"; grep "insn per cycle" $(PROOF_DIR)/exp4_big_during_20w.txt || true
	@echo ""
	@echo "======================================================="
	@echo "  RINGKASAN PEMBUKTIAN"
	@echo "======================================================="
	@echo "EXP-2 (20W Big-only)             :"; \
		grep "insn per cycle" $(PROOF_DIR)/exp2_20w_bigonly.txt | head -1 || echo "  (tidak ada data)"
	@echo "EXP-3 (10W LITTLE-only)           :"; \
		grep "insn per cycle" $(PROOF_DIR)/exp3_10w_littleonly.txt | head -1 || echo "  (tidak ada data)"
	@echo "EXP-4 (Big IPC saat 20W+LITTLE)  :"; \
		grep "insn per cycle" $(PROOF_DIR)/exp4_big_during_20w.txt | head -1 || echo "  (tidak ada data)"
	@echo ""
	@echo "Interpretasi:"
	@echo "  EXP-2 IPC ~ 3.6 → H1 TERBUKTI: LITTLE inclusion = penyebab utama"
	@echo "  EXP-3 IPC ~ 2.x → H2 TERBUKTI: LITTLE inherent IPC lebih rendah"
	@echo "  EXP-4 IPC < EXP-2 IPC → H3 TERBUKTI: L3 contention dari LITTLE"
	@echo "  EXP-4 IPC = EXP-2 IPC → H3 TIDAK terbukti: L3 contention bukan faktor"
	@echo "Semua hasil di: $(PROOF_DIR)/"

# Run Analysis
analyze:
	@echo "Running scaling analysis..."
	@bash $(IMPLEMENTATION_DIR)/analyze_scaling.sh

# Generate Full Analysis Report
report:
	@echo "Generating comprehensive analysis..."
	@bash $(IMPLEMENTATION_DIR)/generate_full_analysis_report.sh $(RESULTS_DIR)

# Clean build artifacts
clean:
	rm -rf $(RESULTS_DIR)
	@echo "Clean complete"

# Quick scale test (without deep profiling)
# Uses - as a prefix to ignore errors and continue the loop
quick_test: $(TARGETS)
	@echo "Running quick scale test (no profiling)..."
	@mkdir -p $(OUTPUT_DIR)
	@for workers in 1 2 4 8; do \
		echo "--- Workers: $$workers ---" ; \
		cd $(SRC_DIR) && \
		$(RESULTS_DIR)/fsrcnn_thread$$workers $(INPUT_YUV) \
			$(OUTPUT_DIR)/out_thread$$workers.yuv $$workers \
			&& echo "OK: thread$$workers" \
			|| echo "FAILED: thread$$workers (continuing...)" ; \
	done

# Install dependencies
install:
	@echo "Installing profiling tools..."
	@sudo apt-get update
	@sudo apt-get install -y gprof gcc libpthread-stubs0-dev clocksource-freq-tools

# Help
help:
	@echo "FSRCNN Profiling Suite - Available targets:"
	@echo "  all              - Build all configurations (default)"
	@echo "  clean            - Remove all build artifacts"
	@echo "  profiling        - Run full gprof + perf stat profiling"
	@echo "  gprof_10w        - gprof flat profile for SyncPilot-10W (all-Big baseline)"
	@echo "  gprof_20w        - gprof flat profile for SyncPilot-20W"
	@echo "  ipc_analysis_20w - Detailed IPC degradation analysis (20W)"
	@echo "  ipc_proof_20w    - 4 controlled experiments to PROVE IPC drop cause"
	@echo "  cfs_comparison   - CFS LITTLE/Big vs SyncPilot IC-RCE wall-clock"
	@echo "                     (default: BIG_CPUS=10-19 LITTLE_CPUS=0-9)"
	@echo "                     (run EXP-1 first to verify CPU topology!)"
	@echo "  analyze          - Run scaling analysis"
	@echo "  report           - Generate comprehensive analysis report"
	@echo "  quick_test       - Execute without profiling (fast)"
	@echo "  install          - Install required tools"
	@echo "  help             - Show this help message"

.PHONY: all clean profiling gprof_10w gprof_20w ipc_analysis_20w ipc_proof_20w cfs_comparison analyze report quick_test install help
