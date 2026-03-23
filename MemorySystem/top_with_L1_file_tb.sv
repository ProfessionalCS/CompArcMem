/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */

`timescale 1ns/1ps

module top_with_L1_file_tb #(
    parameter bit USE_REAL_L2 = 1'b0
);
    typedef enum logic [2:0] {
        OP_MEM_LOAD    = 3'd0,
        OP_MEM_STORE   = 3'd1,
        OP_MEM_RESOLVE = 3'd2,
        OP_TLB_FILL    = 3'd4
    } op_e;

    logic clk;
    logic rst_n;
    logic [120:0] trace_line;

    byte buffer [0:15];
    logic [127:0] raw_record;

    op_e trace_op;
    logic [3:0] trace_id;
    logic [47:0] trace_vaddr;
    logic trace_vaddr_is_valid;
    logic trace_value_is_valid;
    logic [63:0] trace_value;
    logic [29:0] trace_tlb_paddr;

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

    top_with_L1 #(
        .USE_REAL_L2(USE_REAL_L2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .trace_line(trace_line)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic decode_record;
        begin
            for (int i = 0; i < 16; i++)
                raw_record[i*8 +: 8] = buffer[i];

            trace_op             = op_e'(raw_record[54:52]);
            trace_id             = raw_record[51:48];
            trace_vaddr          = raw_record[47:0];
            trace_vaddr_is_valid = raw_record[55];
            trace_tlb_paddr      = raw_record[85:56];
            trace_value          = raw_record[119:56];
            trace_value_is_valid = raw_record[120];
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

    // Counters for observable DUT activity.
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.cache_req)
                cache_req_count <= cache_req_count + 1;
            if (dut.cache_req && dut.cache_we)
                cache_store_count <= cache_store_count + 1;
            if (dut.cache_ret_valid)
                cache_resp_count <= cache_resp_count + 1;
            if (dut.tlb_req)
                tlb_req_count <= tlb_req_count + 1;
        end
    end

    initial begin
        $timeformat(-9, 0, " ns", 8);
        $dumpfile("top_with_L1_file_tb.vcd");
        $dumpvars(0, top_with_L1_file_tb);

        if (!$value$plusargs("TRACE_FILE=%s", trace_file))
            trace_file = "aca-mem-traces/traces/dgemm3.bin";
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

        rst_n = 1'b0;
        trace_line = '0;
        do_reset();

        fd = $fopen(trace_file, "rb");
        if (fd == 0) begin
            $display("ERROR: could not open trace file %s", trace_file);
            $finish;
        end

        $display("Running top_with_L1 file replay with TRACE_FILE=%s MAX_REC=%0d", trace_file, max_records);

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

        $display("\n============= top_with_L1 file replay summary =============");
        $display("records processed         : %0d", rec_count);
        $display("loads seen                : %0d", load_count);
        $display("stores seen               : %0d", store_count);
        $display("resolves seen             : %0d", resolve_count);
        $display("tlb fills seen            : %0d", fill_count);
        $display("tlb requests issued       : %0d", tlb_req_count);
        $display("cache requests issued     : %0d", cache_req_count);
        $display("cache stores committed    : %0d", cache_store_count);
        $display("cache responses observed  : %0d", cache_resp_count);
        $display("===========================================================");

        $finish;
    end
endmodule
