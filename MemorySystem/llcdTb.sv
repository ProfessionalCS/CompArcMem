`timescale 1ns/1ps
/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off IMPORTSTAR */
/* verilator lint_off SELRANGE */
/* verilator lint_off BLKSEQ */

import cacheDataTypes::*;

module llcdTb();
	logic clk;
	logic rstN;

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk; // 10ns period
	end

	initial begin
		rstN = 1'b0;
		#20;
		rstN = 1'b1;
	end

	logic l1ReqValid;
	logic l1ReqWrite;
	logic [PADDR_WIDTH-1:0] l1Addr;
	logic [BLOCK_SIZE-1:0] l1DataIn;
	logic [BLOCK_SIZE-1:0] l1DataOut;
	logic l1RespValid;

	logic memReadRespValid;
	logic memReadRespReady;
	tri [DATA_WIDTH-1:0] memData;
	logic [PADDR_WIDTH-1:0] memAddr;
	logic memWriteReqValid;

	llcd dut (
		.clk(clk),
		.rstN(rstN),
		.l1ReqValid(l1ReqValid),
		.l1ReqWrite(l1ReqWrite),
		.l1Addr(l1Addr),
		.l1DataIn(l1DataIn),
		.l1DataOut(l1DataOut),
		.l1RespValid(l1RespValid),
		.memReadRespValid(memReadRespValid),
		.memReadRespReady(memReadRespReady),
		.memData(memData),
		.memAddr(memAddr),
		.memWriteReqValid(memWriteReqValid)
	);

	// Simple mock memory and mock L1 instantiated in the testbench file
	mockMem #(.MEM_LINES(1024)) mockMem (
		.clk(clk),
		.rstN(rstN),
		.memData(memData),
		.memAddr(memAddr),
		.memWriteReqValid(memWriteReqValid),
		.memReadRespValid(memReadRespValid),
		.memReadRespReady(memReadRespReady)
	);

	mockL1 mockL1 (
		.clk(clk),
		.rstN(rstN),
		.l1ReqValid(l1ReqValid),
		.l1ReqWrite(l1ReqWrite),
		.l1Addr(l1Addr),
		.l1DataIn(l1DataIn),
		.l1DataOut(l1DataOut),
		.l1RespValid(l1RespValid)
	);

    // Simple stimulus for exercising LLCD behavior: misses, coalescing, and writes.
    initial begin
        // Wait for reset to be released by test harness
        wait (rstN == 1);
        @(posedge clk);

        // Initialize signals
        l1ReqValid = 1'b0;
        l1ReqWrite = 1'b0;
        l1Addr = '0;
        l1DataIn = '0;
        @(posedge clk);

        $display("[tb] Starting LLCD stimulus");

        // First read miss to address 0
        $display("[tb] READ miss addr=0");
        l1Addr = 0;
        l1ReqWrite = 1'b0;
        l1ReqValid = 1'b1;
        @(posedge clk);
        l1ReqValid = 1'b0;

        // Issue a coalesced read to the same block next cycle
        @(posedge clk);
        $display("[tb] Coalesced READ addr=0");
        l1Addr = 0;
        l1ReqValid = 1'b1;
        @(posedge clk);
        l1ReqValid = 1'b0;

        // Read another address to allocate a second MSHR
        @(posedge clk);
        $display("[tb] READ miss addr=64");
        l1Addr = 64;
        l1ReqValid = 1'b1;
        @(posedge clk);
        l1ReqValid = 1'b0;

        // Write to a different block (write miss)
        @(posedge clk);
        $display("[tb] WRITE miss addr=128");
        l1Addr = 128;
        l1DataIn = '0;
        l1DataIn[63:0] = 64'hDEADBEEFCAFEBABE;
        l1ReqWrite = 1'b1;
        l1ReqValid = 1'b1;
        @(posedge clk);
        l1ReqValid = 1'b0;
        l1ReqWrite = 1'b0;

        // Let things progress for a while so memory responses, fill and possible evictions occur
        repeat (50) @(posedge clk);

        $display("[tb] Finished stimulus - finishing simulation");
        $finish;
    end



endmodule: llcdTb /* verilator lint_off EOFNEWLINE */

// ------------------------------------------------------------------
// Mock memory: small behavioral memory to respond to L2 read requests
// and accept writebacks. Drives the tri-state `memData` bus during
// read responses and samples it during writes.
module mockMem #(parameter MEM_LINES = 1024)(
	input logic clk,
	input logic rstN,
	inout tri [DATA_WIDTH-1:0] memData,
	input logic [PADDR_WIDTH-1:0] memAddr,
	input logic memWriteReqValid,
	output logic memReadRespValid,
	output logic memReadRespReady
);
	localparam IDX_BITS = $clog2(MEM_LINES);
	logic [IDX_BITS-1:0] addrIdx;
	logic [DATA_WIDTH-1:0] storage [0:MEM_LINES-1];

	// internal control
	logic pendingRead;
	integer readDelay;

	always_comb begin
		addrIdx = memAddr[OFFSET_WIDTH +: IDX_BITS];
	end

	// memData driver for read responses
	assign memData = (memReadRespValid) ? storage[addrIdx] : {DATA_WIDTH{1'bz}};

	always_ff @(posedge clk) begin
		if (!rstN) begin
			memReadRespValid <= 1'b0;
			memReadRespReady <= 1'b0;
			pendingRead <= 1'b0;
			readDelay <= 0;
		end else begin
			// Handle writeback from cache
			if (memWriteReqValid) begin
				// sample write data (driven by cache on memData)
				storage[addrIdx] <= memData;
				// no read response while writeback ongoing
				memReadRespValid <= 1'b0;
				memReadRespReady <= 1'b0;
				pendingRead <= 1'b0;
			end else begin
				// If a read address is presented and no pending read, schedule a response
				if (!pendingRead && (memAddr != '0)) begin
					pendingRead <= 1'b1;
					readDelay <= 3; // some small latency
					memReadRespValid <= 1'b0;
					memReadRespReady <= 1'b0;
				end

				if (pendingRead) begin
					if (readDelay > 0) begin
						readDelay <= readDelay - 1;
					end else begin
						// Drive a single-cycle valid + ready so cache accepts data
						memReadRespValid <= 1'b1;
						memReadRespReady <= 1'b1;
						pendingRead <= 1'b0;
					end
				end else begin
					// default idle
					memReadRespValid <= 1'b0;
					memReadRespReady <= 1'b0;
				end
			end
			// Clear the response after being visible for one cycle
			if (memReadRespValid && memReadRespReady) begin
				memReadRespValid <= 1'b0;
				memReadRespReady <= 1'b0;
			end
		end
	end
endmodule: mockMem


// ------------------------------------------------------------------
// Mock L1: lightweight observer of requests sent toward the L2. The
// testbench still drives the request signals; this module simply
// prints debug info when requests arrive and observes responses.
module mockL1(
	input logic clk,
	input logic rstN,
	input logic l1ReqValid,
	input logic l1ReqWrite,
	input logic [PADDR_WIDTH-1:0] l1Addr,
	input logic [BLOCK_SIZE-1:0] l1DataIn,
	input logic [BLOCK_SIZE-1:0] l1DataOut,
	input logic l1RespValid
);
	always_ff @(posedge clk) begin
		if (!rstN) begin
		end else begin
			if (l1ReqValid) begin
				if (l1ReqWrite) begin
					$display("[mockL1] WRITE req addr=0x%08h", l1Addr);
				end else begin
					$display("[mockL1] READ req addr=0x%08h", l1Addr);
				end
			end
			if (l1RespValid) begin
				$display("[mockL1] RESP valid, data(63:0)=0x%016h", l1DataOut[63:0]);
			end
		end
	end
endmodule: mockL1
