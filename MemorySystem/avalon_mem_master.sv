`timescale 1ns/1ps
/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off BLKSEQ */

// ════════════════════════════════════════════════════════════════════════════
// avalon_mem_master — Avalon-MM master that bridges L2 cache miss/eviction
//                     traffic to the HPS DDR3 via the f2h_sdram0 port.
//
//   The f2h_sdram0_data slave is 256-bit wide.  Our cache lines are 512-bit
//   (64 bytes).  Instead of burst transfers, we issue 2 individual 256-bit
//   reads or writes per cache line (lower half then upper half).
//
//   L2 interface (simple req/resp):
//     Read  : mem_rd_req + mem_rd_addr  →  mem_rd_valid + mem_rd_data (512b)
//     Write : mem_wr_req + mem_wr_addr + mem_wr_data (512b)  →  mem_wr_done
//
//   Avalon-MM master (no-burst, 256-bit data):
//     avm_address, avm_read, avm_readdata, avm_readdatavalid,
//     avm_write, avm_writedata, avm_byteenable, avm_waitrequest
// ════════════════════════════════════════════════════════════════════════════

module avalon_mem_master (
    input  logic         clk,
    input  logic         rst_n,

    // ── L2 read-miss interface (L2 → this module) ───────────────────────
    input  logic         mem_rd_req,       // pulse: L2 wants to read a line
    input  logic [23:0]  mem_rd_addr,      // block address (paddr[29:6])
    output logic         mem_rd_valid,     // pulse: 512-bit line ready
    output logic [511:0] mem_rd_data,      // the fetched cache line

    // ── L2 dirty-eviction interface (L2 → this module) ──────────────────
    input  logic         mem_wr_req,       // pulse: L2 wants to write back a line
    input  logic [23:0]  mem_wr_addr,      // block address (paddr[29:6])
    input  logic [511:0] mem_wr_data,      // 512-bit dirty line to write
    output logic         mem_wr_done,      // pulse: write completed

    // ── Busy flag (L2 should not issue new req while busy) ──────────────
    output logic         mem_busy,

    // ── Avalon-MM master (directly wired to f2h_sdram0 conduit) ─────────
    output logic [31:0]  avm_address,
    output logic         avm_read,
    input  logic [255:0] avm_readdata,
    input  logic         avm_readdatavalid,
    output logic         avm_write,
    output logic [255:0] avm_writedata,
    output logic [31:0]  avm_byteenable,
    input  logic         avm_waitrequest
);

// ── FSM states ──────────────────────────────────────────────────────────
typedef enum logic [3:0] {
    S_IDLE,
    // Read path: 2 × 256-bit individual reads
    S_RD_LO_ISSUE,     // issue read for lower 256 bits
    S_RD_LO_WAIT,      // wait for readdatavalid
    S_RD_HI_ISSUE,     // issue read for upper 256 bits
    S_RD_HI_WAIT,      // wait for readdatavalid
    S_RD_DONE,         // deliver 512-bit result to L2
    // Write path: 2 × 256-bit individual writes
    S_WR_LO_ISSUE,     // issue write for lower 256 bits
    S_WR_LO_WAIT,      // wait for waitrequest deassert
    S_WR_HI_ISSUE,     // issue write for upper 256 bits
    S_WR_HI_WAIT,      // wait for waitrequest deassert
    S_WR_DONE          // signal completion to L2
} state_t;

state_t state, state_next;

// ── Latched request info ────────────────────────────────────────────────
logic [23:0]  req_block_addr;   // block address for current operation
logic [511:0] req_wr_data;      // latched write data
logic [255:0] rd_lo;            // captured lower 256 bits from read
logic [255:0] rd_hi;            // captured upper 256 bits from read

// ── Byte address computation ────────────────────────────────────────────
// block_addr = paddr[29:6] (24 bits).  Byte address = block_addr << 6.
// The DE10-Nano DDR3 address space starts at 0x2000_0000 (per trace README).
// Lower half:  base + (block_addr << 6) + 0
// Upper half:  base + (block_addr << 6) + 32
localparam logic [31:0] DDR3_BASE = 32'h2000_0000;

wire [31:0] line_byte_addr = DDR3_BASE + {2'b0, req_block_addr, 6'b0};
wire [31:0] addr_lo        = line_byte_addr;         // offset +0
wire [31:0] addr_hi        = line_byte_addr + 32'd32; // offset +32

// ── Avalon output defaults ──────────────────────────────────────────────
assign mem_busy = (state != S_IDLE);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        req_block_addr <= '0;
        req_wr_data    <= '0;
        rd_lo          <= '0;
        rd_hi          <= '0;
        mem_rd_valid   <= 1'b0;
        mem_rd_data    <= '0;
        mem_wr_done    <= 1'b0;
        avm_address    <= '0;
        avm_read       <= 1'b0;
        avm_write      <= 1'b0;
        avm_writedata  <= '0;
        avm_byteenable <= '0;
    end else begin
        // One-cycle pulses — clear by default
        mem_rd_valid <= 1'b0;
        mem_wr_done  <= 1'b0;

        case (state)
        // ─────────────────────────────────────────────────────────────
        S_IDLE: begin
            avm_read  <= 1'b0;
            avm_write <= 1'b0;
            if (mem_rd_req) begin
                req_block_addr <= mem_rd_addr;
                state          <= S_RD_LO_ISSUE;
            end else if (mem_wr_req) begin
                req_block_addr <= mem_wr_addr;
                req_wr_data    <= mem_wr_data;
                state          <= S_WR_LO_ISSUE;
            end
        end

        // ═══════════════════ READ PATH ═══════════════════════════════
        S_RD_LO_ISSUE: begin
            avm_address    <= addr_lo;
            avm_read       <= 1'b1;
            avm_write      <= 1'b0;
            avm_byteenable <= 32'hFFFF_FFFF;  // all 32 byte-enables
            state          <= S_RD_LO_WAIT;
        end

        S_RD_LO_WAIT: begin
            // Keep read asserted until accepted (waitrequest low)
            if (!avm_waitrequest) begin
                avm_read <= 1'b0;  // accepted — deassert read
            end
            if (avm_readdatavalid) begin
                rd_lo <= avm_readdata;
                state <= S_RD_HI_ISSUE;
            end
        end

        S_RD_HI_ISSUE: begin
            avm_address    <= addr_hi;
            avm_read       <= 1'b1;
            avm_write      <= 1'b0;
            avm_byteenable <= 32'hFFFF_FFFF;
            state          <= S_RD_HI_WAIT;
        end

        S_RD_HI_WAIT: begin
            if (!avm_waitrequest) begin
                avm_read <= 1'b0;
            end
            if (avm_readdatavalid) begin
                rd_hi <= avm_readdata;
                state <= S_RD_DONE;
            end
        end

        S_RD_DONE: begin
            mem_rd_valid <= 1'b1;
            mem_rd_data  <= {rd_hi, rd_lo};  // 512 bits: [511:256]=hi, [255:0]=lo
            avm_read     <= 1'b0;
            state        <= S_IDLE;
        end

        // ═══════════════════ WRITE PATH ══════════════════════════════
        S_WR_LO_ISSUE: begin
            avm_address    <= addr_lo;
            avm_write      <= 1'b1;
            avm_read       <= 1'b0;
            avm_writedata  <= req_wr_data[255:0];      // lower 256 bits
            avm_byteenable <= 32'hFFFF_FFFF;
            state          <= S_WR_LO_WAIT;
        end

        S_WR_LO_WAIT: begin
            if (!avm_waitrequest) begin
                avm_write <= 1'b0;  // accepted
                state     <= S_WR_HI_ISSUE;
            end
        end

        S_WR_HI_ISSUE: begin
            avm_address    <= addr_hi;
            avm_write      <= 1'b1;
            avm_read       <= 1'b0;
            avm_writedata  <= req_wr_data[511:256];    // upper 256 bits
            avm_byteenable <= 32'hFFFF_FFFF;
            state          <= S_WR_HI_WAIT;
        end

        S_WR_HI_WAIT: begin
            if (!avm_waitrequest) begin
                avm_write <= 1'b0;
                state     <= S_WR_DONE;
            end
        end

        S_WR_DONE: begin
            mem_wr_done <= 1'b1;
            state       <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
