

module ddr3 (
    input logic clk,
    input logic rst_n,
    input logic        req_valid,
    input logic [29:0] req_addr,
    input logic        req_write,
    input logic [63:0] req_wdata,
    output logic        resp_valid,
    output logic [63:0] resp_rdata
);

temp ddr3_inst ( // Assume that if we call ddr3_inst, it will be connected to the actual DDR3 model 
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_addr(req_addr),
    .req_write(req_write),
    .req_wdata(req_wdata),
    .resp_valid(resp_valid),
    .resp_rdata(resp_rdata)
);
    
endmodule