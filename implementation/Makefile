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
# Measures: stall cycles, branch misses, LLC misses, bus cycles
# Usage: make ipc_analysis_20w
# Produces: $(PERF_DIR)/ipc_analysis_thread20.txt
# -------------------------------------------------------
ipc_analysis_20w: $(RESULTS_DIR)/fsrcnn_thread20
	@echo "=== IPC Degradation Analysis: SyncPilot-20W ==="
	@mkdir -p $(OUTPUT_DIR) $(PERF_DIR)
	@echo "--- Pass 1: Pipeline stall counters ---"
	perf stat \
		-e cycles,instructions,\
arcpmu/stall_slot/,\
arcpmu/stall_frontend/,\
arcpmu/stall_backend/,\
arcpmu/stall_backend_mem/ \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass1.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt || \
	perf stat \
		-e cycles,instructions,\
stalled-cycles-frontend,\
stalled-cycles-backend,\
branch-misses,\
cache-misses \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass1.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "--- Pass 2: Memory bandwidth & LLC ---"
	perf stat \
		-e cycles,instructions,\
L1-dcache-loads,L1-dcache-load-misses,\
L1-dcache-stores,\
LLC-loads,LLC-load-misses,\
mem-loads,mem-stores \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass2.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "--- Pass 3: Context-switch & migration overhead ---"
	perf stat \
		-e cycles,instructions,\
context-switches,cpu-migrations,\
task-clock,\
cpu-clock \
		$(RESULTS_DIR)/fsrcnn_thread20 $(INPUT_YUV) \
		$(OUTPUT_DIR)/out_ipc20_pass3.yuv 20 \
		2>> $(PERF_DIR)/ipc_analysis_thread20.txt
	@echo "IPC analysis saved to $(PERF_DIR)/ipc_analysis_thread20.txt"
	@echo ""
	@echo "=== QUICK SUMMARY ==="
	@grep -E "insn per cycle|stall|miss|migration|switch" \
		$(PERF_DIR)/ipc_analysis_thread20.txt || true

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
	@echo "  gprof_20w        - gprof flat profile for SyncPilot-20W"
	@echo "  ipc_analysis_20w - Detailed IPC degradation analysis (20W)"
	@echo "  analyze          - Run scaling analysis"
	@echo "  report           - Generate comprehensive analysis report"
	@echo "  quick_test       - Execute without profiling (fast)"
	@echo "  install          - Install required tools"
	@echo "  help             - Show this help message"

.PHONY: all clean profiling gprof_20w ipc_analysis_20w analyze report quick_test install help
