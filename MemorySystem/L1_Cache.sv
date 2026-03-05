`timescale 1ns/1ps
module L1(
    input  logic        clk,
    input  logic        rst_n,

    //inputs
    input  logic        lookup_req_i, //I want to look up something 
    input  logic [47:0] lookup_vaddr_i, //Vitural Address 

    input logic [29:0] lookup_paddr_i, //Physical address to compare

    //|   Tag   | Index (2) | Offset (6) | 2 bits for index and 6 bits for offset

    output logic        lookup_hit_o, //If we had a hit or not
    output logic        data, //data we get from data Array

    input  logic         clk, // clock
    input  logic         req_valid, //Val
    input  logic [47:0]  req_addr, // 
    input  logic         req_write, //Needs a right
    input  logic [63:0]  req_wdata, //Data to write too 

    output logic         resp_valid, 
    output logic [63:0]  resp_rdata,

    // interface to L2
    output logic         l2_req_valid,
    output logic [47:0]  l2_req_addr,
    input  logic         l2_resp_valid,
    input  logic [511:0] l2_resp_data
    
);
logic [511:0] data_array [0:1][0:3];
logic [39:0]  tag_array  [0:1][0:3];
logic         valid_array[0:1][0:3];
logic         dirty_array[0:1][0:3];

endmodule