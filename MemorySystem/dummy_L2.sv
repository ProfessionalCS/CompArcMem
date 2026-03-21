/* verilator lint_off EOFNEWLINE */
`timescale 1ns/1ps

// Dummy L2 with backing line store.
// - Accepts line read requests from L1
// - Returns a full 64B line after 1 cycle
// - Persists each line in a large array so repeated reads return stable data
module dummy_L2 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         l2_req_valid,
    input  logic [29:0]  l2_req_addr,
    output logic         l2_resp_valid,
    output logic [511:0] l2_resp_data,
    // Write-back intake from L1 dirty evictions
    input  logic         wb_valid,
    input  logic [29:0]  wb_addr,
    input  logic [511:0] wb_data
);
    localparam int MEM_LINES = 65536;
    localparam int MEM_ADDR_W = 16;

    logic [511:0] line_mem   [0:MEM_LINES-1];
    logic         line_valid [0:MEM_LINES-1];

    logic              req_d;
    logic [29:0]       req_addr_d;
    logic [MEM_ADDR_W-1:0] mem_idx;
    logic [23:0]       line_addr;

    function automatic logic [511:0] make_default_line(input logic [23:0] addr);
        logic [511:0] line;
        begin
            for (int w = 0; w < 8; w++) begin
                line[w*64 +: 64] = {32'hD00D_0000 | {8'h00, addr}, 28'h0, w[3:0]};
            end
            return line;
        end
    endfunction

    assign line_addr = req_addr_d[29:6];
    assign mem_idx = line_addr[MEM_ADDR_W-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_d <= 1'b0;
            req_addr_d <= '0;
            l2_resp_valid <= 1'b0;
            l2_resp_data <= '0;
            for (int i = 0; i < MEM_LINES; i++) begin
                line_valid[i] <= 1'b0;
                line_mem[i] <= '0;
            end
        end else begin
            req_d <= l2_req_valid;
            req_addr_d <= l2_req_addr;
            l2_resp_valid <= req_d;

            // Accept dirty write-back from L1 immediately
            if (wb_valid) begin
                line_mem[wb_addr[21:6]] <= wb_data;
                line_valid[wb_addr[21:6]] <= 1'b1;
            end

            if (req_d) begin
                if (!line_valid[mem_idx]) begin
                    line_mem[mem_idx] <= make_default_line(line_addr);
                    line_valid[mem_idx] <= 1'b1;
                    l2_resp_data <= make_default_line(line_addr);
                end else begin
                    l2_resp_data <= line_mem[mem_idx];
                end
            end
        end
    end
endmodule
