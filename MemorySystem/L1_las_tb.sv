/* verilator lint_off EOFNEWLINE */
`timescale 1ns/1ps

module L1_las_tb;
    typedef enum logic [2:0] {
        OP_MEM_LOAD    = 3'd0,
        OP_MEM_STORE   = 3'd1,
        OP_MEM_RESOLVE = 3'd2,
        OP_TLB_FILL    = 3'd4
    } op_e;

    localparam int TLB_SHIM_ENTRIES  = 64;
    localparam int SHADOW_ENTRIES    = 256;  // shadow store table size

    logic clk;
    logic rst_n;

    logic        lookup_req_i;
    logic [47:0] lookup_vaddr_i;
    logic [29:0] lookup_paddr_i;
    logic        lookup_hit_o;

    logic        req_valid;
    logic [29:0] req_addr;
    logic        req_write;
    logic [63:0] req_wdata;
    logic        resp_valid;
    logic [63:0] resp_rdata;

    logic         l2_req_valid;
    logic [29:0]  l2_req_addr;
    logic         l2_resp_valid;
    logic [511:0] l2_resp_data;
    logic         wb_valid;
    logic [29:0]  wb_addr;
    logic [511:0] wb_data;

    byte buffer [0:15];
    logic [127:0] trace_line;

    op_e trace_op;
    logic [3:0] trace_id;
    logic [47:0] trace_vaddr;
    logic trace_vaddr_is_valid;
    logic [29:0] trace_tlb_paddr;
    logic [63:0] trace_value;
    logic trace_value_is_valid;

    // ---- TLB shim ----
    logic tlb_valid [0:TLB_SHIM_ENTRIES-1];
    logic [35:0] tlb_vpn [0:TLB_SHIM_ENTRIES-1];
    logic [17:0] tlb_ppn [0:TLB_SHIM_ENTRIES-1];

    // ---- shadow store table ----
    // Tracks paddr -> last written 64-bit value for load-after-store checking.
    // Simple direct-mapped by low bits, with full-address tag for correctness.
    logic          shadow_valid [0:SHADOW_ENTRIES-1];
    logic [29:0]   shadow_addr  [0:SHADOW_ENTRIES-1];
    logic [63:0]   shadow_data  [0:SHADOW_ENTRIES-1];

    int fd;
    string trace_file;
    int max_records;
    int rec_count;

    int fill_count;
    int mem_issue_count;
    int load_count;
    int store_count;
    int resolve_count;
    int skipped_no_tlb;
    int skipped_unresolved_store;
    int resp_count;
    int timeout_count;

    // load-after-store tracking counters
    int las_checks;
    int las_pass;
    int las_fail;

    L1 dut (
        .clk(clk),
        .rst_n(rst_n),
        .lookup_req_i(lookup_req_i),
        .lookup_vaddr_i(lookup_vaddr_i),
        .lookup_paddr_i(lookup_paddr_i),
        .lookup_hit_o(lookup_hit_o),
        .req_valid(req_valid),
        .req_addr(req_addr),
        .req_write(req_write),
        .req_wdata(req_wdata),
        .resp_valid(resp_valid),
        .resp_rdata(resp_rdata),
        .l2_req_valid(l2_req_valid),
        .l2_req_addr(l2_req_addr),
        .l2_resp_valid(l2_resp_valid),
        .l2_resp_data(l2_resp_data),
        .wb_valid(wb_valid),
        .wb_addr(wb_addr),
        .wb_data(wb_data)
    );

    dummy_L2 dut_l2 (
        .clk(clk),
        .rst_n(rst_n),
        .l2_req_valid(l2_req_valid),
        .l2_req_addr(l2_req_addr),
        .l2_resp_valid(l2_resp_valid),
        .l2_resp_data(l2_resp_data),
        .wb_valid(wb_valid),
        .wb_addr(wb_addr),
        .wb_data(wb_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------
    // decode_trace_from_buffer: unpack binary record into trace fields
    // -------------------------------------------------------------------
    task automatic decode_trace_from_buffer;
        begin
            for (int i = 0; i < 16; i++) begin
                trace_line[i*8 +: 8] = buffer[i];
            end
            trace_op             = op_e'(trace_line[54:52]);
            trace_id             = trace_line[51:48];
            trace_vaddr          = trace_line[47:0];
            trace_vaddr_is_valid = trace_line[55];
            trace_tlb_paddr      = trace_line[85:56];
            trace_value          = trace_line[119:56];
            trace_value_is_valid = trace_line[120];
        end
    endtask

    // -------------------------------------------------------------------
    // do_reset
    // -------------------------------------------------------------------
    task automatic do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            lookup_req_i = 1'b0;
            lookup_vaddr_i = '0;
            lookup_paddr_i = '0;
            req_valid = 1'b0;
            req_addr = '0;
            req_write = 1'b0;
            req_wdata = '0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // -------------------------------------------------------------------
    // TLB shim tasks
    // -------------------------------------------------------------------
    task automatic tlb_insert(input logic [47:0] vaddr, input logic [29:0] paddr);
        logic [35:0] vpn;
        logic [17:0] ppn;
        int idx;
        int free_idx;
        logic found;
        begin
            vpn = vaddr[47:12];
            ppn = paddr[29:12];
            found = 1'b0;
            free_idx = -1;

            for (idx = 0; idx < TLB_SHIM_ENTRIES; idx++) begin
                if (tlb_valid[idx] && tlb_vpn[idx] == vpn) begin
                    tlb_ppn[idx] = ppn;
                    found = 1'b1;
                end
                if (!tlb_valid[idx] && free_idx == -1)
                    free_idx = idx;
            end

            if (!found) begin
                if (free_idx != -1)
                    idx = free_idx;
                else
                    idx = 0;  // evict slot 0 if full

                tlb_valid[idx] = 1'b1;
                tlb_vpn[idx] = vpn;
                tlb_ppn[idx] = ppn;
            end
        end
    endtask

    task automatic tlb_lookup(
        input  logic [47:0] vaddr,
        output logic        hit,
        output logic [29:0] paddr
    );
        logic [35:0] vpn;
        begin
            vpn = vaddr[47:12];
            paddr = '0;
            hit = 1'b0;
            for (int idx = 0; idx < TLB_SHIM_ENTRIES; idx++) begin
                if (tlb_valid[idx] && tlb_vpn[idx] == vpn) begin
                    paddr = {tlb_ppn[idx], vaddr[11:0]};
                    hit = 1'b1;
                end
            end
        end
    endtask

    // -------------------------------------------------------------------
    // Shadow store table tasks
    //   shadow_insert: record that paddr was written with data
    //   shadow_lookup: check if paddr has a pending expected value
    // -------------------------------------------------------------------
    task automatic shadow_insert(input logic [29:0] paddr, input logic [63:0] data);
        int slot;
        int free_slot;
        logic found;
        begin
            // Use low bits of paddr as index hint; do full-address match
            slot = int'(paddr[7:0]);  // low 8 bits -> 0..255
            found = 1'b0;
            free_slot = -1;

            // First pass: look for existing entry with same address
            for (int i = 0; i < SHADOW_ENTRIES; i++) begin
                if (shadow_valid[i] && shadow_addr[i] == paddr) begin
                    shadow_data[i] = data;
                    found = 1'b1;
                end
                if (!shadow_valid[i] && free_slot == -1)
                    free_slot = i;
            end

            if (!found) begin
                // Use hinted slot (evict if needed)
                if (!shadow_valid[slot])
                    free_slot = slot;
                else if (free_slot == -1)
                    free_slot = slot;  // evict hint slot

                shadow_valid[free_slot] = 1'b1;
                shadow_addr [free_slot] = paddr;
                shadow_data [free_slot] = data;
            end
        end
    endtask

    task automatic shadow_lookup(
        input  logic [29:0] paddr,
        output logic        hit,
        output logic [63:0] data
    );
        begin
            data = '0;
            hit  = 1'b0;
            for (int i = 0; i < SHADOW_ENTRIES; i++) begin
                if (shadow_valid[i] && shadow_addr[i] == paddr) begin
                    data = shadow_data[i];
                    hit  = 1'b1;
                end
            end
        end
    endtask

    // -------------------------------------------------------------------
    // issue_mem_req: drive L1 inputs for one cycle then de-assert
    // -------------------------------------------------------------------
    task automatic issue_mem_req(
        input logic [47:0] vaddr,
        input logic [29:0] paddr,
        input logic        is_store,
        input logic [63:0] wdata
    );
        begin
            @(negedge clk);
            lookup_req_i   = 1'b1;
            lookup_vaddr_i = vaddr;
            lookup_paddr_i = paddr;
            req_valid  = 1'b1;
            req_addr   = paddr;
            req_write  = is_store;
            req_wdata  = wdata;
            @(posedge clk);
            #1;
            @(negedge clk);
            lookup_req_i = 1'b0;
            req_valid    = 1'b0;
            req_write    = 1'b0;
            req_wdata    = '0;
        end
    endtask

    // -------------------------------------------------------------------
    // wait_resp_with_timeout: poll for resp_valid, capture rdata
    // -------------------------------------------------------------------
    task automatic wait_resp_with_timeout(
        input  int          timeout_cycles,
        output logic        seen,
        output logic [63:0] captured_rdata
    );
        begin
            seen = 1'b0;
            captured_rdata = '0;
            for (int c = 0; c < timeout_cycles; c++) begin
                @(posedge clk);
                #1;
                if (resp_valid) begin
                    seen = 1'b1;
                    captured_rdata = resp_rdata;
                    resp_count++;
                    c = timeout_cycles;  // break
                end
            end
            if (!seen)
                timeout_count++;
        end
    endtask

    // -------------------------------------------------------------------
    // Main test initial block
    // -------------------------------------------------------------------
    initial begin
        logic [29:0] translated_paddr;
        logic        tlb_hit;
        logic        seen_resp;
        logic [63:0] got_rdata;

        // load-after-store check locals
        logic        shadow_hit;
        logic [63:0] expected_rdata;

        $timeformat(-9, 0, " ns", 8);
        $dumpfile("L1_las_tb.vcd");
        $dumpvars(0, L1_las_tb);

        if (!$value$plusargs("TRACE_FILE=%s", trace_file))
            trace_file = "aca-mem-traces/traces/dgemm3.bin";
        if (!$value$plusargs("MAX_REC=%d", max_records))
            max_records = 5000;

        // init TLB shim
        for (int i = 0; i < TLB_SHIM_ENTRIES; i++) begin
            tlb_valid[i] = 1'b0;
            tlb_vpn[i]   = '0;
            tlb_ppn[i]   = '0;
        end

        // init shadow store table
        for (int i = 0; i < SHADOW_ENTRIES; i++) begin
            shadow_valid[i] = 1'b0;
            shadow_addr[i]  = '0;
            shadow_data[i]  = '0;
        end

        fill_count               = 0;
        mem_issue_count          = 0;
        load_count               = 0;
        store_count              = 0;
        resolve_count            = 0;
        skipped_no_tlb           = 0;
        skipped_unresolved_store = 0;
        resp_count               = 0;
        timeout_count            = 0;
        rec_count                = 0;
        las_checks               = 0;
        las_pass                 = 0;
        las_fail                 = 0;

        do_reset();

        fd = $fopen(trace_file, "rb");
        if (fd == 0) begin
            $display("ERROR: could not open trace file %s", trace_file);
            $finish;
        end

        $display("Running L1 LAS trace replay  TRACE_FILE=%s  MAX_REC=%0d", trace_file, max_records);

        while (($fread(buffer, fd) == 16) && ((max_records == 0) || (rec_count < max_records))) begin
            rec_count++;
            decode_trace_from_buffer();

            case (trace_op)

                // -------------------------------------------------------
                OP_TLB_FILL: begin
                    tlb_insert(trace_vaddr, trace_tlb_paddr);
                    fill_count++;
                end

                // -------------------------------------------------------
                OP_MEM_LOAD: begin
                    if (trace_vaddr_is_valid) begin
                        tlb_lookup(trace_vaddr, tlb_hit, translated_paddr);
                        if (tlb_hit) begin
                            issue_mem_req(trace_vaddr, translated_paddr, 1'b0, '0);
                            wait_resp_with_timeout(200, seen_resp, got_rdata);
                            mem_issue_count++;
                            load_count++;

                            // --- load-after-store check ---
                            if (seen_resp) begin
                                shadow_lookup(translated_paddr, shadow_hit, expected_rdata);
                                if (shadow_hit) begin
                                    las_checks++;
                                    if (got_rdata === expected_rdata) begin
                                        las_pass++;
                                    end else begin
                                        las_fail++;
                                        $display("LAS FAIL  rec=%0d  paddr=0x%07x  expected=0x%016x  got=0x%016x",
                                                 rec_count, translated_paddr, expected_rdata, got_rdata);
                                    end
                                end
                            end

                        end else begin
                            skipped_no_tlb++;
                        end
                    end
                end

                // -------------------------------------------------------
                OP_MEM_STORE: begin
                    if (trace_vaddr_is_valid) begin
                        if (trace_value_is_valid) begin
                            tlb_lookup(trace_vaddr, tlb_hit, translated_paddr);
                            if (tlb_hit) begin
                                // Record BEFORE issuing so shadow is always current,
                                // even if the L1 acks via the slow miss-then-refill path.
                                shadow_insert(translated_paddr, trace_value);
                                issue_mem_req(trace_vaddr, translated_paddr, 1'b1, trace_value);
                                wait_resp_with_timeout(200, seen_resp, got_rdata);
                                mem_issue_count++;
                                store_count++;

                            end else begin
                                skipped_no_tlb++;
                            end
                        end else begin
                            skipped_unresolved_store++;
                        end
                    end
                end

                // -------------------------------------------------------
                OP_MEM_RESOLVE: begin
                    resolve_count++;
                end

                default: begin
                end
            endcase

            if ((rec_count % 1000) == 0)
                $display("Progress: processed %0d records", rec_count);
        end

        $fclose(fd);

        $display("\n============= L1 LAS memtrace summary =============");
        $display("records processed         : %0d", rec_count);
        $display("tlb fills applied         : %0d", fill_count);
        $display("loads issued to L1        : %0d", load_count);
        $display("stores issued to L1       : %0d", store_count);
        $display("resolves seen             : %0d", resolve_count);
        $display("requests issued total     : %0d", mem_issue_count);
        $display("responses observed        : %0d", resp_count);
        $display("response timeouts         : %0d", timeout_count);
        $display("skipped (no TLB mapping)  : %0d", skipped_no_tlb);
        $display("skipped unresolved stores : %0d", skipped_unresolved_store);
        $display("----------------------------------------------------");
        $display("LAS checks performed      : %0d", las_checks);
        $display("LAS PASS                  : %0d", las_pass);
        $display("LAS FAIL                  : %0d", las_fail);
        if (las_fail == 0 && las_checks > 0)
            $display("ALL LAS CHECKS PASSED");
        else if (las_checks == 0)
            $display("(no load-after-store pairs found in this trace window)");
        $display("====================================================");

        $finish;
    end
endmodule
