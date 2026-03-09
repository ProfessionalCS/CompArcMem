/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHTRUNC */
`timescale 1ns/1ps

// Dummy $L1 (for TB for LSQ)
// Inputs:
//     cache_req        request enable (load or store)
//     cache_we         0 = load, 1 = store
//     cache_paddr      30b physical address from TLB
//     cache_wdata      64b write data (stores only)
// Outputs:
//     cache_ready      always 1 (assume this for now)
//     cache_valid      pulses high exactly 2 cycles after a load is accepted
//     cache_data       the 64b data returned to the LSQ (loads)
// Storage is 64 bits
// Indexed by paddr[29:3]
// Bottom 4 bits are offset
//      Byte offset inside the word
// Non-blocking write-back (stores)
// 2 cycle latency

module dummy_$L1 #(
    parameter int MEM_WORDS = 1024 // Assume smaller size for memory
) (
    input logic clk,
    input logic rst_n,

    input logic cache_req,
    input logic cache_we,
    input logic [29:0] cache_paddr,
    input logic [63:0] cache_wdata,

    output logic cache_ready,
    output logic cache_ret_valid,
    output logic [63:0] cache_ret_data
);
    logic [63:0] mem [MEM_WORDS];

    // Assume always ready
    assign cache_ready = 1'b1;

    // Pipeline to emulate the 2 cycle latency (not really how the $L1 behaves)
    logic stage1_valid, stage2_valid;
    logic [63:0] stage1_data, stage2_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear pipeline
            stage1_valid <= 1'b0;
            stage2_valid <= 1'b0;
            stage1_data <= '0;
            stage2_data <= '0;
            cache_ret_valid <= 1'b0;
            cache_ret_data <= '0;

            for (int i = 0; i < MEM_WORDS; i++)
                mem[i] <= '0;

        end else begin
            stage2_valid <= stage1_valid;
            stage2_data <= stage1_data;
            cache_ret_valid <= stage2_valid;
            cache_ret_data <= stage2_data;

            // No new load at stage 1
            stage1_valid <= 1'b0;
            stage1_data  <= '0;

            // Incoming request
            if (cache_req) begin
                // Word index into our array (bottom 4 bits = byte offset)
                logic [26:0] widx = cache_paddr[29:3] % MEM_WORDS[26:0];

                if (cache_we) begin
                    // Store
                    mem[widx] <= cache_wdata;
                
                end else begin
                    // Load
                    stage1_valid <= 1'b1;
                    stage1_data  <= mem[widx];
                end
            end
        end
    end

endmodule