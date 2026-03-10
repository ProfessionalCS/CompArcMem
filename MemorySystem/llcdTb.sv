`timescale 1ns/1ps

import cacheDataTypes::*;

module llcdTb;
	logic clk, rstN;

	// L1 <-> LLCD signals
	logic l1ReqValid;
	logic l1ReqWrite;
	logic [L2_ADDR_WIDTH-1:0] l1Addr;
	logic [DATA_WIDTH-1:0] l1DataIn;
	logic [DATA_WIDTH-1:0] l1DataOut;
	logic l1RespValid;

	// Memory-controller side (currently unused by the LLCD hit-only implementation)
	logic memReadReqReady;
	logic memReadRespValid;
	logic memWriteReqReady;
	logic [DATA_WIDTH-1:0] memDataIn;
	logic [L2_ADDR_WIDTH-1:0] memAddr;
	logic [DATA_WIDTH-1:0] memDataOut;
	logic memReadReqValid;
	logic memReadRespReady;
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
		.memReadReqReady(memReadReqReady),
		.memReadRespValid(memReadRespValid),
		.memWriteReqReady(memWriteReqReady),
		.memDataIn(memDataIn),
		.memAddr(memAddr),
		.memDataOut(memDataOut),
		.memReadReqValid(memReadReqValid),
		.memReadRespReady(memReadRespReady),
		.memWriteReqValid(memWriteReqValid)
	);

	initial clk = 1'b0;
	always #5 clk = ~clk;

	int passCount, failCount;

	function automatic logic [L2_ADDR_WIDTH-1:0] makeAddr(
		input logic [L2_TAG_WIDTH-1:0] tag,
		input logic [L2_INDEX_WIDTH-1:0] idx,
		input logic [OFFSET_WIDTH-1:0] off
	);
		makeAddr = {tag, idx, off};
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

	task automatic checkVec512(
		input string name,
		input logic [DATA_WIDTH-1:0] got,
		input logic [DATA_WIDTH-1:0] exp
	);
		if (got !== exp) begin
			$display("FAIL [%s] got=%h expected=%h", name, got, exp);
			failCount++;
		end else begin
			$display("PASS [%s]", name);
			passCount++;
		end
	endtask

	task automatic doReset();
		@(negedge clk);
		rstN = 1'b0;
		l1ReqValid = 1'b0;
		l1ReqWrite = 1'b0;
		l1Addr = '0;
		l1DataIn = '0;
		repeat(3) @(posedge clk);
		@(negedge clk);
		rstN = 1'b1;
		@(posedge clk);
		#1;
	endtask

	task automatic preloadLine(
		input logic [L2_INDEX_WIDTH-1:0] idx,
		input logic [L2_WAY_WIDTH-1:0] way,
		input logic [L2_TAG_WIDTH-1:0] tag,
		input logic [DATA_WIDTH-1:0] data,
		input logic dirty
	);
		// Directly preloads LLCD state to test hit-path behavior before miss/MSHR is implemented.
		dut.lineMd[idx][way].valid = 1'b1;
		dut.lineMd[idx][way].dirty = dirty;
		dut.lineMd[idx][way].tag = tag;
		dut.dataArray[idx][way] = data;
	endtask

	task automatic invalidateSet(
		input logic [L2_INDEX_WIDTH-1:0] idx
	);
		for (int w = 0; w < L2_WAYS; w++) begin
			dut.lineMd[idx][w].valid = 1'b0;
			dut.lineMd[idx][w].dirty = 1'b0;
			dut.lineMd[idx][w].tag = '0;
			dut.dataArray[idx][w] = '0;
		end
		dut.plruBits[idx] = '0;
	endtask

	task automatic doRead(
		input logic [L2_ADDR_WIDTH-1:0] addr,
		output logic resp,
		output logic [DATA_WIDTH-1:0] data
	);
		@(negedge clk);
		l1ReqValid = 1'b1;
		l1ReqWrite = 1'b0;
		l1Addr = addr;
		l1DataIn = '0;
		@(posedge clk);
		#1;
		resp = l1RespValid;
		data = l1DataOut;
		@(negedge clk);
		l1ReqValid = 1'b0;
		l1ReqWrite = 1'b0;
		l1Addr = '0;
		@(posedge clk);
		#1;
	endtask

	task automatic doWrite(
		input logic [L2_ADDR_WIDTH-1:0] addr,
		input logic [DATA_WIDTH-1:0] data,
		output logic resp
	);
		@(negedge clk);
		l1ReqValid = 1'b1;
		l1ReqWrite = 1'b1;
		l1Addr = addr;
		l1DataIn = data;
		@(posedge clk);
		#1;
		resp = l1RespValid;
		@(negedge clk);
		l1ReqValid = 1'b0;
		l1ReqWrite = 1'b0;
		l1Addr = '0;
		l1DataIn = '0;
		@(posedge clk);
		#1;
	endtask

	logic rdResp;
	logic wrResp;
	logic [DATA_WIDTH-1:0] rdData;
	logic [DATA_WIDTH-1:0] initData;
	logic [DATA_WIDTH-1:0] wrData;
	logic [L2_ADDR_WIDTH-1:0] addrHit;
	logic [L2_ADDR_WIDTH-1:0] addrMiss;

	initial begin
		passCount = 0;
		failCount = 0;

		// Memory-side interface is idle in this revision of LLCD.
		memReadReqReady = 1'b1;
		memReadRespValid = 1'b0;
		memWriteReqReady = 1'b1;
		memDataIn = '0;

		do_reset();
		$display("================= LLCD Testbench =================");

		// ------------------------------------------------------------------
		// TC1: reset defaults outputs to zero
		// ------------------------------------------------------------------
		$display("\nTC1: reset defaults");
		check_bool("TC1a_l1RespValid_after_reset", l1RespValid, 1'b0);
		check_vec512("TC1b_l1DataOut_after_reset", l1DataOut, '0);

		// ------------------------------------------------------------------
		// TC2: read hit returns cached line and resp valid
		// ------------------------------------------------------------------
		$display("\nTC2: read hit");
		addrHit = makeAddr(L2_TAG_WIDTH'(20'h155AA), L2_INDEX_WIDTH'(4'd3), OFFSET_WIDTH'(6'd0));
		initData = {8{64'h1111_2222_3333_4444}};
		invalidateSet(L2_INDEX_WIDTH'(4'd3));
		preloadLine(L2_INDEX_WIDTH'(4'd3), L2_WAY_WIDTH'(2'd1), L2_TAG_WIDTH'(20'h155AA), initData, 1'b0);
		doRead(addrHit, rdResp, rdData);
		checkBool("TC2a_resp_valid_on_read_hit", rdResp, 1'b1);
		checkVec512("TC2b_data_matches_read_hit", rdData, initData);

		// ------------------------------------------------------------------
		// TC3: read miss returns no response and zero data
		// ------------------------------------------------------------------
		$display("\nTC3: read miss");
		addrMiss = makeAddr(L2_TAG_WIDTH'(20'h0BAD0), L2_INDEX_WIDTH'(4'd3), OFFSET_WIDTH'(6'd0));
		doRead(addrMiss, rdResp, rdData);
		checkBool("TC3a_resp_low_on_read_miss", rdResp, 1'b0);
		checkVec512("TC3b_data_zero_on_read_miss", rdData, '0);

		// ------------------------------------------------------------------
		// TC4: write hit updates line and marks it dirty
		// ------------------------------------------------------------------
		$display("\nTC4: write hit updates line");
		wrData = {8{64'hA5A5_A5A5_5A5A_5A5A}};
		doWrite(addrHit, wrData, wrResp);
		checkBool("TC4a_resp_valid_on_write_hit", wrResp, 1'b1);
		checkBool("TC4b_dirty_set_after_write_hit", dut.lineMd[L2_INDEX_WIDTH'(4'd3)][L2_WAY_WIDTH'(2'd1)].dirty, 1'b1);
		doRead(addrHit, rdResp, rdData);
		checkBool("TC4c_resp_valid_after_write_readback", rdResp, 1'b1);
		checkVec512("TC4d_readback_matches_write_data", rdData, wrData);

		// ------------------------------------------------------------------
		// TC5: write miss does not alter existing cached hit line
		// ------------------------------------------------------------------
		$display("\nTC5: write miss");
		doWrite(addrMiss, {8{64'hDEAD_BEEF_F00D_CAFE}}, wrResp);
		checkBool("TC5a_resp_low_on_write_miss", wrResp, 1'b0);
		doRead(addrHit, rdResp, rdData);
		checkBool("TC5b_hit_line_still_readable", rdResp, 1'b1);
		checkVec512("TC5c_hit_line_unchanged_by_miss", rdData, wrData);

		$display("\n===================================================");
		$display("%0d PASSED   %0d FAILED", passCount, failCount);
		if (failCount == 0) begin
			$display("ALL TESTS PASSED");
		end else begin
			$display("SOME TESTS FAILED, SEE LOGS ABOVE");
		end
		$display("===================================================\n");
		$finish;
	end

	initial begin
		#1_000_000;
		$display("TIMEOUT");
		$finish;
	end

endmodule: llcdTb /* verilator lint_off EOFNEWLINE */