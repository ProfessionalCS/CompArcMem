# ──────────────────────────────────────────────────────────────────────────
# Makefile — Memory Subsystem (WSL / Linux)
#
# Usage:
#   make              # build + run 500-record test (same as 'make test')
#   make build        # compile only
#   make run          # run 500 records
#   make run-2k       # run 2000 records
#   make run-full     # run full trace (dgemm3.bin, 2000 records)
#   make test         # build + run, fail if any stores don't verify
#   make clean        # remove build artifacts
#   make sync-fpga    # copy RTL into transfer_quatus/ for Quartus
# ──────────────────────────────────────────────────────────────────────────

# ── Tool config ──────────────────────────────────────────────────────────
VERILATOR   := verilator
VLAT_FLAGS  := -Wall --binary --timing -j 0 -Wno-fatal
TOP_MODULE  := verify_trace_tb
SIM_BIN     := obj_dir/V$(TOP_MODULE)

# ── RTL sources (order doesn't matter for Verilator) ────────────────────
RTL_SRCS := \
    verify_trace_tb.sv \
    top_with_L1.sv \
    lsq.sv \
    dtlb.sv \
    L1_Cache.sv \
    L2_copy.sv \
    cacheDataTypes.sv

# ── Simulation parameters ───────────────────────────────────────────────
TRACE_DIR   := mem-traces-v2/traces
TRACE_FILE  := $(TRACE_DIR)/dgemm3_lsq88.bin
DRAIN       := 6000
GAP         := 3

# Plus-args passed to the simulator
RUN_ARGS = +TRACE_FILE=$(TRACE_FILE) +DRAIN_CYCLES=$(DRAIN) +TRACE_GAP_CYCLES=$(GAP)

# ── Default target ───────────────────────────────────────────────────────
.PHONY: all
all: test

# ── Build ────────────────────────────────────────────────────────────────
$(SIM_BIN): $(RTL_SRCS)
	$(VERILATOR) $(VLAT_FLAGS) \
		-GUSE_REAL_L2=1 \
		--top-module $(TOP_MODULE) \
		$(RTL_SRCS)

.PHONY: build
build: $(SIM_BIN)

# ── Run variants ─────────────────────────────────────────────────────────
.PHONY: run
run: $(SIM_BIN)
	@echo "════════════════════════════════════════════════════"
	@echo " Running: 500 records from $(TRACE_FILE)"
	@echo "════════════════════════════════════════════════════"
	$(SIM_BIN) $(RUN_ARGS) +MAX_REC=500

.PHONY: run-2k
run-2k: $(SIM_BIN)
	@echo "════════════════════════════════════════════════════"
	@echo " Running: 2000 records from $(TRACE_FILE)"
	@echo "════════════════════════════════════════════════════"
	$(SIM_BIN) $(RUN_ARGS) +MAX_REC=2000

.PHONY: run-full
run-full: $(SIM_BIN)
	@echo "════════════════════════════════════════════════════"
	@echo " Running: 2000 records from dgemm3.bin"
	@echo "════════════════════════════════════════════════════"
	$(SIM_BIN) +TRACE_FILE=$(TRACE_DIR)/dgemm3.bin +MAX_REC=2000 \
		+DRAIN_CYCLES=$(DRAIN) +TRACE_GAP_CYCLES=$(GAP)

# ── Test (build + run + check for ALL STORES VERIFIED) ──────────────────
.PHONY: test
test: $(SIM_BIN)
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║  Building & verifying memory subsystem          ║"
	@echo "╚══════════════════════════════════════════════════╝"
	@echo ""
	@echo "── Test 1: dgemm3_lsq88.bin (500 records) ─────────"
	@$(SIM_BIN) $(RUN_ARGS) +MAX_REC=500 2>&1 | tee /tmp/mem_test1.log
	@grep -q "ALL STORES VERIFIED SUCCESSFULLY" /tmp/mem_test1.log || \
		(echo "FAIL: Test 1 did not pass" && exit 1)
	@echo ""
	@echo "── Test 2: dgemm3_lsq88.bin (2000 records) ────────"
	@$(SIM_BIN) $(RUN_ARGS) +MAX_REC=2000 2>&1 | tee /tmp/mem_test2.log
	@grep -q "ALL STORES VERIFIED SUCCESSFULLY" /tmp/mem_test2.log || \
		(echo "FAIL: Test 2 did not pass" && exit 1)
	@echo ""
	@echo "── Test 3: dgemm3.bin (2000 records) ───────────────"
	@$(SIM_BIN) +TRACE_FILE=$(TRACE_DIR)/dgemm3.bin +MAX_REC=2000 \
		+DRAIN_CYCLES=$(DRAIN) +TRACE_GAP_CYCLES=$(GAP) 2>&1 | tee /tmp/mem_test3.log
	@grep -q "ALL STORES VERIFIED SUCCESSFULLY" /tmp/mem_test3.log || \
		(echo "FAIL: Test 3 did not pass" && exit 1)
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║  ALL 3 TESTS PASSED ✓                           ║"
	@echo "╚══════════════════════════════════════════════════╝"

# ── Sync RTL to Quartus IP folder ───────────────────────────────────────
FPGA_IP_DIR := transfer_quatus/ip/mem_subsystem

.PHONY: sync-fpga
sync-fpga:
	@echo "Syncing RTL to $(FPGA_IP_DIR)/ ..."
	@mkdir -p $(FPGA_IP_DIR)
	cp L1_Cache.sv        $(FPGA_IP_DIR)/
	cp L2_copy.sv         $(FPGA_IP_DIR)/
	cp lsq.sv             $(FPGA_IP_DIR)/
	cp dtlb.sv            $(FPGA_IP_DIR)/
	cp cacheDataTypes.sv  $(FPGA_IP_DIR)/
	cp top_with_L1.sv     $(FPGA_IP_DIR)/
	cp avalon_mem_master.sv $(FPGA_IP_DIR)/
	@echo "Done. Now recompile in Quartus."

# ── Cross-compile HPS test program (needs arm-linux-gnueabihf-gcc) ─────
.PHONY: hps-test
hps-test:
	@echo "Cross-compiling HPS mem_test for ARM ..."
	arm-linux-gnueabihf-gcc -O2 -static -o mem_test_arm \
		transfer_quatus/software/hps_mem_test/mem_test.c
	@echo "Built: mem_test_arm (static binary, scp to board)"

# ── Clean ────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -rf obj_dir
	rm -f mem_test_arm
	rm -f /tmp/mem_test1.log /tmp/mem_test2.log /tmp/mem_test3.log

# ── Help ─────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Memory Subsystem Makefile"
	@echo ""
	@echo "  make              Build + run all 3 verification tests"
	@echo "  make build        Compile with Verilator only"
	@echo "  make run          Run 500-record test"
	@echo "  make run-2k       Run 2000-record test"
	@echo "  make run-full     Run 2000 records of dgemm3.bin"
	@echo "  make test         Build + run all tests, exit 1 on failure"
	@echo "  make sync-fpga    Copy RTL into transfer_quatus/ for Quartus"
	@echo "  make hps-test     Cross-compile HPS test program for ARM"
	@echo "  make clean        Remove build artifacts"
	@echo "  make help         Show this message"
