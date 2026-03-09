`timescale 1ns/1ps
module L1(
 // L1: 512B, 2-way => 8 lines => 4 sets => index=2
  localparam int L1_WAYS = 2;
  localparam int L1_SETS = 4;
  localparam int L1_INDEX_BITS = 2;
  localparam int L1_TAG_BITS = PADDR_BITS - OFFSET_BITS - L1_INDEX_BITS; // 
  localparam int LINESIZE = 8 * 64;
)(
    // Cloc
input  logic        clk,                      
input  logic        rst_n,                    

// TLB
input  logic        lookup_req_i,             // Trigger: address translation request incoming
input  logic [47:0] lookup_vaddr_i,           // Virtual address needing translation
input  logic [29:0] lookup_paddr_i,           // Physical address result from TLB
output logic        lookup_hit_o,             // 1=Hit (valid+match), 0=Miss (goes L2)

//  response 
input  logic         req_valid,               // memory operation request arriving
input  logic [29:0]  req_addr,                // Physical address for read/write
input  logic         req_write,               // 1=Store, 0=Load operation
input  logic [63:0]  req_wdata,               // Eight bytes of data to write
output logic         resp_valid,              // Data ready: read response or write ack
output logic [63:0]  resp_rdata,              // Eight-byte result from read hit

//L2 
output logic         l2_req_valid,            // Signal: requesting cache line from L2
output logic [29:0]  l2_req_addr,             // Address of line needed from L2
input  logic         l2_resp_valid,           // L2 response ready with cache line
input  logic [511:0] l2_resp_data             // Full 64-byte cache line from L2
    
);
// [511:0] data line 64B, [0:1] way and [0:3] set
logic [511:0] data_array [0:1][0:3]; 
logic [39:0]  tag_array  [0:1][0:3];
logic         valid_array[0:1][0:3];
logic         dirty_array[0:1][0:3];


// Tag comparison assume we got a tag fromt he TLB and are waiting so we can just brab the data


logic[47:0] grabbedTag;

logic[63:0] grabbedData;


// We are doing the index nits 
logic [1:0] index; // set 
assign index = lookup_vaddr_i[7:6]; 

// Tag bits is the 22 bits 
logic [21:0];
assign tag = lookup_paddr_i[29:8];

// offset 
offset[5:0] = req_addr[5:0]


// we need to have 2 way associetive 
logic hit_way0, hit_way1;
assign hit_way0 = valid_array[0][index] && (tag_array[0][index] == tag); // this is 2 way associete 
assign hit_way1 = valid_array[1][index] && (tag_array[1][index] == tag);

assign lookup_hit_o = hit_way0|hit_way1;

logic tag_match;
assign hit = 
//read logc 
// we have 2 mux if the tag matches the way 1 or way two 
 @(posedge clk) begin : blockName
    if (!rst_n)begin // reset the thing
    end
    if (lookup_req_i && !req_wdata) begin // we got a request and its not a write 
        // It should be valid if its a read if its a write we have abother ff for it 
            if (hit_way0) begin
                    if (valid_array[0][index] && tag_match == 1)begin:
                        grabbedData = data_array[0][index][63:0]; // depends on offset logic
                        tag_match = tag_array[0][index] == tag;
                    end
                    

            end else if (hit_way1) begin
                     if (valid_array[1][index] && tag_match == 1)begin:
                        grabbedData = data_array[1][index][63:0]; // depends on offset logic assume for rn that its the first 64 bits
                        tag_match = tag_array[1][index] == tag;
                    end
            end

            if (tag_match)
    end 
    
end


// the plan is to add write logic to the L1 we can assume that we have already done all the cleaning 
// assume no hazards and life is good // we just have to write data nothing big here we are given a adress and will follow the same way as the thing 

always_ff @(posedge clk ) begin : write // asume no evictions rn 
    if (!rst_n) // We are writting nothings to important rst never happens 

    if (req_valid && req_write) begin // we have a write request and its valid 
        //we need to write to a spot on data, write the dirty bit and and update the valid
        // nothing is there we just want something
        if ((valid_array[0][index] && tag_array[0][index] == tag) || valid_array[0][index] == 0) begin
            tag_array[0][index] =  tag;
            valid_array[0][index] = 1;
            dirty_array[0][index] = 1;
            data_array[0][index][offset*8 +: 64] = req_wdata;

        end
        else if ((valid_array[1][index] && tag_array[1][index] == tag) || valid_array[1][index] == 0) begin
            tag_array[1][index] =  tag;
            valid_array[1][index] = 1;
            dirty_array[1][index] = 1;
            data_array[1][index][offset*8 +: 64] = req_wdata;
        end 


    end




    
end       
endmodule 