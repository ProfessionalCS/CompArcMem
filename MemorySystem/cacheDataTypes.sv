`timescale 1ns/1ps

package cacheDataTypes;
	localparam int L2_CAPACITY = 4096;
	localparam int BLOCK_SIZE = 64;
	localparam int L2_WAYS = 4;
	localparam int L2_SETS = 16;
	localparam int L2_MSHR_COUNT = 4;
	localparam int L2_WAY_WIDTH = $clog2(L2_WAYS);
	localparam int L2_ADDR_WIDTH = 30; // 1 GB address space
	localparam int DATA_WIDTH = 512;
	localparam int OFFSET_WIDTH = $clog2(BLOCK_SIZE);
	localparam int L2_INDEX_WIDTH = $clog2(L2_SETS);
	localparam int L2_TAG_WIDTH = L2_ADDR_WIDTH - OFFSET_WIDTH - L2_INDEX_WIDTH;

	// typedef struct packed {
	// 	logic valid;
	// 	logic [ADDR_WIDTH-1:0] blockAddr;
	// 	logic isWrite;
	// 	logic [DATA_WIDTH-1:0] wdata;
	// } mshrEntry;

	typedef struct packed {
		logic [L2_TAG_WIDTH-1:0] tag;
		logic valid;
		logic dirty;
	} l2LineMetadata; // Metadata for each cache line

endpackage: cacheDataTypes /* verilator lint_off EOFNEWLINE */