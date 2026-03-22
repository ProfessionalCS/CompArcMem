module DE10_NANO_SoC_GHRD(

    //////////// CLOCK //////////
    input               FPGA_CLK1_50,
    input               FPGA_CLK2_50,
    input               FPGA_CLK3_50,

    //////////// HPS //////////
    output   [14: 0]    HPS_DDR3_ADDR,
    output   [ 2: 0]    HPS_DDR3_BA,
    output              HPS_DDR3_CAS_N,
    output              HPS_DDR3_CK_N,
    output              HPS_DDR3_CK_P,
    output              HPS_DDR3_CKE,
    output              HPS_DDR3_CS_N,
    output   [ 3: 0]    HPS_DDR3_DM,
    inout    [31: 0]    HPS_DDR3_DQ,
    inout    [ 3: 0]    HPS_DDR3_DQS_N,
    inout    [ 3: 0]    HPS_DDR3_DQS_P,
    output              HPS_DDR3_ODT,
    output              HPS_DDR3_RAS_N,
    output              HPS_DDR3_RESET_N,
    input               HPS_DDR3_RZQ,
    output              HPS_DDR3_WE_N,

    //////////// LED //////////
    output   [ 7: 0]    LED
);
//=======================================================
//  REG/WIRE declarations
//=======================================================
wire hps_fpga_reset_n;
wire fpga_clk_50;

assign fpga_clk_50 = FPGA_CLK1_50;

// ── PIO wires (reused from existing soc_system — 64-bit adder conduits) ──
wire [63:0] adder_a_export;    // soc_system → FPGA (HPS writes here)
wire [63:0] adder_b_export;    // soc_system → FPGA (HPS writes here)
wire [63:0] adder_sum_export;  // FPGA → soc_system (HPS reads here)

//=======================================================
//  Memory Subsystem
//=======================================================

// ── Trace input (driven from HPS via PIOs) ──────────────────────────────
// adder_a_export[63:0]  = trace_line[63:0]
// adder_b_export[56:0]  = trace_line[120:64]
// adder_b_export[57]    = trace_valid pulse (active high, 1 cycle)
wire [120:0] trace_line = {adder_b_export[56:0], adder_a_export[63:0]};
wire         trace_valid_pulse = adder_b_export[57];

// ── Observation signals (memory subsystem → HPS for status/debug) ───────
wire obs_tlb_req, obs_cache_req, obs_cache_we;
wire [29:0] obs_cache_paddr;
wire [63:0] obs_cache_wdata;
wire obs_cache_ret_valid;
wire [63:0] obs_cache_ret_data;
wire obs_l2_req_valid;
wire [29:0] obs_l2_req_addr;
wire obs_wb_valid;
wire [29:0] obs_wb_addr;

// Pack status into adder_sum_export for HPS to read
assign adder_sum_export = {
    2'b0,
    obs_wb_valid,              // bit 61
    obs_l2_req_valid,          // bit 60
    obs_wb_addr,               // bits 59:30
    obs_cache_ret_data[29:0]   // bits 29:0  (lower 30 bits of returned data)
};

// ── L2 ↔ Avalon memory master wires ─────────────────────────────────────
wire         l2_ext_rd_req;
wire [23:0]  l2_ext_rd_addr;
wire         l2_ext_rd_valid;
wire [511:0] l2_ext_rd_data;
wire         l2_ext_wr_req;
wire [23:0]  l2_ext_wr_addr;
wire [511:0] l2_ext_wr_data;
wire         l2_ext_wr_done;
wire         l2_ext_busy;

// ── Avalon-MM master wires (64-bit, connected to fpga_mem on soc_system) ─
wire [31:0]  avm_address;
wire         avm_read;
wire [63:0]  avm_readdata;
wire         avm_readdatavalid;
wire         avm_write;
wire [63:0]  avm_writedata;
wire [7:0]   avm_byteenable;
wire         avm_waitrequest;

