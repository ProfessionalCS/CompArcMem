`timescale 1ns/1ps

module L1_tb_01_reset;
    logic clk, rst_n;
    logic lookup_req_i;
    logic [47:0] lookup_vaddr_i;
    logic [29:0] lookup_paddr_i;
    logic lookup_hit_o;
    logic req_valid, req_write;
    logic [29:0] req_addr;
    logic [63:0] req_wdata;
    logic resp_valid;
    logic [63:0] resp_rdata;
    logic l2_req_valid;
    logic [29:0] l2_req_addr;
    logic l2_resp_valid;
    logic [511:0] l2_resp_data;
    int fail_count;

    L1 dut (.*);
    dummy_L2 l2 (.clk(clk), .rst_n(rst_n), .l2_req_valid(l2_req_valid), .l2_req_addr(l2_req_addr),
                 .l2_resp_valid(l2_resp_valid), .l2_resp_data(l2_resp_data));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk);
    endtask

    initial begin
        fail_count = 0;
        rst_n = 1'b0;
        lookup_req_i = 1'b0;
        lookup_vaddr_i = '0;
        lookup_paddr_i = '0;
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = '0;
        req_wdata = '0;

        wait_cycles(4);
        if (resp_valid !== 1'b0) fail_count++;
        if (l2_req_valid !== 1'b0) fail_count++;
        if (dut.mshr0.valid !== 1'b0) fail_count++;
        if (dut.mshr1.valid !== 1'b0) fail_count++;

        @(negedge clk);
        rst_n = 1'b1;
        wait_cycles(2);

        $display("[TB01_RESET] %s", (fail_count == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule

