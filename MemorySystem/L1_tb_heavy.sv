/* verilator lint_off EOFNEWLINE */
`timescale 1ns/1ps

module L1_tb_heavy;
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

    function automatic logic [47:0] paddr_to_vaddr(input logic [29:0] paddr);
        paddr_to_vaddr = {18'b0, paddr};
    endfunction

    task automatic wait_cycles(input int n);
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    task automatic drive_req(
        input logic do_write,
        input logic [29:0] paddr,
        input logic [63:0] wdata,
        input int active_cycles,
        input int gap_cycles
    );
        int i;
        begin
            if (do_write) begin
                $display("[%0t][TB] SEND WRITE addr=%h data=%h", $time, paddr, wdata);
            end else begin
                $display("[%0t][TB] SEND READ  addr=%h", $time, paddr);
            end

            @(negedge clk);
            lookup_req_i   <= 1'b1;
            lookup_vaddr_i <= paddr_to_vaddr(paddr);
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
        input logic [29:0] paddr,
        input logic [63:0] exp_data,
        input int timeout_cycles
    );
        int i;
        logic seen;
        begin
            seen = 1'b0;
            $display("[%0t][TB] SEND READ  addr=%h", $time, paddr);

            @(negedge clk);
            lookup_req_i   <= 1'b1;
            lookup_vaddr_i <= paddr_to_vaddr(paddr);
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
                        $display("[%0t][TB] CHECK FAIL addr=%h got=%h exp=%h", $time, paddr, resp_rdata, exp_data);
                    end
                    i = timeout_cycles;
                end
            end

            if (!seen) begin
                fail_count = fail_count + 1;
                $display("[%0t][TB] CHECK FAIL addr=%h no response in %0d cycles", $time, paddr, timeout_cycles);
            end

            @(negedge clk);
            lookup_req_i   <= 1'b0;
            req_valid      <= 1'b0;
            req_write      <= 1'b0;
            req_wdata      <= '0;
            wait_cycles(1);
        end
    endtask

    task automatic write_read_expect(
        input logic [29:0] paddr,
        input logic [63:0] data
    );
        begin
            drive_req(1'b1, paddr, data, 1, 1);
            read_expect(paddr, data, 3);
        end
    endtask

    always @(posedge clk) begin
        if (resp_valid) begin
            $display("[%0t][TB] RECEIVE data=%h", $time, resp_rdata);
        end
    end

    initial begin
        $timeformat(-9, 0, " ns", 8);
        $dumpfile("L1_tb_heavy.vcd");
        $dumpvars(0, L1_tb_heavy);

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

        // Prime two lines so heavy sequence is mostly hit traffic.
        drive_req(1'b0, 30'h0000_0040, 64'h0, 1, 6);
        drive_req(1'b0, 30'h0000_00C0, 64'h0, 1, 6);

        // 20 write+read pairs (more than verbose bench).
        write_read_expect(30'h0000_0040, 64'hAA00_0000_0000_0001);
        write_read_expect(30'h0000_0048, 64'hAA00_0000_0000_0002);
        write_read_expect(30'h0000_0050, 64'hAA00_0000_0000_0003);
        write_read_expect(30'h0000_0058, 64'hAA00_0000_0000_0004);
        write_read_expect(30'h0000_0060, 64'hAA00_0000_0000_0005);
        write_read_expect(30'h0000_0068, 64'hAA00_0000_0000_0006);
        write_read_expect(30'h0000_0070, 64'hAA00_0000_0000_0007);
        write_read_expect(30'h0000_0078, 64'hAA00_0000_0000_0008);
        write_read_expect(30'h0000_00C0, 64'hBB00_0000_0000_0001);
        write_read_expect(30'h0000_00C8, 64'hBB00_0000_0000_0002);
        write_read_expect(30'h0000_00D0, 64'hBB00_0000_0000_0003);
        write_read_expect(30'h0000_00D8, 64'hBB00_0000_0000_0004);
        write_read_expect(30'h0000_00E0, 64'hBB00_0000_0000_0005);
        write_read_expect(30'h0000_00E8, 64'hBB00_0000_0000_0006);
        write_read_expect(30'h0000_00F0, 64'hBB00_0000_0000_0007);
        write_read_expect(30'h0000_00F8, 64'hBB00_0000_0000_0008);
        write_read_expect(30'h0000_0040, 64'hCC00_0000_0000_0011);
        write_read_expect(30'h0000_0050, 64'hCC00_0000_0000_0012);
        write_read_expect(30'h0000_00C0, 64'hDD00_0000_0000_0021);
        write_read_expect(30'h0000_00D0, 64'hDD00_0000_0000_0022);

        $display("[%0t][TB] heavy test done PASS=%0d FAIL=%0d", $time, pass_count, fail_count);
        $finish;
    end

endmodule
