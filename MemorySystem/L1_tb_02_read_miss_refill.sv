`timescale 1ns/1ps

module L1_tb_02_read_miss_refill;
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
    logic saw_l2_req, saw_l2_resp;
    int fail_count;

    L1 dut (.*);
    dummy_L2 l2 (.clk(clk), .rst_n(rst_n), .l2_req_valid(l2_req_valid), .l2_req_addr(l2_req_addr),
                 .l2_resp_valid(l2_resp_valid), .l2_resp_data(l2_resp_data));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (l2_req_valid) saw_l2_req <= 1'b1;
        if (l2_resp_valid) saw_l2_resp <= 1'b1;
    end

    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk);
    endtask

    task automatic send_read(input logic [29:0] paddr);
        begin
            @(negedge clk);
            lookup_req_i <= 1'b1;
            lookup_vaddr_i <= {18'b0, paddr};
            lookup_paddr_i <= paddr;
            req_valid <= 1'b1;
            req_write <= 1'b0;
            req_addr <= paddr;
            req_wdata <= '0;
            @(negedge clk);
            lookup_req_i <= 1'b0;
            req_valid <= 1'b0;
        end
    endtask

    initial begin
        fail_count = 0;
        saw_l2_req = 1'b0;
        saw_l2_resp = 1'b0;
        rst_n = 1'b0;
        lookup_req_i = 1'b0;
        lookup_vaddr_i = '0;
        lookup_paddr_i = '0;
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = '0;
        req_wdata = '0;

        wait_cycles(4);
        @(negedge clk); rst_n = 1'b1;
        wait_cycles(1);

        send_read(30'h0000_0040);
        wait_cycles(6);
        send_read(30'h0000_0040);
        @(posedge clk);
        if (!saw_l2_req) fail_count++;
        if (!saw_l2_resp) fail_count++;
        if (lookup_hit_o !== 1'b1) fail_count++;

        $display("[TB02_READ_MISS_REFILL] %s", (fail_count == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule

