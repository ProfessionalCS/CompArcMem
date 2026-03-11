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

module llcdTb(
	input logic clk,
	input logic rstN
);

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

	// Clock and reset are driven externally by the C++ harness

	int passCount;
	int failCount;

	function automatic logic [PADDR_WIDTH-1:0] makeAddr(
		input logic [L2_TAG_WIDTH-1:0] tag,
		input logic [L2_INDEX_WIDTH-1:0] index,
		input logic [OFFSET_WIDTH-1:0] offset
	);
		logic [PADDR_WIDTH-1:0] addr;
		addr = '0;
		addr[OFFSET_WIDTH-1:0] = offset;
		addr[OFFSET_WIDTH +: L2_INDEX_WIDTH] = index;
		addr[OFFSET_WIDTH + L2_INDEX_WIDTH +: L2_TAG_WIDTH] = tag;
		return addr;
	endfunction

	task automatic checkBool(
		input string name,
		input logic got,
		input logic exp
	);
		if (got !== exp) begin
			$display("FAIL [%s] got=%b expected=%b", name, got, exp);
			failCount++;
		end else begin
			$display("PASS [%s] val=%b", name, got);
			passCount++;
		end
	endtask

	task automatic checkVal64(
		input string name,
		input logic [63:0] got,
		input logic [63:0] exp
	);
		if (got !== exp) begin
			$display("FAIL [%s] got=0x%016h expected=0x%016h", name, got, exp);
			failCount++;
		end else begin
			$display("PASS [%s] val=0x%016h", name, got);
			passCount++;
		end
	endtask

	task automatic checkVal512(
		input string name,
		input logic [DATA_WIDTH-1:0] got,
		input logic [DATA_WIDTH-1:0] exp
	);
		if (got !== exp) begin
			$display("FAIL [%s] got=0x%0128h expected=0x%0128h", name, got, exp);
			failCount++;
		end else begin
			$display("PASS [%s]", name);
			passCount++;
		end
	endtask

	task automatic clearDutState();
		for (int s = 0; s < L2_SETS; s++) begin
			for (int w = 0; w < L2_WAYS; w++) begin
				dut.dataArray[s][w] = '0;
				dut.lineMd[s][w] = '{tag: '0, valid: 1'b0, dirty: 1'b0};
			end
			dut.plruBits[s] = '0;
		end
		for (int i = 0; i < L2_MSHR_COUNT; i++) begin
			dut.mshr[i].valid = 1'b0;
			dut.mshr[i].addr = '0;
			dut.mshr[i].tail = '0;
			for (int q = 0; q < L2_MSHR_QUEUE_SIZE; q++) begin
				dut.missQueues[i][q] = '{isWrite: 1'b0, writeData: '0};
			end
		end
	endtask

	task automatic doReset();
		@(negedge clk);
		// external reset driven by harness; do not assign rstN here
		l1ReqValid = 1'b0;
		l1ReqWrite = 1'b0;
		l1Addr = '0;
		l1DataIn = '0;
		memReadRespValid = 1'b0;
		memReadRespReady = 1'b0;
		repeat (3) @(posedge clk);
		clearDutState();
		@(negedge clk);
		// external reset driven by harness; do not assign rstN here
		@(posedge clk);
		#1;
	endtask

	task automatic driveL1Req(
		input logic reqWrite,
		input logic [PADDR_WIDTH-1:0] addr,
		input logic [BLOCK_SIZE-1:0] dataIn
	);
		@(negedge clk);
		l1ReqValid = 1'b1;
		l1ReqWrite = reqWrite;
		l1Addr = addr;
		l1DataIn = dataIn;
		@(posedge clk);
		#1;
		@(negedge clk);
		l1ReqValid = 1'b0;
		l1ReqWrite = 1'b0;
		l1Addr = '0;
		l1DataIn = '0;
		@(posedge clk);
		#1;
	endtask

	logic [PADDR_WIDTH-1:0] testAddr;
	logic [DATA_WIDTH-1:0] linePattern;
	logic [DATA_WIDTH-1:0] expectedWriteLine;
	logic [L2_INDEX_WIDTH-1:0] testIndex;
	logic [L2_TAG_WIDTH-1:0] testTag;

	initial begin
		passCount = 0;
		failCount = 0;
		doReset();

		$display("================= LLCD Testbench =================");

		// TC1: reset leaves response outputs deasserted.
		checkBool("TC1a_reset_l1RespValid_zero", l1RespValid, 1'b0);
		checkVal64("TC1b_reset_l1DataOut_zero", l1DataOut, 64'h0);

		// TC2: read hit returns the selected 64-bit chunk from a 512-bit line.
		testIndex = 4'h3;
		testTag = 20'h12ACE;
		testAddr = makeAddr(testTag, testIndex, 6'h08);
		linePattern = {
			64'h1111_2222_3333_4444,
			64'h5555_6666_7777_8888,
			64'h9999_AAAA_BBBB_CCCC,
			64'hDDDD_EEEE_FFFF_0001,
			64'h1357_9BDF_2468_ACE0,
			64'h0BAD_F00D_CAFE_BABE,
			64'h0123_4567_89AB_CDEF,
			64'hDEAD_BEEF_FEED_FACE
		};

		dut.lineMd[testIndex][1] = '{tag: testTag, valid: 1'b1, dirty: 1'b0};
		dut.dataArray[testIndex][1] = linePattern;

		driveL1Req(1'b0, testAddr, '0);
		checkBool("TC2a_read_hit_resp_valid", l1RespValid, 1'b1);
		checkVal64("TC2b_read_hit_data", l1DataOut, 64'h0123_4567_89AB_CDEF);

		// TC3: write hit updates line data and sets dirty bit.
		testAddr = makeAddr(testTag, testIndex, 6'h00);
		driveL1Req(1'b1, testAddr, 64'hCAFE_C0DE_DEAD_BEEF);
		expectedWriteLine = '0;
		expectedWriteLine[63:0] = 64'hCAFE_C0DE_DEAD_BEEF;

		checkBool("TC3a_write_hit_resp_valid", l1RespValid, 1'b1);
		checkVal512("TC3b_write_hit_data_array_updated", dut.dataArray[testIndex][1], expectedWriteLine);
		checkBool("TC3c_write_hit_dirty_set", dut.lineMd[testIndex][1].dirty, 1'b1);

		// TC4: first read miss allocates a new MSHR entry.
		testAddr = makeAddr(20'h0A5A5, 4'hC, 6'h00);
		driveL1Req(1'b0, testAddr, 64'h0);

		checkBool("TC4a_read_miss_allocates_mshr_valid", dut.mshr[0].valid, 1'b1);
		checkVal64("TC4b_read_miss_sets_mshr_block_addr",
			{34'b0, dut.mshr[0].addr[29:0]},
			{34'b0, {testAddr[29:6], 6'b0}}
		);
		checkVal64("TC4c_read_miss_tail_advances", {61'b0, dut.mshr[0].tail}, 64'd1);

		// TC5: second miss to same block coalesces into existing MSHR queue.
		driveL1Req(1'b1, testAddr, 64'hFACE_FEED_1234_5678);
		checkVal64("TC5a_same_block_mshr_tail_increments", {61'b0, dut.mshr[0].tail}, 64'd2);
		checkBool("TC5b_same_block_queued_as_write", dut.missQueues[0][1].isWrite, 1'b1);
		checkVal64("TC5c_same_block_queued_write_data", dut.missQueues[0][1].writeData, 64'hFACE_FEED_1234_5678);

		$display("\n==================================================");
		$display("%0d PASSED   %0d FAILED", passCount, failCount);
		if (failCount == 0) begin
			$display("ALL TESTS PASSED");
		end else begin
			$display("SOME TESTS FAILED, SEE FAILURES ABOVE");
		end
		$display("==================================================\n");
		$finish;
	end

	initial begin
		#1_000_000;
		$display("TIMEOUT");
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
