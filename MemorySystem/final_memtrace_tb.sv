/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */

`timescale 1ns/1ps

module final_memtrace_tb #(
    parameter bit USE_REAL_L2 = 1'b1
);
    localparam logic [2:0] OP_MEM_LOAD    = 3'd0;
    localparam logic [2:0] OP_MEM_STORE   = 3'd1;
    localparam logic [2:0] OP_MEM_RESOLVE = 3'd2;
    localparam logic [2:0] OP_TLB_FILL    = 3'd4;

    logic clk;
    logic rst_n;
    logic [120:0] trace_line;

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

    task automatic decode_record;
        begin
            for (int i = 0; i < 16; i++)
                raw_record[i*8 +: 8] = buffer[i];
            trace_op = raw_record[54:52];
        end
    endtask

    task automatic do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            trace_line = '0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
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

    initial begin
        $timeformat(-9, 0, " ns", 8);
        $dumpfile("final_memtrace_tb.vcd");
        $dumpvars(0, final_memtrace_tb);

        if (!$value$plusargs("TRACE_FILE=%s", trace_file))
            trace_file = "aca-mem-traces/traces/dgemm3_lsq88.bin";
        if (!$value$plusargs("MAX_REC=%d", max_records))
            max_records = 2000;
        if (!$value$plusargs("DRAIN_CYCLES=%d", drain_cycles))
            drain_cycles = 4000;
        if (!$value$plusargs("TRACE_GAP_CYCLES=%d", trace_gap_cycles))
            trace_gap_cycles = 3;

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

        rst_n = 1'b0;
        trace_line = '0;
        do_reset();

        fd = $fopen(trace_file, "rb");
        if (fd == 0) begin
            $display("ERROR: could not open trace file %s", trace_file);
            $finish;
        end

        $display("Running final_memtrace_tb with TRACE_FILE=%s MAX_REC=%0d", trace_file, max_records);

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

        $display("\n============= final_memtrace_tb summary =============");
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
        $display("=====================================================");

        $finish;
    end
endmodule
