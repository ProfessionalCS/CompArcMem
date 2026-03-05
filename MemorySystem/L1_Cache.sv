`timescale 1ns/1ps
module L1(
 // L1: 512B, 2-way => 8 lines => 4 sets => index=2
  localparam int L1_WAYS = 2;
  localparam int L1_SETS = 4;
  localparam int L1_INDEX_BITS = 2;
  localparam int L1_TAG_BITS = PADDR_BITS - OFFSET_BITS - L1_INDEX_BITS; // 
  localparam int LINESIZE = 8 * 64;
)(
    input  logic        clk,
    input  logic        rst_n,

    //inputs
    input  logic        lookup_req_i, //I want to look up something 
    input  logic [47:0] lookup_vaddr_i, //Vitural Address 

    input logic [29:0] lookup_paddr_i, //Physical address to compare

    //|   Tag   | Index (2) | Offset (6) | 2 bits for index and 6 bits for offset

    output logic        lookup_hit_o, //If we had a hit or not
    output logic        data, //data we get from data Array
    
    input  logic         req_valid, //Val
    input  logic [47:0]  req_addr, // 
    input  logic         req_write, //Needs a right
    input  logic [63:0]  req_wdata, //Data to write too 

    output logic         resp_valid, 
    output logic [63:0]  resp_rdata, //

    // interface to L2
    output logic         l2_req_valid,
    output logic [47:0]  l2_req_addr,
    input  logic         l2_resp_valid,
    input  logic [511:0] l2_resp_data
    
);
// [511:0] data line 64B, [0:1] way and [0:3] set
logic [511:0] data_array [0:1][0:3]; 
logic [39:0]  tag_array  [0:1][0:3];
logic         valid_array[0:1][0:3];
logic         dirty_array[0:1][0:3];


// Tag comparison assume we got a tag fromt he TLB and are waiting so we can just brab the data


logic[47:0] grabbedTag;
logic[63:0] grabbedData;

logic [1:0] index; // set inde
assign index = lookup_vaddr_i[7:6];

logic [21:0] tag;
assign tag = lookup_paddr_i[29:8];

logic hit_way0, hit_way1;
assign hit_way0 = valid_array[0][index] && (tag_array[0][index] == tag);
assign hit_way1 = valid_array[1][index] && (tag_array[1][index] == tag);

assign lookup_hit_o = hit_way0|hit_way1;

// we have 2 mux if the tag matches the way 1 or way two 
always_ff @(posedge clk) begin : blockName
    if (!rst_n)begin // reset the thing
    end
    if (lookup_req_i && !req_wdata) begin 
        // It should be valid if its a read if its a write we have t
            if (hit_way0) begin
                    grabbedData = data_array[0][index][63:0]; // depends on offset logic
            end else if (hit_way1) begin
                    grabbedData = data_array[1][index][63:0];
            end
    end 
    
end

// the plan is to add write logic to the L1 we can assume that we have already done all the cleaning 
// assume no hazards and life is good 
always_ff @(posedge clk ) begin : write
    if (!rst_n)
    
end
    

endmodule