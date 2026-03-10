`timescale 1ns/1ps

// struct mshr_entry {
//     logic        valid;          // entry allocated
//     logic [1:0]  way;            // victim way encoded
//     logic [1:0]  set;            // index to simplify refill write
//     logic [21:0] tag;            // match incoming fills
//     logic        is_store;       // 1 if original op was store
//     logic [63:0] store_data;     // pending store data (byte-masked)
//     logic [5:0]  byte_offset;    // which 64b beat the CPU asked for
//     logic        needs_writeback;// victim dirty
// };


module L1(
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
logic [511:0]   data_array  [0:1][0:3]; 
logic [21:0]    tag_array   [0:1][0:3];
logic           valid_array [0:1][0:3];
logic           dirty_array [0:1][0:3];
logic           lru_array   [0:3];


// Tag comparison assume we got a tag fromt he TLB and are waiting so we can just brab the data


logic[47:0] grabbedTag;

logic[63:0] grabbedData;


// We are doing the index nits 
logic [1:0] index; // set 
assign index = lookup_vaddr_i[7:6]; 

// Tag bits is the 22 bits 
logic [21:0] tag;
assign tag = lookup_paddr_i[29:8];

logic [5:0] offset;
assign offset = req_addr[5:0];


// we need to have 2 way associetive 
logic hit_way0, hit_way1;
assign hit_way0 = valid_array[0][index] && (tag_array[0][index] == tag); // this is 2 way associete 
assign hit_way1 = valid_array[1][index] && (tag_array[1][index] == tag);

assign lookup_hit_o = hit_way0|hit_way1;

logic tag_match;


// The MSHR we need to get the data and we need to handle the misses maybe we need to add this







//read logc 

// we have 2 mux if the tag matches the way 1 or way two 
always_ff @(posedge clk) begin : blockName
    if (!rst_n)begin // reset the thing
    end
    if (lookup_req_i && !req_write) begin // we got a request and its not a write 
        // It should be valid if its a read if its a write we have abother ff for it 
        if (lookup_hit_o) begin
            if (hit_way0 == 1) begin
                    if (valid_array[0][index] && tag_match == 1) begin
                        grabbedData <= data_array[0][index][63:0]; // depends on offset logic
                        tag_match <= tag_array[0][index] == tag;
                        lru_array[index] <= 1'b0; 
                    end
            end 
            else if (hit_way1 == 1) begin
                    if (valid_array[1][index] && tag_match == 1) begin
                        grabbedData <= data_array[1][index][63:0]; // depends on offset logic assume for rn that its the first 64 bits
                        tag_match <= tag_array[1][index] == tag;
                        lru_array[index] <= 1'b1; 
                    end
            end
        end 
        else begin // We missed 
            // okay its not in the queue so we must call L2

            // We have to put it in the MSHR


            
        end
    end 
    
end
// assign logic [1:0] selected_way = lru_array[index];

// the plan is to add write logic to the L1 we can assume that we have already done all the cleaning 
// assume no hazards and life is good // we just have to write data nothing big here we are given a adress and will follow the same way as the thing 

always_ff @(posedge clk ) begin : write // asume no evictions rn 
    if (!rst_n) // We are writting nothings to important rst never happens 
      for (int way = 0; way < 2; way++) // Clean house 
        for (int sets = 0; sets < 4; sets++)
            valid_array[way][sets] <= 1'b0;

    else if (req_valid && req_write) begin // we have a write request and its valid 
        //we need to write to a spot on data, write the dirty bit and and update the valid
        // nothing is there we just want something
        
        // Hit and we can just change the data or nothings in it
        if (lookup_hit_o) begin // We got a hit its real and we need to write to that spot
            if ((valid_array[0][index] && tag_array[0][index] == tag)) begin
                valid_array[0][index] <= 1;
                dirty_array[0][index] <= 1;
                data_array[0][index][offset*8 +: 64] <= req_wdata;
                lru_array[index] <= 1'b0; 
                
                // send data to L2 and make sure they write it
                resp_valid <= 1'b1;  // Write finished

            end
            else if (valid_array[1][index] && tag_array[1][index] == tag) begin
                valid_array[1][index] <= 1;
                dirty_array[1][index] <= 1;
                data_array[1][index][offset*8 +: 64] <= req_wdata;
                lru_array[index] <= 1'b1; 
                // Logic might be wrong 
                resp_valid <= 1'b1; //hbg
            end 
        end

        else begin  // okay so we fucked up and need to get from L2 
                    //we need to evict some loser or get data either way this is a MSHR
            // Lets get the data
            // get data from L2
            // call function to L2


            l2_req_valid <= 1'b1;
            l2_req_addr <= req_addr;    
            // wait till the data 
            if (l2_resp_valid) begin
                // L2 (or physical memory and beyond) has the data
                data_array[lru_array[index]][index][offset*8 +: 64] <= l2_resp_data[63:0];  // Always succeeds
                resp_valid <= 1'b1; 
            end

            // // lets do eviction foor
            // if (lru_array[index] == 0) begin: // way 0 was last used so evict 1
            // // Start the eviction process for 1 is just write the data we might need 
            // l2_resp_data 
            // end
            


        end 


    end
end       
endmodule 
