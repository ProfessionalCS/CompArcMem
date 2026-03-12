/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */

/* verilator lint_off UNDRIVEN */

`timescale 1ns/1ps

import cacheDataTypes::*;

module top (
    input logic clk,
    input logic rst_n,
    input logic [120:0] trace_line
);
    // -----------------------------------------------------------------------
    // IO for TLB
    // -----------------------------------------------------------------------
    logic tlb_req;

    logic tlb_hit;
    logic [PADDR_WIDTH-1:0] tlb_paddr;
    logic [VADDR_WIDTH-1:0] tlb_vaddr;
    logic tlb_fill;
    logic [VADDR_WIDTH-1:0] fill_vaddr;
    logic [PADDR_WIDTH-1:0] fill_paddr;

    // -----------------------------------------------------------------------
    // IO for the caches
    // -----------------------------------------------------------------------
    logic cache_ready;
    logic cache_ret_valid;
    logic [BLOCK_SIZE-1:0] cache_ret_data;

    // -----------------------------------------------------------------------
    // IO for the cache-memory
    // -----------------------------------------------------------------------
    logic memReadRespValid;
    logic memReadRespReady;
    logic [BLOCK_SIZE-1:0] memData;
    logic [PADDR_WIDTH-1:0] memAddr;
    logic memWriteReqValid;

    // -----------------------------------------------------------------------
    // Instantiated modules
    // -----------------------------------------------------------------------
    lsq #(.N(16)) dut_lsq (
        .clk              (clk),
        .rst_n            (rst_n),
        .trace_line       (trace_line),
        .tlb_hit          (tlb_hit),
        .tlb_paddr        (tlb_paddr),
        .tlb_req          (tlb_req),
        .tlb_vaddr        (tlb_vaddr),
        .tlb_fill         (tlb_fill),
        .fill_tlb_paddr   (fill_paddr),
        .fill_tlb_vaddr   (fill_vaddr),
        .cache_ready      (cache_ready),
        .cache_ret_valid  (cache_ret_valid),
        .cache_ret_data   (cache_ret_data),
        .cache_req        (),
        .cache_we         (),
        .cache_paddr      (),
        .cache_wdata      ()
    );

    dtlb dut_tlb (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_req_i   (tlb_req),
        .lookup_vaddr_i (tlb_vaddr),
        .lookup_hit_o   (tlb_hit),
        .lookup_paddr_o (tlb_paddr),
        .fill_req_i     (tlb_fill),
        .fill_vaddr_i   (fill_vaddr),
        .fill_paddr_i   (fill_paddr)
    );


    // L1 goes here:
    // ....


    llcd dutLLCD(
      .clk(clk),
      .rstN(rst_n),
      .l1ReqValid(),
      .l1ReqWrite(),
      .l1Addr(),
      .l1DataIn(),
      .l1DataOut(),
      .l1RespValid(),
      .memReadRespValid(memReadRespValid),
      .memReadRespReady(memReadRespReady),
      .memData(memData),
      .memAddr(memAddr),
      .memWriteReqValid(memWriteReqValid)
    );

endmodule
