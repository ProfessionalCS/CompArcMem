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
	cp L1_Cache.sv          $(FPGA_IP_DIR)/
	cp L2_copy.sv           $(FPGA_IP_DIR)/
	cp lsq.sv               $(FPGA_IP_DIR)/
	cp dtlb.sv              $(FPGA_IP_DIR)/
	cp cacheDataTypes.sv    $(FPGA_IP_DIR)/
	cp top_with_L1.sv       $(FPGA_IP_DIR)/
	cp avalon_mem_master.sv $(FPGA_IP_DIR)/
	cp transfer_quatus/DE10_NANO_SoC_GHRD.v transfer_quatus/
	@echo "Done. Now recompile in Quartus (DE10_NANO_SoC_GHRD.v has the sticky status fix)."

# ── Cross-compile HPS test programs (needs arm-linux-gnueabihf-gcc) ─────
ARM_CC      := arm-linux-gnueabihf-gcc
HPS_SRC_DIR := transfer_quatus/software/hps_mem_test

.PHONY: hps-test
hps-test:
	@echo "Cross-compiling HPS programs for ARM ..."
	$(ARM_CC) -O2 -static -o mem_test_arm      $(HPS_SRC_DIR)/mem_test.c
	$(ARM_CC) -O2 -static -o fpga_manual_arm   $(HPS_SRC_DIR)/fpga_manual.c
	$(ARM_CC) -O2 -static -o enable_bridges_arm $(HPS_SRC_DIR)/enable_bridges.c
	$(ARM_CC) -O2 -static -o devmem2_arm        $(HPS_SRC_DIR)/devmem2.c
	@echo "Built: mem_test_arm, fpga_manual_arm, enable_bridges_arm, devmem2_arm"

# ── Convert SOF → RBF (requires Quartus on PATH or Windows) ────────────
QUARTUS_DIR := transfer_quatus
SOF_FILE    := $(QUARTUS_DIR)/output_files/DE10_NANO_SoC_GHRD.sof
RBF_FILE    := $(QUARTUS_DIR)/output_files/soc_system.rbf

.PHONY: rbf
rbf: $(RBF_FILE)

$(RBF_FILE): $(SOF_FILE)
	quartus_cpf -c -o bitstream_compression=on $< $@
	@echo "Created $@"

# ── Board connection defaults ────────────────────────────────────────────
BOARD_IP   ?= 192.168.0.2
BOARD_USER ?= root
BOARD_PASS ?= root

# SSH/SCP shortcuts
SSHPASS := $(shell command -v sshpass 2>/dev/null)

ifeq ($(strip $(SSHPASS)),)
SSH  := ssh -o StrictHostKeyChecking=no $(BOARD_USER)@$(BOARD_IP)
BSCP := scp -o StrictHostKeyChecking=no
else
SSH  := $(SSHPASS) -p $(BOARD_PASS) ssh -o StrictHostKeyChecking=no $(BOARD_USER)@$(BOARD_IP)
BSCP := $(SSHPASS) -p $(BOARD_PASS) scp -o StrictHostKeyChecking=no
endif

# ── Deploy to DE10-Nano (full: DTB + RBF + auto-bridge + reboot) ────────
.PHONY: deploy
deploy:
	@echo "Running full board deployment ..."
	bash deploy_to_board.sh

# ── Quick deploy: copy files + compile on board (no reboot) ─────────────
.PHONY: deploy-quick
deploy-quick:
	@echo "Quick deploy: uploading + compiling on board ..."
	$(SSH) "mkdir -p /root/deploy"
	$(BSCP) $(HPS_SRC_DIR)/mem_test.c $(HPS_SRC_DIR)/manual_test.c \
		$(HPS_SRC_DIR)/ddr3_test.c \
		$(HPS_SRC_DIR)/devmem_verify.c \
		$(HPS_SRC_DIR)/fpga_manual.c $(HPS_SRC_DIR)/enable_bridges.c \
		$(HPS_SRC_DIR)/fix_bridges.c $(HPS_SRC_DIR)/test_h2f.c \
		$(HPS_SRC_DIR)/devmem2.c $(HPS_SRC_DIR)/board_setup.sh \
		$(HPS_SRC_DIR)/run_trace.sh \
		$(BOARD_USER)@$(BOARD_IP):/root/deploy/
	$(BSCP) mem-traces-v2/traces/dgemm3_lsq88.bin \
		$(BOARD_USER)@$(BOARD_IP):/root/deploy/
	$(SSH) "cd /root/deploy && chmod +x board_setup.sh run_trace.sh && \
		gcc -O2 -o mem_test mem_test.c && \
		gcc -O2 -o manual_test manual_test.c && \
		gcc -O2 -o ddr3_test ddr3_test.c && \
		gcc -O2 -o devmem_verify devmem_verify.c && \
		gcc -O2 -o fpga_manual fpga_manual.c 2>/dev/null || true && \
		gcc -O2 -o enable_bridges enable_bridges.c && \
		gcc -O2 -o fix_bridges fix_bridges.c && \
		gcc -O2 -o test_h2f test_h2f.c 2>/dev/null || true && \
		gcc -O2 -o devmem2 devmem2.c 2>/dev/null || true && \
		cp devmem2 /usr/local/bin/devmem2 2>/dev/null || true && \
		echo BUILD_OK"
	@echo "Quick deploy done. Run: make board-ddr3  (DDR3 proof) or make board-smoke"

