# Memory Subsystem — CompArc 350C

A full cache hierarchy implemented in SystemVerilog for the DE10-Nano (Cyclone V) FPGA.

```
Trace → LSQ (16-entry) → dTLB (16-entry, FA) → L1 (512B, 2-way) → L2 (4KB, 4-way) → DDR3
```

---

## Architecture Overview

| Component | File | Description |
|---|---|---|
| **Load-Store Queue** | `lsq.sv` | 16-entry in-order queue. Decodes trace records (LOAD, STORE, RESOLVE, TLB_FILL). Issues to TLB then cache. |
| **Data TLB** | `dtlb.sv` | 16-entry fully-associative TLB. 4KB pages. Tree-PLRU replacement. 1-cycle hit. |
| **L1 Data Cache** | `L1_Cache.sv` | 2-way set-associative, 4 sets, 64B lines (512B total). 2-entry MSHR with store merging. LRU replacement. |
| **L2 Cache** | `L2_copy.sv` | 4-way set-associative, 16 sets (sim) / 4 sets (FPGA), 64B lines. 4-entry MSHR. Tree-PLRU. Dirty writeback on eviction. |
| **Avalon Master** | `avalon_mem_master.sv` | Bridges L2's 512-bit cache-line requests to 8x64-bit Avalon-MM burst transactions for DDR3 access. |
| **Top Wrapper** | `top_with_L1.sv` | Connects LSQ → TLB → L1 → L2. Parameters: `USE_REAL_L2`, `USE_AVALON`, `L2_SETS`. |
| **Shared Types** | `cacheDataTypes.sv` | `op_e` enum, `mshr_entry_t` struct. |

### Cache Geometry

| | L1 | L2 (sim) | L2 (FPGA) |
|---|---|---|---|
| Ways | 2 | 4 | 4 |
| Sets | 4 | 16 | 4 |
| Line size | 64B | 64B | 64B |
| Total data | 512B | 4KB | 1KB |
| Replacement | LRU (1-bit) | Tree-PLRU (3-bit) | Tree-PLRU (3-bit) |
| MSHRs | 2 | 4 | 4 |
| Write policy | Write-back, allocate | Write-back, allocate | Write-back, allocate |

### Trace Format (v2, 121 bits)

Each trace record is a 121-bit `trace_line` built from two 64-bit PIO registers:

```
trace_line[120:0] = { adder_b[56:0], adder_a[63:0] }

adder_a[47:0]  = vaddr
adder_a[51:48] = id (0-15)
adder_a[54:52] = op (0=LOAD, 1=STORE, 2=RESOLVE, 4=TLB_FILL)
adder_a[55]    = vaddr_is_valid
adder_a[63:56] = value[7:0]
adder_b[55:0]  = value[63:8]
adder_b[56]    = value_is_valid
```

Binary trace files (`*.bin`) use 16 bytes per record (little-endian).

---

## Prerequisites

- **WSL Ubuntu** (tested on 22.04)
- **Verilator 5.x** with `--timing` support:
  ```bash
  sudo apt-get update
  sudo apt-get install -y verilator build-essential
  ```
  Verify: `verilator --version` (needs 5.006+)

---

## Quick Start (Simulation)

```bash
# From WSL, cd into the MemorySystem directory
cd /mnt/c/<your-path>/CompArcMem/MemorySystem

# Build and run the trace verification test
make test

# Or step by step:
make build           # compile with Verilator
make run             # run with default trace (dgemm3_lsq88.bin, 500 records)
make run-2k          # run with 2000 records
make clean           # remove build artifacts
```

---

## How to Verify Correctness

### What `make test` does

1. **Phase 1 — Trace Replay**: Feeds a binary memory trace (`dgemm3_lsq88.bin`) through the full hierarchy. The testbench (`verify_trace_tb.sv`) records every STORE's virtual address and expected value in a shadow memory table.

2. **Phase 2 — Store Verification**: After the trace drains, the testbench re-issues TLB fills and LOADs for every address that was STOREd. It compares the data returned by the cache hierarchy against the expected values.

### What "passing" looks like

```
Phase 2 (Store Verification):
    addresses checked       : 111
    PASS                    : 111
    FAIL                    : 0
    TIMEOUT                 : 0

>>> ALL STORES VERIFIED SUCCESSFULLY <<<
```

**111/111 PASS** = every store written during the trace was correctly persisted through L1 → L2 → backing memory and can be read back with the correct value.

### What a failure means

- **FAIL**: Data read back doesn't match what was stored → bug in cache data path, eviction, or writeback logic.
- **TIMEOUT**: Cache never responded to a read → stuck MSHR, lost request, or deadlock.

### Available traces

