/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off LATCH */
/* verilator lint_off MULTIDRIVEN */
`timescale 1ns/1ps

/*
 * fpga_mimic_tb.sv — Reproduce the exact PIO write sequence that
 * manual_test.c performs on the FPGA, using the same top_with_L1
 * hierarchy. This test checks whether loads get cache_ret_valid
 * after stores.
 */
module fpga_mimic_tb;
    logic clk = 0;
    logic rst_n = 0;

    always #10 clk = ~clk; // 50 MHz

    // PIO-like registers (mimic HPS writes)
    logic [63:0] adder_a, adder_b;
    wire [120:0] trace_line = {adder_b[56:0], adder_a[63:0]};

    // Observation signals
    logic obs_tlb_req, obs_cache_req, obs_cache_we;
    logic [29:0] obs_cache_paddr;
    logic [63:0] obs_cache_wdata;
    logic obs_cache_ret_valid;
    logic [63:0] obs_cache_ret_data;
    logic obs_l2_req_valid;
    logic [29:0] obs_l2_req_addr;
    logic obs_wb_valid;
    logic [29:0] obs_wb_addr;

    // Unused ext mem ports (sim uses internal backing store)
    logic         ext_mem_rd_req;
    logic [23:0]  ext_mem_rd_addr;
    logic         ext_mem_rd_valid = 0;
    logic [511:0] ext_mem_rd_data = '0;
    logic         ext_mem_wr_req;
    logic [23:0]  ext_mem_wr_addr;
    logic [511:0] ext_mem_wr_data;
    logic         ext_mem_wr_done = 0;
    logic         ext_mem_busy = 0;

    top_with_L1 #(
        .USE_REAL_L2(1'b1),
        .USE_AVALON(1'b0),
        .L2_SETS(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .trace_line(trace_line),
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
        .ext_mem_rd_req(ext_mem_rd_req),
        .ext_mem_rd_addr(ext_mem_rd_addr),
        .ext_mem_rd_valid(ext_mem_rd_valid),
        .ext_mem_rd_data(ext_mem_rd_data),
        .ext_mem_wr_req(ext_mem_wr_req),
        .ext_mem_wr_addr(ext_mem_wr_addr),
        .ext_mem_wr_data(ext_mem_wr_data),
        .ext_mem_wr_done(ext_mem_wr_done),
        .ext_mem_busy(ext_mem_busy)
    );

    // Sticky status register (mirrors GHRD)
    logic [63:0] status_sticky;
    wire clear_status_sig = (adder_b[63:57] == 7'b1111111);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_sticky <= 64'h0;
        end else if (clear_status_sig) begin
            status_sticky <= 64'h0;
        end else begin
            if (obs_cache_ret_valid) begin
                status_sticky[63]   <= 1'b1;
                status_sticky[29:0] <= obs_cache_ret_data[29:0];
            end
            if (obs_l2_req_valid)
                status_sticky[62] <= 1'b1;
            if (obs_wb_valid) begin
                status_sticky[61]    <= 1'b1;
                status_sticky[56:30] <= obs_wb_addr[26:0];
            end
        end
    end

    // ── Helper tasks that mimic HPS PIO writes ──────────────────────────
    task automatic pio_write_a(input logic [63:0] val);
        @(posedge clk);
        adder_a <= val;
        // Wait a few cycles to mimic AXI latency
        repeat(3) @(posedge clk);
    endtask

    task automatic pio_write_b(input logic [63:0] val);
        @(posedge clk);
        adder_b <= val;
        repeat(3) @(posedge clk);
    endtask

    task automatic send_trace_pio(input logic [63:0] a, input logic [63:0] b);
        // Same as manual_test: write B first, then A
        pio_write_b(b);
        pio_write_a(a);
    endtask

    task automatic clear_status_pio();
        // Exact sequence from manual_test.c clear_status():
        //   *reg_a = 0
        //   *reg_b = 0xFFFFFFFFFFFFFFFE
        //   *reg_b = 0
        pio_write_a(64'h0);
        pio_write_b(64'hFFFFFFFFFFFFFFFE);
        pio_write_b(64'h0);
    endtask

    function automatic void build_trace_fn(
        input logic [2:0] op, input logic [3:0] id, input logic [47:0] vaddr,
        input logic vv, input logic [63:0] value, input logic val_v,
        output logic [63:0] a, output logic [63:0] b
    );
        a = 0; b = 0;
        a = a | (vaddr & 48'hFFFFFFFFFFFF);
        a = a | ({60'b0, id} << 48);
        a = a | ({61'b0, op} << 52);
        a = a | ({63'b0, vv} << 55);
        a = a | ((value & 64'hFF) << 56);
        b = (value >> 8) & 64'h00FFFFFFFFFFFFFF;
        b = b | ({63'b0, val_v} << 56);
    endfunction

    // ── Main test sequence ──────────────────────────────────────────────
    logic [63:0] a, b;
    int load_got_ret;
    int test_pass = 0, test_fail = 0;

    // Cycle-by-cycle monitor (uncomment for debugging)
    // int cycle_cnt = 0;
    // always @(posedge clk) begin
    //     cycle_cnt <= cycle_cnt + 1;
    //     if (rst_n) begin
    //         if (obs_tlb_req || obs_cache_req || obs_cache_ret_valid ||
    //             dut.dut_lsq.tlb_fill || dut.dut_lsq.tlb_pending ||
    //             dut.dut_lsq.cache_pending ||
    //             (dut.dut_lsq.trace_id != dut.dut_lsq.trace_id_prev)) begin
    //             $display("  [cyc %0d] trace_id=%0d trace_op=%0d vv=%0b vaddr=%0h | tlb_fill=%0b tlb_req=%0b tlb_hit=%0b tlb_pending=%0b | cache_req=%0b cache_we=%0b cache_ret=%0b cache_pending=%0b | id_prev=%0d lh=%0d lt=%0d sh=%0d st=%0d",
    //                 cycle_cnt,
    //                 dut.dut_lsq.trace_id,
    //                 dut.dut_lsq.trace_op,
    //                 dut.dut_lsq.trace_vaddr_is_valid,
    //                 dut.dut_lsq.trace_vaddr,
    //                 dut.dut_lsq.tlb_fill,
    //                 obs_tlb_req,
    //                 dut.dut_lsq.tlb_hit,
    //                 dut.dut_lsq.tlb_pending,
    //                 obs_cache_req,
    //                 obs_cache_we,
    //                 obs_cache_ret_valid,
    //                 dut.dut_lsq.cache_pending,
    //                 dut.dut_lsq.trace_id_prev,
    //                 dut.dut_lsq.load_head,
    //                 dut.dut_lsq.load_tail,
    //                 dut.dut_lsq.store_head,
    //                 dut.dut_lsq.store_tail);
    //         end
    //     end
    // end

    initial begin
        adder_a = 64'h0;
        adder_b = 64'h0;

        // Reset
        rst_n = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("\n=== FPGA Mimic Test: Store then Load ===\n");

        // ─── Step 1: TLB fill page 0x001000 → paddr 0x00001000 ──────────
        // manual_test uses id=0 for TLB fills
        $display("[Step 1] TLB fill: vaddr_page=0x001000, paddr=0x00001000");
        build_trace_fn(3'd4, 4'd0, 48'h001000, 1'b1, 64'h00001000, 1'b0, a, b);
        send_trace_pio(a, b);
        repeat(20) @(posedge clk);

        // ─── Step 2: STORE id=1, vaddr=0x1008, data=0xCAFEBABE ──────────
        $display("[Step 2] clear_status then STORE");
        clear_status_pio();
        build_trace_fn(3'd1, 4'd1, 48'h001008, 1'b1, 64'hCAFEBABE, 1'b1, a, b);
        send_trace_pio(a, b);
        
        // Wait for store to complete (drain time for MSHR → L2 → response)
        repeat(200) @(posedge clk);
        
        $display("  Status after STORE: sticky=0x%016h  cache_ret=%0d",
                 status_sticky, status_sticky[63]);
        if (status_sticky[63])
            $display("  STORE → cache_ret_valid seen ✓");
        else
            $display("  STORE → cache_ret_valid NOT seen ✗");

        // ─── Step 3: LOAD id=2, vaddr=0x1008 ────────────────────────────
        $display("[Step 3] clear_status then LOAD");
        clear_status_pio();
        build_trace_fn(3'd0, 4'd2, 48'h001008, 1'b1, 64'h0, 1'b0, a, b);
        send_trace_pio(a, b);
        
        // Wait for load to complete
        load_got_ret = 0;
        for (int i = 0; i < 500; i++) begin
            @(posedge clk);
            if (status_sticky[63]) begin
                load_got_ret = 1;
                break;
            end
        end

        if (load_got_ret) begin
            $display("  LOAD → cache_ret_valid seen ✓  ret_data=0x%08h",
                     status_sticky[29:0]);
            test_pass++;
        end else begin
            $display("  LOAD → TIMEOUT (no cache_ret_valid) ✗");
            $display("  status_sticky = 0x%016h", status_sticky);
            test_fail++;
        end

        // ─── Step 4: Another STORE id=3, LOAD id=4 same addr ────────────
        $display("\n[Step 4] STORE id=3, vaddr=0x1010, data=0x12345678");
        clear_status_pio();
        build_trace_fn(3'd1, 4'd3, 48'h001010, 1'b1, 64'h12345678, 1'b1, a, b);
        send_trace_pio(a, b);
        repeat(200) @(posedge clk);
        
        $display("[Step 5] LOAD id=4, vaddr=0x1010");
        clear_status_pio();
        build_trace_fn(3'd0, 4'd4, 48'h001010, 1'b1, 64'h0, 1'b0, a, b);
        send_trace_pio(a, b);
        
        load_got_ret = 0;
        for (int i = 0; i < 500; i++) begin
            @(posedge clk);
            if (status_sticky[63]) begin
                load_got_ret = 1;
                break;
            end
        end

        if (load_got_ret) begin
            $display("  LOAD → cache_ret_valid seen ✓  ret_data=0x%08h",
                     status_sticky[29:0]);
            test_pass++;
        end else begin
            $display("  LOAD → TIMEOUT (no cache_ret_valid) ✗");
            test_fail++;
        end

        // ─── Summary ────────────────────────────────────────────────────
        $display("\n=== Results: PASS=%0d  FAIL=%0d ===", test_pass, test_fail);
        if (test_fail > 0)
            $display(">>> FPGA LOAD BUG REPRODUCED <<<");
        else
            $display(">>> ALL TESTS PASSED <<<");

        $finish;
    end

endmodule
