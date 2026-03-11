/* verilator lint_off EOFNEWLINE */
`timescale 1ns/1ps

// Dummy L2: accepts line requests and always returns a zeroed cache line.
// No storage, no write handling, no backpressure.
module dummy_L2 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         l2_req_valid,
    input  logic [29:0]  l2_req_addr,
    output logic         l2_resp_valid,
    output logic [511:0] l2_resp_data
);
    logic req_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_d <= 1'b0;
            l2_resp_valid <= 1'b0;
        end else begin
            req_d <= l2_req_valid;
            l2_resp_valid <= req_d;
        end
    end

    // Always return zero data for every response.
    assign l2_resp_data = '0;

    // Keep request address referenced so lint does not flag drift.
    logic _unused_req_addr;
    assign _unused_req_addr = ^l2_req_addr;
endmodule
