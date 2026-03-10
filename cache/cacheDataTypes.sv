`timescale 1ns/1ps

package cacheDataTypes;
	localparam int CAPACITY = 4096;
	localparam int BLOCK_SIZE = 64;
	localparam int WAYS = 4;
	localparam int SETS = 16;
	localparam int MSHR_COUNT = 4;
	localparam int WAY_WIDTH = $clog2(WAYS);
	localparam int ADDR_WIDTH = 30; // 1 GB address space
	localparam int DATA_WIDTH = 512;
	localparam int OFFSET_WIDTH = $clog2(BLOCK_SIZE);
	localparam int INDEX_WIDTH = $clog2(SETS);
	localparam int TAG_WIDTH = ADDR_WIDTH - OFFSET_WIDTH - INDEX_WIDTH;

	// typedef struct packed {
	// 	logic valid;
	// 	logic [ADDR_WIDTH-1:0] blockAddr;
	// 	logic isWrite;
	// 	logic [DATA_WIDTH-1:0] wdata;
	// } mshrEntry;

	typedef struct packed {
		logic [TAG_WIDTH-1:0] tag;
		logic valid;
		logic dirty;
		logic [1:0] mruBits; // For 4-way, we need 2 bits to track MRU status
	} lineMetadata; // Metadata for each cache line

endpackage: cacheDataTypes /* verilator lint_off EOFNEWLINE */