# ── Full board recovery (from fresh/corrupted image) ────────────────────
.PHONY: recover
recover:
	@echo "Running full board recovery ..."
	bash recover_board.sh

# ── Fix bridges NOW (no reboot needed) ──────────────────────────────────
.PHONY: board-fix-bridges
board-fix-bridges:
	@echo "Running fix_bridges on board ..."
	$(SSH) "cd /root/deploy && ./fix_bridges 2>&1"
	@echo "Bridges fixed. Run: make board-smoke"

# ── Run board_setup.sh on board (compile + service + bridges + test) ─────
# Uploads and runs the all-in-one board-side setup script.
.PHONY: board-setup
board-setup:
	@echo "Uploading board_setup.sh and running on board ..."
	$(SSH) "mkdir -p /root/deploy"
	$(BSCP) $(HPS_SRC_DIR)/board_setup.sh $(BOARD_USER)@$(BOARD_IP):/root/deploy/
	$(SSH) "chmod +x /root/deploy/board_setup.sh && cd /root/deploy && bash board_setup.sh"

# ── Install the systemd auto-bridge service (persists across reboots) ───
.PHONY: board-install-service
board-install-service: board-setup

# ── Run smoke test on board ─────────────────────────────────────────────
.PHONY: board-smoke
board-smoke:
	$(SSH) "cd /root/deploy && ./mem_test smoke 2>&1"

# ── DDR3 access proof (simple PASS/FAIL) ────────────────────────────────
.PHONY: board-ddr3
board-ddr3:
	@echo "Running DDR3 access test on board $(BOARD_IP) ..."
	$(SSH) "cd /root/deploy && ./ddr3_test 2>&1"

# ── devmem verify: store via FPGA, read back with /dev/mem ──────────────
.PHONY: board-devmem-verify
board-devmem-verify:
	@echo "Running devmem_verify on board $(BOARD_IP) ..."
	$(SSH) "cd /root/deploy && ./devmem_verify 2>&1"

# ── Run manual_test correctness suite ────────────────────────────────────
.PHONY: board-test
board-test:
	$(SSH) "cd /root/deploy && ./manual_test clean test 2>&1"

# ── Check board status (FPGA + bridges + service + H2F) ─────────────────
.PHONY: board-status
board-status:
	@$(SSH) '\
		echo "=== Board Status ==="; \
		echo "FPGA:    $$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo UNKNOWN)"; \
		for br in br0 br1 br2 br3; do \
		  echo "$$br:     $$(cat /sys/class/fpga_bridge/$$br/state 2>/dev/null || echo MISSING)"; \
		done; \
		echo "Service: $$(systemctl is-active fpga-bridges.service 2>/dev/null || echo not-installed)"; \
		echo "---"; \
		if [ -f /root/deploy/test_h2f ]; then \
		  cd /root/deploy && ./test_h2f 2>&1 && echo "H2F:     OK" || echo "H2F:     FAIL (run: make board-fix-bridges)"; \
		else \
		  echo "H2F:     test_h2f not found"; \
		fi'

# ── Reboot the board ────────────────────────────────────────────────────
.PHONY: board-reboot
board-reboot:
	$(SSH) "sync; reboot" 2>/dev/null || true
	@echo "Reboot sent. Wait ~40s, then: make board-status"

