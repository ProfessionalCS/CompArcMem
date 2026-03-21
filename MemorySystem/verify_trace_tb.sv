/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off VARHIDDEN */

`timescale 1ns/1ps

// ════════════════════════════════════════════════════════════════════════════
// verify_trace_tb — Trace replay with store-value verification
//
//   Phase 1: Replay a binary trace file (mem-traces-v2 format)
//            ▸ Track every STORE's vaddr + value in a shadow memory table
//            ▸ Track the TLB fill mapping (vaddr page → paddr page)
//   Phase 2: After drain, re-issue TLB fills + loads for every stored address
//            ▸ Compare cache response to expected value from shadow memory
//            ▸ Report PASS/FAIL per address and a final summary
//
//   Uses v2 trace format: bit[55] = vaddr_is_valid, bit[120] = value_is_valid
//
//   Usage (compile then run):
//     $> vlator -Wall --binary --timing -j 0 -Wno-fatal -GUSE_REAL_L2=1
//        --top-module verify_trace_tb
//        ./verify_trace_tb.sv ./top_with_L1.sv ./lsq.sv ./dtlb.sv
//        ./L1_Cache.sv ./L2_copy.sv ./cacheDataTypes.sv
//
//     $> ./obj_dir/Vverify_trace_tb
//        "+TRACE_FILE=mem-traces-v2/traces/dgemm3_lsq88.bin"
//        "+MAX_REC=500" "+DRAIN_CYCLES=6000" "+TRACE_GAP_CYCLES=3"
// ════════════════════════════════════════════════════════════════════════════

module verify_trace_tb #(
    parameter bit USE_REAL_L2 = 1'b0
);
    // ── Op codes (localparam to avoid VARHIDDEN with lsq.sv enum) ───────
    localparam logic [2:0] OP_MEM_LOAD    = 3'd0;
    localparam logic [2:0] OP_MEM_STORE   = 3'd1;
    localparam logic [2:0] OP_MEM_RESOLVE = 3'd2;
    localparam logic [2:0] OP_TLB_FILL    = 3'd4;

    // Idle trace line: OP_TLB_FILL op, everything else 0.
    // Prevents the LSQ from enqueuing a spurious OP_MEM_LOAD to addr 0
    // when we want to "clear" the trace line.
    localparam logic [120:0] IDLE_TRACE = {1'b0, 64'b0, 1'b0, 3'b100, 4'b0, 48'b0};

    // ── DUT signals ─────────────────────────────────────────────────────
    logic        clk;
    logic        rst_n;
    logic [120:0] trace_line;
    logic        obs_tlb_req;
    logic        obs_cache_req;
    logic        obs_cache_we;
    logic [29:0] obs_cache_paddr;
    logic [63:0] obs_cache_wdata;
    logic        obs_cache_ret_valid;
    logic [63:0] obs_cache_ret_data;
    logic        obs_l2_req_valid;
    logic [29:0] obs_l2_req_addr;
    logic        obs_wb_valid;
    logic [29:0] obs_wb_addr;

    // ── DUT instantiation ───────────────────────────────────────────────
    top_with_L1 #(.USE_REAL_L2(USE_REAL_L2)) dut (
        .clk(clk), .rst_n(rst_n), .trace_line(trace_line),
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

    // ── Clock ───────────────────────────────────────────────────────────
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ══════════════════════════════════════════════════════════════════════
    //  Shadow Memory — mirrors replay_trace.c's architectural state
    // ══════════════════════════════════════════════════════════════════════
    // Associative array keyed by 48-bit vaddr → 64-bit expected value
    logic [63:0] shadow_mem [logic [47:0]];

    // TLB shadow: vaddr page (48-bit, page-aligned) → paddr (30-bit)
    logic [29:0] tlb_shadow [logic [47:0]];

    // Store tracking for verification phase
    localparam int MAX_STORES = 1024;
    logic [47:0] store_vaddrs [0:MAX_STORES-1];
    logic [63:0] store_values [0:MAX_STORES-1];
    int          store_count;

    // ── Trace file I/O ──────────────────────────────────────────────────
    byte         buffer [0:15];
    logic [127:0] raw_record;
    logic [2:0]  trace_op;
    int          fd;
    string       trace_file;
    int          max_records;
    int          drain_cycles;
    int          trace_gap_cycles;

    // ── Counters ────────────────────────────────────────────────────────
    int rec_count;
    int load_count, store_seen_count, resolve_count, fill_count;
    int tlb_req_count, cache_req_count, cache_store_count;
    int cache_resp_count, l2_req_count, wb_count;

    // ── Verification counters ───────────────────────────────────────────
    int verify_pass, verify_fail, verify_timeout;
    int verify_total;

    // ── Activity monitor ────────────────────────────────────────────────
    always @(posedge clk) begin
        if (rst_n) begin
            if (obs_tlb_req)                     tlb_req_count   <= tlb_req_count + 1;
            if (obs_cache_req)                   cache_req_count <= cache_req_count + 1;
            if (obs_cache_req && obs_cache_we)   cache_store_count <= cache_store_count + 1;
            if (obs_cache_ret_valid)             cache_resp_count <= cache_resp_count + 1;
            if (obs_l2_req_valid)                l2_req_count    <= l2_req_count + 1;
            if (obs_wb_valid)                    wb_count        <= wb_count + 1;
        end
    end

    // ══════════════════════════════════════════════════════════════════════
    //  Trace-line constructors (v2 format)
    // ══════════════════════════════════════════════════════════════════════
    function automatic logic [120:0] make_trace(
        input logic [2:0]  op,
        input logic [3:0]  tid,
        input logic [47:0] vaddr,
        input logic        va_valid,
        input logic [63:0] val,
        input logic        vv,
        input logic [29:0] paddr
    );
        logic [120:0] t;
        t = '0;
        t[47:0]   = vaddr;
        t[51:48]  = tid;
        t[54:52]  = op;
        t[55]     = va_valid;
        t[120]    = vv;
        t[119:56] = val;
        if (paddr != '0) t[85:56] = paddr;
        return t;
    endfunction

    function automatic logic [120:0] fill_trace(input logic [47:0] va,
                                                input logic [29:0] pa);
        return make_trace(OP_TLB_FILL, 4'h0, va, 1'b1, '0, 1'b0, pa);
    endfunction

    function automatic logic [120:0] load_trace(input logic [3:0] tid,
                                                input logic [47:0] va);
        return make_trace(OP_MEM_LOAD, tid, va, 1'b1, '0, 1'b0, '0);
    endfunction

    function automatic logic [120:0] store_trace(input logic [3:0] tid,
                                                 input logic [47:0] va,
                                                 input logic [63:0] data);
        return make_trace(OP_MEM_STORE, tid, va, 1'b1, data, 1'b1, '0);
    endfunction

    // ── Decode raw record ───────────────────────────────────────────────
    task automatic decode_record;
        for (int i = 0; i < 16; i++)
            raw_record[i*8 +: 8] = buffer[i];
        trace_op = raw_record[54:52];
    endtask

    // ── Helpers ─────────────────────────────────────────────────────────
    task automatic do_reset();
        @(negedge clk);
        rst_n = 1'b0;
        trace_line = '0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;
    endtask

    // Drive a trace line and wait gap cycles
    task automatic drive_trace(input logic [120:0] tl, input int gap);
        @(negedge clk);
        trace_line = tl;
        @(posedge clk); #1;
        repeat (gap) @(posedge clk);
    endtask

    // Wait for a cache response with timeout, return data and whether it arrived
    task automatic wait_resp(
        input int timeout,
        output logic got_resp,
        output logic [63:0] rdata
    );
        got_resp = 1'b0;
        rdata = '0;
        for (int i = 0; i < timeout; i++) begin
            @(posedge clk); #1;
            if (obs_cache_ret_valid) begin
                got_resp = 1'b1;
                rdata = obs_cache_ret_data;
                return;
            end
        end
    endtask

    // ══════════════════════════════════════════════════════════════════════
    //  Main Test Sequence
    // ══════════════════════════════════════════════════════════════════════
    initial begin : run_main
        logic [47:0] s_vaddr;
        logic [63:0] s_value;
        logic [2:0]  s_op;
        logic        s_va_valid;
        logic        s_vv;
        logic [29:0] s_paddr;
        logic [47:0] s_page;

        logic        got_resp;
        logic [63:0] rdata;
        logic [47:0] verify_va;
        logic [63:0] verify_exp;
        logic [47:0] verify_page;
        logic [29:0] verify_pa;
        logic [3:0]  fill_tid, load_tid;

        $timeformat(-9, 0, " ns", 8);
        $dumpfile("verify_trace_tb.vcd");
        $dumpvars(0, verify_trace_tb);

        // Init everything
        rst_n = 1'b0;
        trace_line = '0;
        rec_count = 0;
        load_count = 0; store_seen_count = 0;
        resolve_count = 0; fill_count = 0;
        tlb_req_count = 0; cache_req_count = 0;
        cache_store_count = 0; cache_resp_count = 0;
        l2_req_count = 0; wb_count = 0;
        store_count = 0;
        verify_pass = 0; verify_fail = 0; verify_timeout = 0;

        do_reset();

        // ─── Parse plusargs ─────────────────────────────────────────────
        if (!$value$plusargs("TRACE_FILE=%s", trace_file)) begin
            $display("ERROR: +TRACE_FILE=<path> required");
            $finish;
        end
        if (!$value$plusargs("MAX_REC=%d", max_records))    max_records = 500;
        if (!$value$plusargs("DRAIN_CYCLES=%d", drain_cycles)) drain_cycles = 6000;
        if (!$value$plusargs("TRACE_GAP_CYCLES=%d", trace_gap_cycles)) trace_gap_cycles = 3;

        fd = $fopen(trace_file, "rb");
        if (fd == 0) begin
            $display("ERROR: could not open %s", trace_file);
            $finish;
        end

        $display("════════════════════════════════════════════════════════════");
        $display(" verify_trace_tb — Phase 1: Trace Replay");
        $display("   FILE=%s  MAX_REC=%0d", trace_file, max_records);
        $display("════════════════════════════════════════════════════════════");

        // ═════════════════════════════════════════════════════════════════
        //  PHASE 1: Replay trace, build shadow memory
        // ═════════════════════════════════════════════════════════════════
        while (($fread(buffer, fd) == 16) && ((max_records == 0) || (rec_count < max_records))) begin
            rec_count++;
            decode_record();

            s_op       = raw_record[54:52];
            s_vaddr    = raw_record[47:0];
            s_va_valid = raw_record[55];
            s_vv       = raw_record[120];
            s_value    = raw_record[119:56];
            s_paddr    = raw_record[85:56];

            case (s_op)
                OP_TLB_FILL: begin
                    fill_count++;
                    // Record page mapping: vaddr page → paddr
                    s_page = {s_vaddr[47:12], 12'b0};
                    tlb_shadow[s_page] = s_paddr;
                end
                OP_MEM_LOAD: begin
                    load_count++;
                end
                OP_MEM_STORE: begin
                    store_seen_count++;
                    // Track in shadow memory (matching replay_trace.c behavior):
                    // Only stores with both vaddr_valid and value_valid commit
                    if (s_va_valid && s_vv) begin
                        // Update or insert into shadow memory
                        if (!shadow_mem.exists(s_vaddr)) begin
                            // New address — add to ordered list for verification
                            if (store_count < MAX_STORES) begin
                                store_vaddrs[store_count] = s_vaddr;
                                store_count++;
                            end
                        end
                        shadow_mem[s_vaddr] = s_value;
                    end
                end
                OP_MEM_RESOLVE: begin
                    resolve_count++;
                end
                default: begin end
            endcase

            // Drive the trace line into the DUT
            @(negedge clk);
            trace_line = raw_record[120:0];
            @(posedge clk); #1;
            repeat (trace_gap_cycles) @(posedge clk);

            if ((rec_count % 500) == 0)
                $display("  Phase 1 progress: %0d records", rec_count);
        end

        $fclose(fd);

        $display("  Phase 1 complete: %0d records replayed", rec_count);
        $display("    loads=%0d  stores=%0d  resolves=%0d  fills=%0d",
                 load_count, store_seen_count, resolve_count, fill_count);
        $display("    unique store addresses tracked: %0d", store_count);

        // ── Drain: let all in-flight ops settle ─────────────────────────
        @(negedge clk);
        trace_line = IDLE_TRACE;
        $display("  Draining for %0d cycles...", drain_cycles);
        repeat (drain_cycles) @(posedge clk);

        // ═════════════════════════════════════════════════════════════════
        //  PHASE 2: Verify stored values are still present
        //    For each stored vaddr:
        //      1. Re-issue TLB fill (using shadow TLB mapping)
        //      2. Issue a LOAD to that vaddr
        //      3. Wait for cache response and compare with shadow value
        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("════════════════════════════════════════════════════════════");
        $display(" verify_trace_tb — Phase 2: Store Verification");
        $display("   Checking %0d stored addresses...", store_count);
        $display("════════════════════════════════════════════════════════════");

        verify_total = store_count;

        for (int s = 0; s < store_count; s++) begin
            verify_va  = store_vaddrs[s];
            verify_exp = shadow_mem[verify_va];
            verify_page = {verify_va[47:12], 12'b0};

            // Look up the TLB mapping for this page
            if (!tlb_shadow.exists(verify_page)) begin
                $display("  SKIP [%0d] vaddr=%012h — no TLB mapping found", s, verify_va);
                verify_total--;
                continue;
            end
            verify_pa = tlb_shadow[verify_page];

            // Use alternating tids: even for fill, odd for load.
            // Consecutive tids always differ so the LSQ recognises each
            // as a new operation (trace_id != trace_id_prev).
            fill_tid = 4'((2*s) & 4'hF);
            load_tid = 4'(((2*s) + 1) & 4'hF);

            // Step A: Re-fill TLB for this page
            drive_trace(make_trace(OP_TLB_FILL, fill_tid, verify_page,
                                   1'b1, '0, 1'b0, verify_pa), 2);

            // Step B: Issue LOAD with a unique tid the LSQ will enqueue
            drive_trace(load_trace(load_tid, verify_va), 1);

            // Step C: Wait for response (generous timeout for L2 misses)
            wait_resp(500, got_resp, rdata);

            if (got_resp) begin
                if (rdata === verify_exp) begin
                    verify_pass++;
                end else begin
                    verify_fail++;
                    $display("  FAIL [%0d] vaddr=%012h  got=%016h  exp=%016h",
                             s, verify_va, rdata, verify_exp);
                end
            end else begin
                verify_timeout++;
                $display("  TIMEOUT [%0d] vaddr=%012h  (no response in 200 cycles)",
                         s, verify_va);
            end

            // Brief settle between verifications
            repeat (4) @(posedge clk);

            if ((s % 50 == 0) && (s > 0))
                $display("  Phase 2 progress: %0d / %0d checked", s, store_count);
        end

        // ═════════════════════════════════════════════════════════════════
        //  Final Report
        // ═════════════════════════════════════════════════════════════════
        $display("");
        $display("════════════════════════════════════════════════════════════");
        $display(" verify_trace_tb — RESULTS");
        $display("════════════════════════════════════════════════════════════");
        $display("  Phase 1 (Trace Replay):");
        $display("    records processed       : %0d", rec_count);
        $display("    loads                   : %0d", load_count);
        $display("    stores                  : %0d", store_seen_count);
        $display("    resolves                : %0d", resolve_count);
        $display("    TLB fills               : %0d", fill_count);
        $display("    tlb requests issued     : %0d", tlb_req_count);
        $display("    cache requests issued   : %0d", cache_req_count);
        $display("    cache stores issued     : %0d", cache_store_count);
        $display("    cache responses         : %0d", cache_resp_count);
        $display("    L2 requests             : %0d", l2_req_count);
        $display("    writebacks              : %0d", wb_count);
        $display("");
        $display("  Phase 2 (Store Verification):");
        $display("    addresses checked       : %0d", verify_total);
        $display("    PASS                    : %0d", verify_pass);
        $display("    FAIL                    : %0d", verify_fail);
        $display("    TIMEOUT                 : %0d", verify_timeout);
        $display("");

        if (verify_fail == 0 && verify_timeout == 0)
            $display("  >>> ALL STORES VERIFIED SUCCESSFULLY <<<");
        else
            $display("  >>> VERIFICATION FAILURES DETECTED <<<");

        $display("════════════════════════════════════════════════════════════");
        $finish;
    end

endmodule
