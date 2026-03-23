/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */

`timescale 1ns/1ps

module top_with_L1_tb #(
    parameter bit USE_REAL_L2 = 1'b0
);
    localparam logic [2:0] OP_MEM_LOAD    = 3'd0;
    localparam logic [2:0] OP_MEM_STORE   = 3'd1;
    localparam logic [2:0] OP_MEM_RESOLVE = 3'd2;
    localparam logic [2:0] OP_TLB_FILL    = 3'd4;

    logic clk;
    logic rst_n;
    logic [120:0] trace_line;
    logic obs_tlb_req;
    logic obs_cache_req;
    logic obs_cache_we;
    logic [29:0] obs_cache_paddr;
    logic [63:0] obs_cache_wdata;
    logic obs_cache_ret_valid;
    logic [63:0] obs_cache_ret_data;
    logic obs_l2_req_valid;
    logic [29:0] obs_l2_req_addr;
    logic obs_wb_valid;
    logic [29:0] obs_wb_addr;

    int pass_count;
    int fail_count;

    logic trace_mode;
    byte buffer [0:15];
    logic [127:0] raw_record;
    logic [2:0] trace_op;
    int fd;
    string trace_file;
    int max_records;
    int drain_cycles;
    int trace_gap_cycles;
    int rec_count;
    int load_count;
    int store_count;
    int resolve_count;
    int fill_count;
    int cache_resp_count;
    int cache_req_count;
    int cache_store_count;
    int tlb_req_count;
    int l2_req_count;
    int wb_count;

    top_with_L1 #(
        .USE_REAL_L2(USE_REAL_L2)
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
        .obs_wb_addr(obs_wb_addr)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n && trace_mode) begin
            if (obs_tlb_req)
                tlb_req_count <= tlb_req_count + 1;
            if (obs_cache_req)
                cache_req_count <= cache_req_count + 1;
            if (obs_cache_req && obs_cache_we)
                cache_store_count <= cache_store_count + 1;
            if (obs_cache_ret_valid)
                cache_resp_count <= cache_resp_count + 1;
            if (obs_l2_req_valid)
                l2_req_count <= l2_req_count + 1;
            if (obs_wb_valid)
                wb_count <= wb_count + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Trace constructors (same layout used by lsq.sv)
    // -------------------------------------------------------------------------
    function automatic logic [120:0] make_trace (
        input logic [2:0]  op_val,
        input logic [3:0]  tid,
        input logic [47:0] vaddr,
        input logic        va_valid,
        input logic [63:0] val,
        input logic        vv,
        input logic [29:0] paddr
    );
        logic [120:0] t;
        begin
            t = '0;
            t[47:0]   = vaddr;
            t[51:48]  = tid;
            t[54:52]  = op_val;
            t[55]     = va_valid;
            t[120]    = vv;
            t[119:56] = val;
            if (paddr != '0) t[85:56] = paddr;
            return t;
        end
    endfunction

    function automatic logic [120:0] fill_trace (input logic [47:0] va,
                                                 input logic [29:0] pa);
        return make_trace(3'd4, 4'h0, va, 1'b0, '0, 1'b0, pa);
    endfunction

    function automatic logic [120:0] load_trace (input logic [3:0] tid,
                                                 input logic [47:0] va);
        return make_trace(3'd0, tid, va, 1'b1, '0, 1'b0, '0);
    endfunction

    function automatic logic [120:0] store_trace (input logic [3:0] tid,
                                                  input logic [47:0] va,
                                                  input logic [63:0] data);
        return make_trace(3'd1, tid, va, 1'b1, data, 1'b1, '0);
    endfunction

    task automatic decode_record;
        begin
            for (int i = 0; i < 16; i++)
                raw_record[i*8 +: 8] = buffer[i];
            trace_op = raw_record[54:52];
        end
    endtask

    // -------------------------------------------------------------------------
    // Drive helpers
    // -------------------------------------------------------------------------
    task automatic do_reset();
        begin
            @(negedge clk);
            rst_n = 1'b0;
            trace_line = '0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    task automatic drive_fill(input logic [47:0] va, input logic [29:0] pa);
        begin
            @(negedge clk);
            trace_line = fill_trace(va, pa);
            @(posedge clk); #1;
            @(negedge clk);
            trace_line = '0;
            @(posedge clk); #1;
        end
    endtask

    task automatic drive_trace_idle(input logic [120:0] tl);
        begin
            @(negedge clk);
            trace_line = tl;
            // Keep trace stable long enough for LSQ->dTLB lookup pipeline.
            repeat (3) @(posedge clk);
            #1;
            @(negedge clk);
            trace_line = '0;
            @(posedge clk); #1;
        end
    endtask

    task automatic wait_for_load_resp(
        input string name,
        input logic expect_resp,
        input logic [63:0] exp_data,
        input int timeout_cycles
    );
        int i;
        logic seen;
        begin
            seen = 1'b0;
            for (i = 0; i < timeout_cycles; i++) begin
                @(posedge clk);
                #1;
                if (obs_cache_ret_valid) begin
                    seen = 1'b1;
                    if (expect_resp) begin
                        if (obs_cache_ret_data === exp_data) begin
                            $display("PASS [%s] data=%h", name, obs_cache_ret_data);
                            pass_count++;
                        end else begin
                            $display("FAIL [%s] got=%h exp=%h", name, obs_cache_ret_data, exp_data);
                            fail_count++;
                        end
                    end else begin
                        $display("FAIL [%s] unexpected response data=%h", name, obs_cache_ret_data);
                        fail_count++;
                    end
                    i = timeout_cycles;
                end
            end

            if (!seen) begin
                if (expect_resp) begin
                    $display("FAIL [%s] no response in %0d cycles", name, timeout_cycles);
                    fail_count++;
                end else begin
                    $display("PASS [%s] no response (expected)", name);
                    pass_count++;
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    initial begin : run_main
        logic [47:0] va1, va2, va3;
        logic [29:0] pa1, pa3;
        logic [63:0] d1, d2;

        $timeformat(-9, 0, " ns", 8);
        $dumpfile("top_with_L1_tb.vcd");
        $dumpvars(0, top_with_L1_tb);

        pass_count = 0;
        fail_count = 0;
        rst_n = 1'b0;
        trace_line = '0;
        trace_mode = 1'b0;

        rec_count = 0;
        load_count = 0;
        store_count = 0;
        resolve_count = 0;
        fill_count = 0;
        cache_resp_count = 0;
        cache_req_count = 0;
        cache_store_count = 0;
        tlb_req_count = 0;
        l2_req_count = 0;
        wb_count = 0;

        do_reset();

        if ($value$plusargs("TRACE_FILE=%s", trace_file)) begin
            trace_mode = 1'b1;
            if (!$value$plusargs("MAX_REC=%d", max_records))
                max_records = 2000;
            if (!$value$plusargs("DRAIN_CYCLES=%d", drain_cycles))
                drain_cycles = 4000;
            if (!$value$plusargs("TRACE_GAP_CYCLES=%d", trace_gap_cycles))
                trace_gap_cycles = 3;

            fd = $fopen(trace_file, "rb");
            if (fd == 0) begin
                $display("ERROR: could not open trace file %s", trace_file);
                $finish;
            end

            $display("Running top_with_L1_tb trace replay with TRACE_FILE=%s MAX_REC=%0d", trace_file, max_records);

            while (($fread(buffer, fd) == 16) && ((max_records == 0) || (rec_count < max_records))) begin
                rec_count++;
                decode_record();

                case (trace_op)
                    OP_MEM_LOAD:    load_count++;
                    OP_MEM_STORE:   store_count++;
                    OP_MEM_RESOLVE: resolve_count++;
                    OP_TLB_FILL:    fill_count++;
                    default: begin end
                endcase

                @(negedge clk);
                trace_line = raw_record[120:0];
                @(posedge clk);
                #1;
                repeat (trace_gap_cycles) @(posedge clk);

                if ((rec_count % 1000) == 0)
                    $display("Progress: processed %0d records", rec_count);
            end

            $fclose(fd);

            @(negedge clk);
            trace_line = '0;
            repeat (drain_cycles) @(posedge clk);

            $display("\n============= top_with_L1_tb trace summary =============");
            $display("records processed         : %0d", rec_count);
            $display("loads seen                : %0d", load_count);
            $display("stores seen               : %0d", store_count);
            $display("resolves seen             : %0d", resolve_count);
            $display("tlb fills seen            : %0d", fill_count);
            $display("tlb requests issued       : %0d", tlb_req_count);
            $display("cache requests issued     : %0d", cache_req_count);
            $display("cache stores issued       : %0d", cache_store_count);
            $display("cache responses observed  : %0d", cache_resp_count);
            $display("l2 requests observed      : %0d", l2_req_count);
            $display("writebacks observed       : %0d", wb_count);
            $display("=========================================================");
            $finish;
            disable run_main;
        end

        va1 = 48'h0000_0000_1000;
        va2 = 48'h0000_0000_1030;
        va3 = 48'h0000_0000_2000;
        pa1 = 30'h0000_1400;
        pa3 = 30'h0000_2400;
        d1  = 64'hA1A1_A1A1_1111_2222;
        d2  = 64'hB2B2_B2B2_3333_4444;

        // TC1: fill TLB, store then load same address.
        $display("\nTC1: store then load same address");
        drive_fill(va1, pa1);
        drive_trace_idle(store_trace(4'h1, va1, d1));
        repeat (30) @(posedge clk);
        drive_trace_idle(load_trace(4'h2, va1));
        wait_for_load_resp("TC1", 1'b1, d1, 120);

        // TC2: store then load different offset in same cache line.
        $display("\nTC2: store then load different offset in same line");
        drive_trace_idle(store_trace(4'h3, va2, d2));
        repeat (30) @(posedge clk);
        drive_trace_idle(load_trace(4'h4, va2));
        wait_for_load_resp("TC2", 1'b1, d2, 120);

        // TC3: cold load miss should now return refill data (dummy_L2 -> zeros).
        $display("\nTC3: cold load miss returns refill data");
        drive_fill(va3, pa3);
        drive_trace_idle(load_trace(4'h5, va3));
        wait_for_load_resp("TC3", 1'b1, 64'h0, 120);

        // TC4: re-load old written address should still read the last stored value.
        $display("\nTC4: re-load previous address");
        drive_trace_idle(load_trace(4'h6, va1));
        wait_for_load_resp("TC4", 1'b1, d1, 120);

        $display("\n========================================");
        $display("top_with_L1_tb: PASS=%0d FAIL=%0d", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else $display("SOME TESTS FAILED");
        $display("========================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT: top_with_L1_tb exceeded 5 ms");
        $finish;
    end

endmodule
