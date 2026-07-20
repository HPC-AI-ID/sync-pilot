# Makefile for FSRCNN Profiling & Testing Suite
# Supported: gprof profiling, perf stat, progressive scaling

CC = gcc
CFLAGS = -O3 -Wall -march=native -fno-inline-functions -mtune=native -pg
LDFLAGS = -lm -lrt -lpthread

# Directories
PROJECT_DIR = $(dir $(abspath $(lastword $(MAKEFILE_LIST))))..
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
          $(RESULTS_DIR)/fsrcnn_thread4 $(RESULTS_DIR)/fsrcnn_thread8

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

# Run Full Profiling Suite
# Note: perf requires CAP_PERFMON or perf_event_paranoid <= 0.
#   To allow without sudo (requires root once):
#     echo "kernel.perf_event_paranoid = -1" | sudo tee -a /etc/sysctl.conf
#     sudo sysctl -p
#   Or run this target with sudo:
#     sudo make run_profiling
run_profiling: $(TARGETS)
	@echo "=========================================="
	@echo "Running Full Profiling Suite..."
	@echo "=========================================="
	@mkdir -p $(OUTPUT_DIR) $(GPROF_DIR) $(PERF_DIR)
	@for workers in 1 2 4 8; do \
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
			$(OUTPUT_DIR)/out_thread$$workers.yuv $$workers > $(PERF_DIR)/perf_thread$$workers.txt || echo "perf stat failed" ; \
	done

# Alias for run_profiling
profiling: run_profiling

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
	@cp -f $(SRC_DIR)/weights_layer*.txt $(SRC_DIR)/biasess_layer*.txt $(RESULTS_DIR)/
	@for workers in 1 2 4 8; do \
		echo "--- Workers: $$workers ---" ; \
		cd $(SRC_DIR) && \
		$(RESULTS_DIR)/fsrcnn_thread$$workers $(INPUT_YUV) \
			../$(OUTPUT_DIR)/out_thread$$workers.yuv $$workers \
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
	@echo "  all       - Build all configurations (default)"
	@echo "  clean     - Remove all build artifacts"
	@echo "  profiling - Run full gprof + perf stat profiling"
	@echo "  analyze   - Run scaling analysis"
	@echo "  report    - Generate comprehensive analysis report"
	@echo "  quick_test - Execute without profiling (fast)"
	@echo "  install   - Install required tools"
	@echo "  help      - Show this help message"

.PHONY: all clean profiling analyze report quick_test install help