| File | Description |
|---|---|
| `mem-traces-v2/traces/dgemm3_lsq88.bin` | DGEMM kernel, LSQ-friendly ordering. **Use this one.** |
| `mem-traces-v2/traces/dgemm3.bin` | Same kernel, raw order. Also passes. |
| `mem-traces-v2/traces/dgemm3_lsq88_real.bin` | Full trace with out-of-order resolves. Known to timeout (LSQ limitation). |

---

## FPGA Deployment (DE10-Nano)

### Files needed on the board

| File | What it is |
|---|---|
| `transfer_quatus/output_files/soc_system.rbf` | FPGA bitstream |
| `transfer_quatus/software/hps_mem_test/mem_test.c` | HPS test driver |
| `mem-traces-v2/traces/dgemm3_lsq88.bin` | Trace file to replay |

### Step-by-step

```bash
# 1. Copy files to DE10-Nano (from Windows PowerShell)
scp transfer_quatus/output_files/soc_system.rbf root@<BOARD_IP>:/root/
scp transfer_quatus/software/hps_mem_test/mem_test.c root@<BOARD_IP>:/root/
scp mem-traces-v2/traces/dgemm3_lsq88.bin root@<BOARD_IP>:/root/

# 2. SSH in
ssh root@<BOARD_IP>

# 3. Program the FPGA
mkdir -p /lib/firmware
cp soc_system.rbf /lib/firmware/
echo soc_system.rbf > /sys/class/fpga_manager/fpga0/firmware
# (alternative: dd if=soc_system.rbf of=/dev/fpga0 bs=1M)

# 4. Build the test program (one-time: apt-get install -y gcc)
gcc -O2 -o mem_test mem_test.c

# 5. Run smoke test
./mem_test smoke

# 6. Replay a trace
./mem_test trace dgemm3_lsq88.bin 100
```

### How to know the FPGA is working

- **LED[0]** blinks when the cache returns data
- `./mem_test status` shows changing register values (not all zeros)
- `./mem_test smoke` prints status lines where `ret_data` and `wb_addr` change between reads

### FPGA-specific parameters

When synthesised for the Cyclone V (USE_AVALON=1):
- `backing_mem` shrinks to 1 entry (eliminated ~2M register bits)
- L2 uses 4 sets instead of 16 (fits within 4191 LABs)
- L2 reads/writes go through the Avalon master → HPS DDR3

---

## File Map

```
MemorySystem/
├── cacheDataTypes.sv          # Shared types (op_e enum, mshr_entry_t)
├── lsq.sv                     # Load-Store Queue (16-entry)
├── dtlb.sv                    # Data TLB (16-entry, fully-associative)
├── L1_Cache.sv                # L1 data cache (2-way, 4 sets)
├── L2_copy.sv                 # L2 cache (4-way, parameterised sets)
├── dummy_L2.sv                # Stub L2 (instant response, for unit tests)
├── avalon_mem_master.sv       # Avalon-MM bridge (512b ↔ 8x64b)
├── top_with_L1.sv             # Hierarchy wrapper (LSQ→TLB→L1→L2)
├── verify_trace_tb.sv         # Main verification testbench
├── Makefile                   # Build/test automation (WSL)
├── README.md                  # This file
├── ASSIGNMENT.md              # Original assignment spec
│
├── mem-traces-v2/traces/      # Binary trace files
│   ├── dgemm3_lsq88.bin       #   ← primary test trace
│   ├── dgemm3.bin
│   └── ...
│
└── transfer_quatus/           # Quartus FPGA project (DE10-Nano)
    ├── DE10_NANO_SoC_GHRD.v   #   FPGA top-level
    ├── DE10_NANO_SoC_GHRD.qsf #   Quartus settings
    ├── soc_system.qsys        #   Platform Designer system
    ├── ip/mem_subsystem/       #   RTL copies for Quartus
    ├── output_files/
    │   └── soc_system.rbf     #   Pre-built bitstream
    └── software/
        └── hps_mem_test/
            ├── mem_test.c     #   HPS-side C driver
            └── Makefile       #   ARM cross-compile
```

---

## Known Limitations

1. **OOO resolves**: The LSQ processes resolves in FIFO order. Traces with out-of-order resolve IDs (like `dgemm3_lsq88_real.bin`) can cause timeouts — the resolve gets stuck waiting behind an earlier unresolved entry.
2. **No L2→L1 back-invalidation**: L2 evictions don't invalidate stale copies in L1 (no inclusion enforcement).
3. **L1 LRU is inverted**: The single LRU bit updates backwards (updates on the evicted way instead of accessed way). Works functionally but may show suboptimal hit rates.
4. **L2 hit latency**: Currently 2 cycles (1 input-latch + 1 tag-check). Design spec calls for 5 cycles.
