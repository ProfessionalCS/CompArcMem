/* verilator lint_off EOFNEWLINE */
`timescale 1ns/1ps

module L1_tb_4writes_then_read_20x;
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

    int read_seen_count;
    int read_timeout_count;

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

    task automatic pulse_req(
        input logic do_write,
        input logic [29:0] paddr,
        input logic [63:0] wdata
    );
        begin
            @(negedge clk);
            lookup_req_i   <= 1'b1;
            lookup_vaddr_i <= paddr_to_vaddr(paddr);
            lookup_paddr_i <= paddr;
            req_valid      <= 1'b1;
            req_addr       <= paddr;
            req_write      <= do_write;
            req_wdata      <= wdata;

            @(negedge clk);
            lookup_req_i   <= 1'b0;
            req_valid      <= 1'b0;
            req_write      <= 1'b0;
            req_wdata      <= '0;
        end
    endtask

    task automatic send_write(
        input logic [29:0] paddr,
        input logic [63:0] data
    );
        begin
            $display("[%0t][TB] SEND WRITE addr=%h data=%h", $time, paddr, data);
            pulse_req(1'b1, paddr, data);
        end
    endtask

    task automatic try_read(
        input logic [29:0] paddr,
        input int timeout_cycles
    );
        int t;
        logic seen;
        begin
            seen = 1'b0;
            $display("[%0t][TB] SEND READ  addr=%h", $time, paddr);
            pulse_req(1'b0, paddr, 64'h0);

            for (t = 0; t < timeout_cycles; t++) begin
                @(posedge clk);
                #1;
                if (resp_valid) begin
                    seen = 1'b1;
                    read_seen_count = read_seen_count + 1;
                    $display("[%0t][TB] READ RESULT addr=%h data=%h", $time, paddr, resp_rdata);
                    t = timeout_cycles;
                end
            end

            if (!seen) begin
                read_timeout_count = read_timeout_count + 1;
                $display("[%0t][TB] READ RESULT addr=%h no response", $time, paddr);
            end
        end
    endtask

    always @(posedge clk) begin
        if (resp_valid) begin
            $display("[%0t][TB] RECEIVE data=%h", $time, resp_rdata);
        end
    end

    initial begin
        int i;
        logic [29:0] base_addr;
        logic [63:0] d0, d1, d2, d3;

        $timeformat(-9, 0, " ns", 8);
        $dumpfile("L1_tb_4writes_then_read_20x.vcd");
        $dumpvars(0, L1_tb_4writes_then_read_20x);

        read_seen_count = 0;
        read_timeout_count = 0;

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

        for (i = 0; i < 20; i++) begin
            base_addr = 30'h0000_0400 + (i * 30'd64);
            d0 = 64'hA0A0_0000_0000_0000 + i;
            d1 = 64'hB0B0_0000_0000_0000 + i;
            d2 = 64'hC0C0_0000_0000_0000 + i;
            d3 = 64'hD0D0_0000_0000_0000 + i;

            $display("[%0t][TB] ITER=%0d begin", $time, i);
            send_write(base_addr + 30'd0,  d0);
            send_write(base_addr + 30'd8,  d1);
            send_write(base_addr + 30'd16, d2);
            send_write(base_addr + 30'd24, d3);

            $display("[%0t][TB] ITER=%0d wait after 4 writes", $time, i);
            wait_cycles(4);

            try_read(base_addr + 30'd8, 4);
            wait_cycles(1);
        end

        $display("[%0t][TB] done read_seen=%0d read_timeout=%0d", $time, read_seen_count, read_timeout_count);
        $finish;
    end
endmodule
