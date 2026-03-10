`timescale 1ns/1ps

import cacheDataTypes::*;

// 4 KiB capacity, 64 B block size, 4-way set associative, 16 L2_sets
module llcd(
	input logic clk,
	input logic rstN,


	/** Interface to L1 cache **/
	input logic l1ReqValid, // l2_req_valid from l1
	input logic l1ReqWrite, // 1=write request, 0=read request
	input logic [L2_ADDR_WIDTH-1:0] l1Addr, // l2_req_addr from l1, address sent by l1
	input logic [DATA_WIDTH-1:0] l1DataIn,
	output logic [DATA_WIDTH-1:0] l1DataOut, // l2_resp_data from l1, data going into l1
	output logic l1RespValid, // l2_resp_valid from l1

	/** Interface to memory controller **/
	input logic memReadReqReady,
	input logic memReadRespValid,
	input logic memWriteReqReady,
	input logic [DATA_WIDTH-1:0] memDataIn, // Data read from memory
	output logic [L2_ADDR_WIDTH-1:0] memAddr,
	output logic [DATA_WIDTH-1:0] memDataOut, // Data to write to memory
	output logic memReadReqValid,
	output logic memReadRespReady,
	output logic memWriteReqValid
);


	logic [DATA_WIDTH-1:0] dataArray [L2_SETS-1:0][L2_WAYS-1:0];
	l2LineMetadata lineMd [L2_SETS-1:0][L2_WAYS-1:0];

	// Using PLRU for replacement
	// Need A-1 bits per set
	logic [L2_WAYS-2:0] plruBits [L2_SETS-1:0];

	l2_mshr_t mshr[L2_MSHR_COUNT];
	l2_mshr_miss_t missQueues[L2_MSHR_COUNT][L2_MSHR_QUEUE_SIZE];

	// Extract index and tag from the address
	logic [L2_INDEX_WIDTH-1:0] index;
	logic [L2_TAG_WIDTH-1:0] tag;
	logic [OFFSET_WIDTH-1:0] blockOffset;
	always_comb begin
		index = l1Addr[OFFSET_WIDTH +: L2_INDEX_WIDTH];
		tag = l1Addr[OFFSET_WIDTH + L2_INDEX_WIDTH +: L2_TAG_WIDTH];
		blockOffset = l1Addr[0 +: OFFSET_WIDTH];
	end


	// Tag matching
	logic [L2_WAYS-1:0] hitVec; // Vector indicating which way hits (if any)
	logic cacheHit;
	logic [L2_WAY_WIDTH-1:0] hitWay; // Encoded way index of the hit
	always_comb begin
		for (int w = 0; w < L2_WAYS; w++) begin
			hitVec[w] = lineMd[index][w].valid && (lineMd[index][w].tag == tag);
		end
	end

	assign cacheHit = |hitVec;
	always_comb begin
		hitWay = '0;
		for (int w = 0; w < L2_WAYS; w++) begin
			if (hitVec[w]) hitWay = L2_WAY_WIDTH'(w);
		end
	end

	// Miss/MSHR stuff, todo later


	// Herein assume a hit was made

	// Handle reads:
	always_ff @(posedge clk) begin
		if (!rstN) begin
			l1DataOut <= '0;
			l1RespValid <= 1'b0;
		end else if (l1ReqValid && !l1ReqWrite) begin // Read request
			if (cacheHit) begin
				l1DataOut <= dataArray[index][hitWay];
				l1RespValid <= 1'b1;

				// Update PLRU bits for this set
				if (hitWay < 2) begin
					plruBits[index][0] <= (hitWay == 0) ? 1'b1 : 1'b0;
				end else begin
					plruBits[index][1] <= (hitWay == 2) ? 1'b1 : 1'b0;
				end
				plruBits[index][2] <= (hitWay < 2) ? 1'b1 : 1'b0;

			end else begin
				l1DataOut <= '0;
				l1RespValid <= 1'b0;
			end
		end else begin
			l1DataOut <= '0;
			l1RespValid <= 1'b0;
		end
	end

	// Maybe later use write-back buffer???

	// Handle writes
	// For now, just write directly to the cache on a hit. No write buffer.
	always_ff @(posedge clk) begin
		if (!rstN) begin
			// Reset logic if needed
		end else if (l1ReqValid && l1ReqWrite) begin // Write request
			if (cacheHit) begin
				dataArray[index][hitWay] <= l1DataIn;
				lineMd[index][hitWay].dirty <= 1'b1; // Mark line as dirty on write
				l1RespValid <= 1'b1;
				// Update PLRU bits for this set
				if (hitWay < 2) begin
					plruBits[index][0] <= (hitWay == 0) ? 1'b1 : 1'b0;
				end else begin
					plruBits[index][1] <= (hitWay == 2) ? 1'b1 : 1'b0;
				end
				plruBits[index][2] <= (hitWay < 2) ? 1'b1 : 1'b0;
			end else begin
				l1RespValid <= 1'b0;
			end
		end else begin
			l1RespValid <= 1'b0;
		end
	end



endmodule: llcd /* verilator lint_off EOFNEWLINE */