#!/bin/bash

# Autonomous Profiling Script for FSRCNN SyncPilot
# Purpose: Scale testing 1-8 threads with gprof and perf stat profiling

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
SRC_DIR="${PROJECT_DIR}/example/fsrcnn"
FRAMES=150
INPUT_FILE="suzie_176x144.yuv"
OUTPUT_DIR="${PROJECT_DIR}/results"
PROFILES_DIR="${OUTPUT_DIR}/gprof"
LOGS_DIR="${OUTPUT_DIR}/logs"
PERF_DIR="${OUTPUT_DIR}/perf_stat"

mkdir -p ${OUTPUT_DIR}
mkdir -p ${PROFILES_DIR}
mkdir -p ${LOGS_DIR}
mkdir -p ${PERF_DIR}