# ── Reboot + wait + verify (blocking) ───────────────────────────────────
.PHONY: board-reboot-wait
board-reboot-wait:
	$(SSH) "sync; reboot" 2>/dev/null || true
	@echo "Reboot sent. Waiting 40s ..."
	sleep 40
	@for i in $$(seq 1 15); do \
		ping -c 1 -W 2 $(BOARD_IP) > /dev/null 2>&1 && break; \
		echo "  Waiting... ($$i)"; \
		sleep 5; \
	done
	sleep 5
	@echo "Board is back. Checking status ..."
	$(MAKE) board-status

# ── Run trace replay on board ───────────────────────────────────────────
TRACE_DELAY ?= 10
.PHONY: board-trace
board-trace:
	$(SSH) "cd /root/deploy && ./mem_test trace dgemm3_lsq88.bin $(TRACE_DELAY)"

# ── Install devmem2 on board ────────────────────────────────────────────
.PHONY: board-install-devmem
board-install-devmem:
	@echo "Installing devmem2 on board $(BOARD_IP) ..."
	$(BSCP) $(HPS_SRC_DIR)/devmem2.c $(BOARD_USER)@$(BOARD_IP):/tmp/devmem2.c
	$(SSH) "gcc -O2 -o /usr/local/bin/devmem2 /tmp/devmem2.c && \
		chmod +x /usr/local/bin/devmem2 && echo 'devmem2 installed'"

# ── Quick devmem2 read/write ────────────────────────────────────────────
DEVMEM_ADDR  ?= 0xC0000000
DEVMEM_WIDTH ?= w
DEVMEM_VAL   ?=
.PHONY: board-devmem
board-devmem:
	$(SSH) "devmem2 $(DEVMEM_ADDR) $(DEVMEM_WIDTH) $(DEVMEM_VAL)"

# ── Board SSH (interactive shell) ────────────────────────────────────────
.PHONY: board-ssh
board-ssh:
	$(SSH)

# ── Clean ────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -rf obj_dir
	rm -f mem_test_arm fpga_manual_arm enable_bridges_arm devmem2_arm
	rm -f /tmp/mem_test1.log /tmp/mem_test2.log /tmp/mem_test3.log

# ── Help ─────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Memory Subsystem Makefile"
	@echo ""
	@echo "  Simulation (WSL/Linux):"
	@echo "    make              Build + run all 3 verification tests"
	@echo "    make build        Compile with Verilator only"
	@echo "    make run          Run 500-record test"
	@echo "    make run-2k       Run 2000-record test"
	@echo "    make run-full     Run 2000 records of dgemm3.bin"
	@echo "    make test         Build + run all tests, exit 1 on failure"
	@echo ""
	@echo "  Deploy (Host → Board):"
	@echo "    make deploy              Full deployment (DTB + RBF + auto-bridge + reboot)"
	@echo "    make deploy-quick        Upload sources + compile (no reboot)"
	@echo "    make recover             Full recovery from corrupted/fresh image"
	@echo ""
	@echo "  Board Operations:"
	@echo "    make board-setup         Compile + service + bridges + test (all-in-one)"
	@echo "    make board-smoke         Smoke test (store + load back)"
	@echo "    make board-ddr3          DDR3 proof: store → evict → load from DDR3 (PASS/FAIL)"
	@echo "    make board-devmem-verify  Store via FPGA, read back with CPU /dev/mem (gold proof)"
	@echo "    make board-test          Run manual_test correctness suite"
	@echo "    make board-trace         Replay trace file (TRACE_DELAY=10)"
	@echo "    make board-status        FPGA + bridges + H2F test"
	@echo "    make board-fix-bridges   Enable bridges NOW (no reboot)"
	@echo "    make board-install-service  Same as board-setup (alias)"
	@echo "    make board-reboot        Reboot board"
	@echo "    make board-reboot-wait   Reboot + wait + verify"
	@echo "    make board-ssh           Interactive SSH to board"
	@echo "    make board-devmem        Read/write phys addr (ADDR=0x.. VAL=0x..)"
	@echo ""
	@echo "  FPGA Build:"
	@echo "    make sync-fpga    Copy RTL into transfer_quatus/ for Quartus"
	@echo "    make rbf          Convert SOF to RBF (needs quartus_cpf)"
	@echo "    make hps-test     Cross-compile HPS programs for ARM"
	@echo ""
	@echo "  Cleanup:"
	@echo "    make clean        Remove build artifacts"
	@echo "    make help         Show this message"
