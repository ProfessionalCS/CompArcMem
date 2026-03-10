`timescale 1ns/1ps

import cacheDataTypes::*;

// 4 KiB capacity, 64 B block size, 4-way set associative, 16 sets
module llcd(
	input logic clk,
	input logic rstN,


	/** Interface to L1 cache **/
	input logic l1ReqValid, // l2_req_valid from l1
	input logic l1ReqWrite, // 1=write request, 0=read request
	input logic [ADDR_WIDTH-1:0] l1Addr, // l2_req_addr from l1
	input logic [DATA_WIDTH-1:0] l1DataIn,
	output logic [DATA_WIDTH-1:0] l1DataOut, // Response/backpropagated line to L1
	output logic l1RespValid, // l2_resp_valid to l1

	/** Interface to memory controller **/
	input logic memReadReqReady,
	input logic memReadRespValid,
	input logic memWriteReqReady,
	input logic [DATA_WIDTH-1:0] memDataIn, // Data read from memory
	output logic [ADDR_WIDTH-1:0] memAddr,
	output logic [DATA_WIDTH-1:0] memDataOut, // Data to write to memory
	output logic memReadReqValid,
	output logic memReadRespReady,
	output logic memWriteReqValid
);


	logic [DATA_WIDTH-1:0] dataArray [SETS-1:0][WAYS-1:0];
	lineMetadata lineMd [SETS-1:0][WAYS-1:0];
	// mshrEntry mshrEntries [MSHR_COUNT-1:0];

	// Extract index and tag from the address
	logic [INDEX_WIDTH-1:0] index;
	logic [TAG_WIDTH-1:0] tag;
	logic [OFFSET_WIDTH-1:0] blockOffset;
	always_comb begin
		index = l1Addr[OFFSET_WIDTH +: INDEX_WIDTH];
		tag = l1Addr[OFFSET_WIDTH + INDEX_WIDTH +: TAG_WIDTH];
		blockOffset = l1Addr[0 +: OFFSET_WIDTH];
	end


	// Tag matching
	logic [WAYS-1:0] hitVec; // Vector indicating which way hits (if any)
	logic cacheHit;
	logic [WAY_WIDTH-1:0] hitWay; // Encoded way index of the hit
	always_comb begin
		for (int w = 0; w < WAYS; w++) begin
			hitVec[w] = lineMd[index][w].valid && (lineMd[index][w].tag == tag);
		end
	end

	assign cacheHit = |hitVec;
	always_comb begin
		hitWay = '0;
		for (int w = 0; w < WAYS; w++) begin
			if (hitVec[w]) hitWay = WAY_WIDTH'(w);
		end
	end

	// Miss/MSHR stuff, todo later
	// logic missDetected;
	// logic mshrFree;
	// logic [WAY_WIDTH-1:0] mshrFreeIdx;
	// always_comb begin
	// 	missDetected = l1ReqValid && !cacheHit;
	// 	mshrFree = 1'b0;
	// 	mshrFreeIdx = '0;
	// 	for (int m = 0; m < MSHR_COUNT; m++) begin
	// 		if (!mshrEntries[m].valid && !mshrFree) begin
	// 			mshrFree = 1'b1;
	// 			mshrFreeIdx = WAY_WIDTH'(m);
	// 		end
	// 	end
	// end

	// Hit response + inclusivity backpropagation to L1.
	always_comb begin
		l1RespValid = l1ReqValid && cacheHit;
		l1DataOut = '0;
		if (cacheHit) begin
			if (l1ReqWrite) begin
				// Backpropagate updated line to L1 on write hits.
				l1DataOut = l1DataIn;
			end else begin
				l1DataOut = dataArray[index][hitWay];
			end
		end
	end


	always_comb begin
		memAddr = '0;
		memDataOut = '0;
		memReadReqValid = 1'b0;
		memReadRespReady = 1'b0;
		memWriteReqValid = 1'b0;

		// Placeholder references to avoid accidental unused-interface drift while
		// miss logic is under construction.
		if (memReadReqReady || memReadRespValid || memWriteReqReady || (|memDataIn)) begin
			memAddr = '0;
		end
	end

	always_ff @(posedge clk or negedge rstN) begin
		if (!rstN) begin
			for (int s = 0; s < SETS; s++) begin
				for (int w = 0; w < WAYS; w++) begin
					dataArray[s][w] <= '0;
					lineMd[s][w] <= '0;
				end
			end

			// for (int m = 0; m < MSHR_COUNT; m++) begin
			// 	mshrEntries[m] <= '0;
			// end
		end else begin
			if (l1ReqValid && cacheHit) begin
				if (l1ReqWrite) begin
					dataArray[index][hitWay] <= l1DataIn;
					lineMd[index][hitWay].dirty <= 1'b1;
				end

				lineMd[index][hitWay].valid <= 1'b1;
				lineMd[index][hitWay].tag <= tag;

				for (int w = 0; w < WAYS; w++) begin
					if (w == hitWay) begin
						lineMd[index][w].mruBits <= 2'd3;
					end else if (lineMd[index][w].mruBits != 2'd0) begin
						lineMd[index][w].mruBits <= lineMd[index][w].mruBits - 2'd1;
					end
				end
			end

			// if (missDetected && mshrFree) begin
			// 	mshrEntries[mshrFreeIdx].valid <= 1'b1;
			// 	mshrEntries[mshrFreeIdx].blockAddr <= {
			// 		l1Addr[ADDR_WIDTH-1:OFFSET_WIDTH],
			// 		{OFFSET_WIDTH{1'b0}}
			// 	};
			// 	mshrEntries[mshrFreeIdx].isWrite <= l1ReqWrite;
			// 	mshrEntries[mshrFreeIdx].wdata <= l1DataIn;
			// end
		end
	end

	logic _unused_blockOffset;
	assign _unused_blockOffset = ^blockOffset;

endmodule: llcd /* verilator lint_off EOFNEWLINE */

// TODO: Ignore MSHR for now
// module mshrQueue #(
// 	parameter QUEUE_SIZE = 4
// )(
// 	input logic clk,
// 	input logic rstN,


// );

// endmodule: mshrQueue