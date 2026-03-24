/* verilator lint_off EOFNEWLINE */
`timescale 1ns/1ps

module L1_tb_verbose;
    logic clk;
    logic rst_n;

    // L1 request-side signals
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

    // L1 <-> L2 signals
    logic         l2_req_valid;
    logic [29:0]  l2_req_addr;
    logic         l2_resp_valid;
    logic [511:0] l2_resp_data;

    int pass_count, fail_count;

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
        .l2_resp_data(l2_resp_data)
    );

    dummy_L2 l2 (
        .clk(clk),
        .rst_n(rst_n),
        .l2_req_valid(l2_req_valid),
        .l2_req_addr(l2_req_addr),
        .l2_resp_valid(l2_resp_valid),
        .l2_resp_data(l2_resp_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic wait_cycles(input int n);
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    task automatic drive_req(
        input string label,
        input logic do_write,
        input logic [47:0] vaddr,
        input logic [29:0] paddr,
        input logic [63:0] wdata,
        input int active_cycles,
        input int gap_cycles
    );
        int i;
        begin
            if (do_write) begin
                $display("[%0t][TB] SEND WRITE label=%s addr=%h data=%h", $time, label, paddr, wdata);
            end else begin
                $display("[%0t][TB] SEND READ  label=%s addr=%h", $time, label, paddr);
            end
            @(negedge clk);
            lookup_req_i   <= 1'b1;
            lookup_vaddr_i <= vaddr;
            lookup_paddr_i <= paddr;
            req_valid      <= 1'b1;
            req_addr       <= paddr;
            req_write      <= do_write;
            req_wdata      <= wdata;

            for (i = 1; i < active_cycles; i++) begin
                @(negedge clk);
            end

            @(negedge clk);
            lookup_req_i   <= 1'b0;
            req_valid      <= 1'b0;
            req_write      <= 1'b0;
            req_wdata      <= '0;

            wait_cycles(gap_cycles);
        end
    endtask

    task automatic read_expect(
        input string label,
        input logic [47:0] vaddr,
        input logic [29:0] paddr,
        input logic [63:0] exp_data,
        input int timeout_cycles
    );
        int i;
        logic seen;
        begin
            seen = 1'b0;
            $display("[%0t][TB] SEND READ  label=%s addr=%h", $time, label, paddr);

            @(negedge clk);
            lookup_req_i   <= 1'b1;
            lookup_vaddr_i <= vaddr;
            lookup_paddr_i <= paddr;
            req_valid      <= 1'b1;
            req_addr       <= paddr;
            req_write      <= 1'b0;
            req_wdata      <= '0;

            for (i = 0; i < timeout_cycles; i++) begin
                @(posedge clk);
                #1;
                if (resp_valid) begin
                    seen = 1'b1;
                    if (resp_rdata === exp_data) begin
                        pass_count = pass_count + 1;
                    end else begin
                        fail_count = fail_count + 1;
                        $display("[%0t][TB] CHECK FAIL label=%s got=%h exp=%h", $time, label, resp_rdata, exp_data);
                    end
                    i = timeout_cycles;
                end
            end

            if (!seen) begin
                fail_count = fail_count + 1;
                $display("[%0t][TB] CHECK FAIL label=%s no response in %0d cycles", $time, label, timeout_cycles);
            end

            @(negedge clk);
            lookup_req_i   <= 1'b0;
            req_valid      <= 1'b0;
            req_write      <= 1'b0;
            req_wdata      <= '0;
            wait_cycles(2);
        end
    endtask

    task automatic write_read_expect(
        input string label,
        input logic [47:0] vaddr,
        input logic [29:0] paddr,
        input logic [63:0] data
    );
        begin
            drive_req({label, "_W"}, 1'b1, vaddr, paddr, data, 1, 1);
            read_expect({label, "_R"}, vaddr, paddr, data, 3);
        end
    endtask

    always @(posedge clk) begin
        if (resp_valid) begin
            $display("[%0t][TB] RECEIVE data=%h", $time, resp_rdata);
        end
    end

    initial begin
        $timeformat(-9, 0, " ns", 8);
        $dumpfile("L1_tb_verbose.vcd");
        $dumpvars(0, L1_tb_verbose);

        pass_count = 0;
        fail_count = 0;
        rst_n = 1'b0;
        lookup_req_i = 1'b0;
        lookup_vaddr_i = '0;
        lookup_paddr_i = '0;
        req_valid = 1'b0;
        req_addr = '0;
        req_write = 1'b0;
        req_wdata = '0;

        $display("[%0t][TB] reset asserted", $time);
        wait_cycles(4);
        @(negedge clk);
        rst_n = 1'b1;
        $display("[%0t][TB] reset deasserted", $time);
        wait_cycles(2);

        // Same line transactions (should merge into same miss block).
        drive_req("READ_A_MISS_0x40", 1'b0, 48'h0000_0000_0040, 30'h0000_0040, 64'h0, 1, 2);
        drive_req("READ_A_MERGE_0x48", 1'b0, 48'h0000_0000_0048, 30'h0000_0048, 64'h0, 1, 1);
        drive_req("STORE_A_MERGE_0x48", 1'b1, 48'h0000_0000_0048, 30'h0000_0048, 64'hA1A1_A1A1_1111_2222, 1, 6);
        read_expect("READ_AFTER_WRITE_A_0x48", 48'h0000_0000_0048, 30'h0000_0048, 64'hA1A1_A1A1_1111_2222, 3);

        // Different line transactions.
        drive_req("READ_B_MISS_0xC0", 1'b0, 48'h0000_0000_00C0, 30'h0000_00C0, 64'h0, 1, 2);
        drive_req("WRITE_B_MERGE_0xC8", 1'b1, 48'h0000_0000_00C8, 30'h0000_00C8, 64'hB2B2_B2B2_3333_4444, 1, 6);

        // Re-read line A after refill path activity.
        drive_req("READ_A_AGAIN_0x40", 1'b0, 48'h0000_0000_0040, 30'h0000_0040, 64'h0, 1, 8);
        read_expect("READ_A1_DATA_AGAIN_0x48", 48'h0000_0000_0048, 30'h0000_0048, 64'hA1A1_A1A1_1111_2222, 3);

        // 10 additional write+read pairs.
        write_read_expect("PAIR_01_0x40", 48'h0000_0000_0040, 30'h0000_0040, 64'h0101_0101_AAAA_0001);
        write_read_expect("PAIR_02_0x50", 48'h0000_0000_0050, 30'h0000_0050, 64'h0202_0202_AAAA_0002);
        write_read_expect("PAIR_03_0x58", 48'h0000_0000_0058, 30'h0000_0058, 64'h0303_0303_AAAA_0003);
        write_read_expect("PAIR_04_0x68", 48'h0000_0000_0068, 30'h0000_0068, 64'h0404_0404_AAAA_0004);
        write_read_expect("PAIR_05_0x70", 48'h0000_0000_0070, 30'h0000_0070, 64'h0505_0505_AAAA_0005);
        write_read_expect("PAIR_06_0xC0", 48'h0000_0000_00C0, 30'h0000_00C0, 64'h0606_0606_BBBB_0006);
        write_read_expect("PAIR_07_0xD0", 48'h0000_0000_00D0, 30'h0000_00D0, 64'h0707_0707_BBBB_0007);
        write_read_expect("PAIR_08_0xD8", 48'h0000_0000_00D8, 30'h0000_00D8, 64'h0808_0808_BBBB_0008);
        write_read_expect("PAIR_09_0xE8", 48'h0000_0000_00E8, 30'h0000_00E8, 64'h0909_0909_BBBB_0009);
        write_read_expect("PAIR_10_0xF0", 48'h0000_0000_00F0, 30'h0000_00F0, 64'h1010_1010_BBBB_0010);

        $display("[%0t][TB] verbose test done PASS=%0d FAIL=%0d", $time, pass_count, fail_count);
        $finish;
    end

endmodule
