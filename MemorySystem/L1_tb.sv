/* verilator lint_off EOFNEWLINE */
`timescale 1ns/1ps

module L1_tb;
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

    logic        l2_req_valid;
    logic [29:0] l2_req_addr;
    logic        l2_resp_valid;
    logic [511:0] l2_resp_data;
    logic         wb_valid;
    logic [29:0]  wb_addr;
    logic [511:0] wb_data;

    int pass_count;
    int fail_count;

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

    function automatic logic [63:0] expected_l2_word(input logic [29:0] paddr);
        logic [23:0] block_addr;
        logic [2:0] word_idx;
        begin
            block_addr = paddr[29:6];
            word_idx = paddr[5:3];
            expected_l2_word = {32'hD00D_0000 | {8'h00, block_addr}, 29'h0, word_idx};
        end
    endfunction

    task automatic do_reset();
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

    task automatic issue_load(input logic [29:0] paddr);
        begin
            @(negedge clk);
            lookup_req_i = 1'b1;
            req_valid = 1'b1;
            req_write = 1'b0;
            lookup_paddr_i = paddr;
            lookup_vaddr_i = {40'h0, paddr[7:0]};
            req_addr = paddr;
            req_wdata = '0;
            @(posedge clk);
            #1;
            @(negedge clk);
            lookup_req_i = 1'b0;
            req_valid = 1'b0;
            req_write = 1'b0;
        end
    endtask

    task automatic issue_store(input logic [29:0] paddr, input logic [63:0] data);
        begin
            @(negedge clk);
            lookup_req_i = 1'b1;
            req_valid = 1'b1;
            req_write = 1'b1;
            lookup_paddr_i = paddr;
            lookup_vaddr_i = {40'h0, paddr[7:0]};
            req_addr = paddr;
            req_wdata = data;
            @(posedge clk);
            #1;
            @(negedge clk);
            lookup_req_i = 1'b0;
            req_valid = 1'b0;
            req_write = 1'b0;
        end
    endtask

    task automatic wait_for_resp(
        input string name,
        input logic [63:0] exp_data,
        input int timeout_cycles
    );
        int c;
        logic seen;
        begin
            seen = 1'b0;
            for (c = 0; c < timeout_cycles; c++) begin
                @(posedge clk);
                #1;
                if (resp_valid) begin
                    seen = 1'b1;
                    if (resp_rdata === exp_data) begin
                        $display("PASS [%s] resp=%h", name, resp_rdata);
                        pass_count++;
                    end else begin
                        $display("FAIL [%s] got=%h exp=%h", name, resp_rdata, exp_data);
                        fail_count++;
                    end
                    c = timeout_cycles;
                end
            end
            if (!seen) begin
                $display("FAIL [%s] no response", name);
                fail_count++;
            end
        end
    endtask

    task automatic wait_for_write_ack(input string name, input int timeout_cycles);
        int c;
        logic seen;
        begin
            seen = 1'b0;
            for (c = 0; c < timeout_cycles; c++) begin
                @(posedge clk);
                #1;
                if (resp_valid) begin
                    seen = 1'b1;
                    $display("PASS [%s] write ack", name);
                    pass_count++;
                    c = timeout_cycles;
                end
            end
            if (!seen) begin
                $display("FAIL [%s] no write ack", name);
                fail_count++;
            end
        end
    endtask

    initial begin
        logic [29:0] a0;
        logic [29:0] a1;
        logic [29:0] a0_w3;
        logic [29:0] a0_w5;
        logic [29:0] a2;
        logic [29:0] a2_w2;
        logic [63:0] w0;
        logic [63:0] w1;
        logic [63:0] w2;

        $timeformat(-9, 0, " ns", 8);
        $dumpfile("L1_tb.vcd");
        $dumpvars(0, L1_tb);

        pass_count = 0;
        fail_count = 0;

        a0 = 30'h0000_0408;
        a1 = 30'h0000_1800;
    a0_w3 = 30'h0000_0418;
    a0_w5 = 30'h0000_0428;
    a2 = 30'h0000_2440;
    a2_w2 = 30'h0000_2450;
        w0 = 64'h1122_3344_5566_7788;
    w1 = 64'h89AB_CDEF_0123_4567;
    w2 = 64'hDEAD_BEEF_CAFE_BABE;

        do_reset();

        $display("\nTC1: cold load miss refills from dummy_L2 backing store");
        issue_load(a0);
        wait_for_resp("TC1", expected_l2_word(a0), 60);

        $display("\nTC2: second load to same addr should hit with same data");
        issue_load(a0);
        wait_for_resp("TC2", expected_l2_word(a0), 20);

        $display("\nTC3: store hit updates cached word and acks");
        issue_store(a0, w0);
        wait_for_write_ack("TC3", 20);

        $display("\nTC4: load after store should return stored data");
        issue_load(a0);
        wait_for_resp("TC4", w0, 20);

        $display("\nTC5: different line miss returns that line's deterministic data");
        issue_load(a1);
        wait_for_resp("TC5", expected_l2_word(a1), 60);

        $display("\nTC6: same cache line different word offset should be intact");
        issue_load(a0_w3);
        wait_for_resp("TC6", expected_l2_word(a0_w3), 20);

        $display("\nTC7: store hit on same line different offset");
        issue_store(a0_w3, w1);
        wait_for_write_ack("TC7", 20);

        $display("\nTC8: reload stored different offset");
        issue_load(a0_w3);
        wait_for_resp("TC8", w1, 20);

        $display("\nTC9: original stored word should remain unchanged");
        issue_load(a0);
        wait_for_resp("TC9", w0, 20);

        $display("\nTC10: another untouched word in same line should still be default");
        issue_load(a0_w5);
        wait_for_resp("TC10", expected_l2_word(a0_w5), 20);

        $display("\nTC11: cold miss on third line");
        issue_load(a2);
        wait_for_resp("TC11", expected_l2_word(a2), 60);

        $display("\nTC12: hit on third line after refill");
        issue_load(a2);
        wait_for_resp("TC12", expected_l2_word(a2), 20);

        $display("\nTC13: store hit on third line base word");
        issue_store(a2, w2);
        wait_for_write_ack("TC13", 20);

        $display("\nTC14: reload third line stored word");
        issue_load(a2);
        wait_for_resp("TC14", w2, 20);

        $display("\nTC15: another word in third line remains default");
        issue_load(a2_w2);
        wait_for_resp("TC15", expected_l2_word(a2_w2), 20);

        $display("\nTC16: cross-line retention check line a1");
        issue_load(a1);
        wait_for_resp("TC16", expected_l2_word(a1), 20);

        $display("\nTC17: cross-line retention check line a0 word3");
        issue_load(a0_w3);
        wait_for_resp("TC17", w1, 20);

        $display("\nTC18: reset then reload a0 should return default (cache cleared)");
        do_reset();
        issue_load(a0);
        wait_for_resp("TC18", expected_l2_word(a0), 60);

        $display("\n========================================");
        $display("L1_tb: PASS=%0d FAIL=%0d", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else $display("SOME TESTS FAILED");
        $display("========================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT: L1_tb exceeded 2 ms");
        $finish;
    end

endmodule