// ── Instantiate the memory hierarchy ────────────────────────────────────
top_with_L1 #(
    .USE_REAL_L2(1'b1),
    .USE_AVALON(1'b1)
) mem_subsystem (
    .clk(fpga_clk_50),
    .rst_n(hps_fpga_reset_n),
    .trace_line(trace_line),
    // Observation ports
    .obs_tlb_req(obs_tlb_req),
    .obs_cache_req(obs_cache_req),
    .obs_cache_we(obs_cache_we),
    .obs_cache_paddr(obs_cache_paddr),
    .obs_cache_wdata(obs_cache_wdata),
    .obs_cache_ret_valid(obs_cache_ret_valid),
    .obs_cache_ret_data(obs_cache_ret_data),
    .obs_l2_req_valid(obs_l2_req_valid),
    .obs_l2_req_addr(obs_l2_req_addr),
    .obs_wb_valid(obs_wb_valid),
    .obs_wb_addr(obs_wb_addr),
    // External memory (Avalon path)
    .ext_mem_rd_req(l2_ext_rd_req),
    .ext_mem_rd_addr(l2_ext_rd_addr),
    .ext_mem_rd_valid(l2_ext_rd_valid),
    .ext_mem_rd_data(l2_ext_rd_data),
    .ext_mem_wr_req(l2_ext_wr_req),
    .ext_mem_wr_addr(l2_ext_wr_addr),
    .ext_mem_wr_data(l2_ext_wr_data),
    .ext_mem_wr_done(l2_ext_wr_done),
    .ext_mem_busy(l2_ext_busy)
);

// ── Avalon-MM master (bridges L2 512b requests to 256b DDR3 accesses) ───
avalon_mem_master avm_master (
    .clk(fpga_clk_50),
    .rst_n(hps_fpga_reset_n),
    // L2 read-miss
    .mem_rd_req(l2_ext_rd_req),
    .mem_rd_addr(l2_ext_rd_addr),
    .mem_rd_valid(l2_ext_rd_valid),
    .mem_rd_data(l2_ext_rd_data),
    // L2 dirty eviction
    .mem_wr_req(l2_ext_wr_req),
    .mem_wr_addr(l2_ext_wr_addr),
    .mem_wr_data(l2_ext_wr_data),
    .mem_wr_done(l2_ext_wr_done),
    // Busy
    .mem_busy(l2_ext_busy),
    // Avalon-MM master
    .avm_address(avm_address),
    .avm_read(avm_read),
    .avm_readdata(avm_readdata),
    .avm_readdatavalid(avm_readdatavalid),
    .avm_write(avm_write),
    .avm_writedata(avm_writedata),
    .avm_byteenable(avm_byteenable),
    .avm_waitrequest(avm_waitrequest)
);

//=======================================================
//  Structural coding — soc_system (Platform Designer)
//=======================================================
soc_system u0(
               // PIO conduits (reused for trace input / status output)
               .adder_a_export(adder_a_export),
               .adder_b_export(adder_b_export),
               .adder_sum_export(adder_sum_export),
               //Clock&Reset
               .clk_clk(FPGA_CLK1_50),
               .reset_reset_n(hps_fpga_reset_n),
               //HPS ddr3
               .memory_mem_a(HPS_DDR3_ADDR),
               .memory_mem_ba(HPS_DDR3_BA),
               .memory_mem_ck(HPS_DDR3_CK_P),
               .memory_mem_ck_n(HPS_DDR3_CK_N),
               .memory_mem_cke(HPS_DDR3_CKE),
               .memory_mem_cs_n(HPS_DDR3_CS_N),
               .memory_mem_ras_n(HPS_DDR3_RAS_N),
               .memory_mem_cas_n(HPS_DDR3_CAS_N),
               .memory_mem_we_n(HPS_DDR3_WE_N),
               .memory_mem_reset_n(HPS_DDR3_RESET_N),
               .memory_mem_dq(HPS_DDR3_DQ),
               .memory_mem_dqs(HPS_DDR3_DQS_P),
               .memory_mem_dqs_n(HPS_DDR3_DQS_N),
               .memory_mem_odt(HPS_DDR3_ODT),
               .memory_mem_dm(HPS_DDR3_DM),
               .memory_oct_rzqin(HPS_DDR3_RZQ),
               .hps_0_h2f_reset_reset_n(hps_fpga_reset_n),
               // FPGA → DDR3 Avalon-MM path (via fpga_mem_bridge in soc_system)
               .fpga_mem_address(avm_address),
               .fpga_mem_read(avm_read),
               .fpga_mem_readdata(avm_readdata),
               .fpga_mem_readdatavalid(avm_readdatavalid),
               .fpga_mem_write(avm_write),
               .fpga_mem_writedata(avm_writedata),
               .fpga_mem_byteenable(avm_byteenable),
               .fpga_mem_waitrequest(avm_waitrequest),
               .fpga_mem_burstcount(1'b1),
               .fpga_mem_debugaccess(1'b0)
           );

assign LED = {obs_cache_ret_valid, obs_l2_req_valid, obs_wb_valid,
              obs_cache_we, obs_cache_req, obs_tlb_req, 2'b0};

endmodule