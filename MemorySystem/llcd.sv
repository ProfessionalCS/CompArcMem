`timescale 1ns/1ps

import cacheDataTypes::*;

// 4 KiB capacity, 64 B block size, 4-way set associative, 16 sets
module llcd(
	input logic clk,
	input logic rstN,


	/** Interface to L1 cache **/
	input logic l1ReqValid, // l2_req_valid from l1, signal that l1 is making a request
	input logic l1ReqWrite, // 1=write request, 0=read request
	input logic [PADDR_WIDTH-1:0] l1Addr, // l2_req_addr from l1, address sent by l1
	input logic [BLOCK_SIZE-1:0] l1DataIn,
	output logic [BLOCK_SIZE-1:0] l1DataOut, // l2_resp_data from l1, data going into l1
	output logic l1RespValid, // l2_resp_valid from l1, signal that l2 response is valid and can be accepted by l1

	/** Interface to memory controller **/
	input logic memReadRespValid, // Memory data is valid to read
	input logic memReadRespReady, // Cache is ready to accept memory data
	inout logic [DATA_WIDTH-1:0] memData, // Bidirectional data bus for memory
	output logic [PADDR_WIDTH-1:0] memAddr, // Address
	output logic memWriteReqValid, // Data on bus is for a valid write request
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

	// Get the MSHR that matches the current miss address (if any)
	// If none, find the first free MSHR
	logic mshrHit;
	logic [$clog2(L2_MSHR_COUNT)-1:0] mshrIndex;
	always_comb begin
		mshrHit = 1'b0;
		mshrIndex = '0;
		for (int i = 0; i < L2_MSHR_COUNT; i++) begin
			if (mshr[i].valid && (mshr[i].blockAddr == l1Addr[29:6])) begin
				mshrHit = 1'b1;
				mshrIndex = i;
			end
		end
	end


	// Handle reads:
	always_ff @(posedge clk) begin
		if (!rstN) begin
			l1DataOut <= '0;
			l1RespValid <= 1'b0;
		end else if (l1ReqValid && !l1ReqWrite) begin // Read request
			if (cacheHit) begin
				l1DataOut <= dataArray[index][hitWay][blockOffset*8 +: BLOCK_SIZE]; // Extract the correct block based on offset
				l1RespValid <= 1'b1;

				// Update PLRU bits for this set
				if (hitWay < 2) begin
					plruBits[index][0] <= (hitWay == 0) ? 1'b1 : 1'b0;
				end else begin
					plruBits[index][1] <= (hitWay == 2) ? 1'b1 : 1'b0;
				end
				plruBits[index][2] <= (hitWay < 2) ? 1'b1 : 1'b0;

			end else begin
				// Read miss
				// If MSHR already tracking this miss, just add to its queue
				// Else, find a free MSHR and allocate it for this miss
				if (mshrHit) begin
					missQueues[mshrIndex][mshr[mshrIndex].tail] <= '{l1ReqWrite, l1DataIn}; // Store whether it's a write and the data (if it's a write)
					mshr[mshrIndex].tail <= mshr[mshrIndex].tail + 1;
				end else begin
					// Find a free MSHR
					logic foundFreeMshr = 1'b0;
					for (int i = 0; i < L2_MSHR_COUNT; i++) begin
						if (!mshr[i].valid && !foundFreeMshr) begin
							mshr[i].valid <= 1'b1;
							mshr[i].blockAddr <= l1Addr[29:6]; // Store block-aligned address
							mshr[i].tail <= 0;
							missQueues[i][0] <= '{l1ReqWrite, l1DataIn}; // Store the first miss in the queue
							mshr[i].tail <= 1;
							foundFreeMshr = 1'b1;
						end
					end
					// If no free MSHR, either drop the request or stall until one is free. For now, just drop it.
					if (!foundFreeMshr) begin
						// Drop request (could also set a flag to retry later)
						l1RespValid <= 1'b0;
					end
				end
			end
		end else begin
			l1DataOut <= '0;
			l1RespValid <= 1'b0;
		end
	end

	// Handle writes
	always_ff @(posedge clk) begin
		if (!rstN) begin
		end else if (l1ReqValid && l1ReqWrite) begin // Write request
			if (cacheHit) begin
				dataArray[index][hitWay] <= l1DataIn;
				lineMd[index][hitWay].dirty <= 1'b1; // Mark line as dirty on write
				l1RespValid <= 1'b1;
				// Update PLRU bits for this set
				// FIXME: Make it dynamic (do not hardcode for 4-way)
				if (hitWay < 2) begin
					plruBits[index][0] <= (hitWay == 0) ? 1'b1 : 1'b0;
				end else begin
					plruBits[index][1] <= (hitWay == 2) ? 1'b1 : 1'b0;
				end
				plruBits[index][2] <= (hitWay < 2) ? 1'b1 : 1'b0;
			end else begin // Write miss, need to get data from memory to write to block
				// Similar to read miss, but we also need to mark the MSHR entry as a write and store the data to be written
				if (mshrHit) begin
					missQueues[mshrIndex][mshr[mshrIndex].tail] <= '{l1ReqWrite, l1DataIn}; // Store whether it's a write and the data
					mshr[mshrIndex].tail <= mshr[mshrIndex].tail + 1;
				end else begin
					// Find a free MSHR
					logic foundFreeMshr = 1'b0;
					for (int i = 0; i < L2_MSHR_COUNT; i++) begin
						if (!mshr[i].valid && !foundFreeMshr) begin
							mshr[i].valid <= 1'b1;
							mshr[i].blockAddr <= l1Addr[29:6]; // Store block-aligned address
							mshr[i].tail <= 0;
							missQueues[i][0] <= '{l1ReqWrite, l1DataIn}; // Store the first miss in the queue
							mshr[i].tail <= 1;
							foundFreeMshr = 1'b1;
						end
					end
					// If no free MSHR, stall
				end
				
			end
		end else begin
			l1RespValid <= 1'b0;
		end
	end


	// TODO
	// If misses, send read/write requests to memory controller and handle responses
	// This part is more complex and involves handling the MSHR queues, sending requests to memory, and updating the cache on responses.
	// This is also where eviction is handled and replacement policy is applied, writeback is also done if the evicted line is dirty.
	// For now, don't have write buffer



endmodule: llcd /* verilator lint_off EOFNEWLINE */