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
	output logic memWriteReqValid // Data on bus is for a valid write request
);


	logic [DATA_WIDTH-1:0] dataArray [L2_SETS-1:0][L2_WAYS-1:0];
	l2LineMetadata lineMd [L2_SETS-1:0][L2_WAYS-1:0];

	// Using PLRU for replacement
	// Need A-1 bits per set
	logic [L2_WAYS-2:0] plruBits [L2_SETS-1:0];

	l2_mshr_t mshr[L2_MSHR_COUNT];
	l2_mshr_miss_t missQueues[L2_MSHR_COUNT][L2_MSHR_QUEUE_SIZE];

	// Internal state for refill/eviction handling.
	logic [PADDR_WIDTH-1:0] evictAddrReg;
	logic [DATA_WIDTH-1:0] evictDataReg;
	logic evictWriteReqReg;

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
			if (mshr[i].valid && (mshr[i].addr == {l1Addr[29:6], 6'b0})) begin
				mshrHit = 1'b1;
				mshrIndex = i[$clog2(L2_MSHR_COUNT)-1:0];
			end
		end
	end

	function automatic logic [L2_WAY_WIDTH-1:0] selectVictimWay(
		input logic [L2_WAYS-2:0] plru
	);
		logic [L2_WAY_WIDTH-1:0] victim;
		begin
			// 4-way tree pLRU.
			// plru[2]: root, plru[0]: left subtree, plru[1]: right subtree.
			if (plru[2]) begin
				victim = plru[1] ? L2_WAY_WIDTH'(3) : L2_WAY_WIDTH'(2);
			end else begin
				victim = plru[0] ? L2_WAY_WIDTH'(1) : L2_WAY_WIDTH'(0);
			end
			return victim;
		end
	endfunction

	function automatic logic [L2_WAY_WIDTH-1:0] chooseFillWay(
		input logic [L2_INDEX_WIDTH-1:0] setIdx
	);
		logic [L2_WAY_WIDTH-1:0] chosen;
		logic foundInvalid;
		begin
			chosen = selectVictimWay(plruBits[setIdx]);
			foundInvalid = 1'b0;
			for (int w = 0; w < L2_WAYS; w++) begin
				if (!lineMd[setIdx][w].valid && !foundInvalid) begin
					chosen = L2_WAY_WIDTH'(w);
					foundInvalid = 1'b1;
				end
			end
			return chosen;
		end
	endfunction

	task automatic updatePlruOnAccess(
		input logic [L2_INDEX_WIDTH-1:0] setIdx,
		input logic [L2_WAY_WIDTH-1:0] way
	);
		begin
			if (way < 2) begin
				plruBits[setIdx][0] <= (way == 0) ? 1'b1 : 1'b0;
			end else begin
				plruBits[setIdx][1] <= (way == 2) ? 1'b1 : 1'b0;
			end
			plruBits[setIdx][2] <= (way < 2) ? 1'b1 : 1'b0;
		end
	endtask


	// Handle reads:
	always_ff @(posedge clk) begin
		if (!rstN) begin
			l1DataOut <= '0;
			l1RespValid <= 1'b0;
		end else if (l1ReqValid && !l1ReqWrite) begin // Read request
			if (cacheHit) begin
				l1DataOut <= dataArray[index][hitWay][blockOffset*8 +: BLOCK_SIZE]; // Extract the correct block based on offset
				l1RespValid <= 1'b1;

				updatePlruOnAccess(index, hitWay);

			end else begin
				// Read miss
				// If MSHR already tracking this miss, just add to its queue
				// Else, find a free MSHR and allocate it for this miss
				if (mshrHit) begin
					if (mshr[mshrIndex].tail < L2_MSHR_TAIL_WIDTH'(L2_MSHR_QUEUE_SIZE)) begin
						missQueues[mshrIndex][mshr[mshrIndex].tail] <= '{l1ReqWrite, l1DataIn}; // Store whether it's a write and the data (if it's a write)
						mshr[mshrIndex].tail <= mshr[mshrIndex].tail + 1'b1;
					end else begin
						// Queue full for this in-flight miss (depth=1): drop/coalesce policy is not implemented.
						l1RespValid <= 1'b0;
					end
				end else begin
					// Find a free MSHR
					logic foundFreeMshr = 1'b0;
					for (int i = 0; i < L2_MSHR_COUNT; i++) begin
						if (!mshr[i].valid && !foundFreeMshr) begin
							mshr[i].valid <= 1'b1;
							mshr[i].addr <= {l1Addr[29:6], 6'b0}; // Store block-aligned address
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
				dataArray[index][hitWay][blockOffset*8 +: BLOCK_SIZE] <= l1DataIn;
				lineMd[index][hitWay].dirty <= 1'b1; // Mark line as dirty on write
				l1RespValid <= 1'b1;
				updatePlruOnAccess(index, hitWay);
			end else begin // Write miss, need to get data from memory to write to block
				// Similar to read miss, but we also need to mark the MSHR entry as a write and store the data to be written
				if (mshrHit) begin
					if (mshr[mshrIndex].tail < L2_MSHR_TAIL_WIDTH'(L2_MSHR_QUEUE_SIZE)) begin
						missQueues[mshrIndex][mshr[mshrIndex].tail] <= '{l1ReqWrite, l1DataIn}; // Store whether it's a write and the data
						mshr[mshrIndex].tail <= mshr[mshrIndex].tail + 1'b1;
					end
				end else begin
					// Find a free MSHR
					logic foundFreeMshr = 1'b0;
					for (int i = 0; i < L2_MSHR_COUNT; i++) begin
						if (!mshr[i].valid && !foundFreeMshr) begin
							mshr[i].valid <= 1'b1;
							mshr[i].addr <= {l1Addr[29:6], 6'b0}; // Store block-aligned address
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


	logic serviceMshrValid;
	logic [$clog2(L2_MSHR_COUNT)-1:0] serviceMshrIdx;
	always_comb begin
		serviceMshrValid = 1'b0;
		serviceMshrIdx = '0;
		for (int i = 0; i < L2_MSHR_COUNT; i++) begin
			if (mshr[i].valid && !serviceMshrValid) begin
				serviceMshrValid = 1'b1;
				serviceMshrIdx = i[$clog2(L2_MSHR_COUNT)-1:0];
			end
		end
	end

	// Miss completion path: refill line, process queued misses, and evict dirty victim if needed.
	always_ff @(posedge clk) begin
		if (!rstN) begin
			evictAddrReg <= '0;
			evictDataReg <= '0;
			evictWriteReqReg <= 1'b0;
			for (int s = 0; s < L2_SETS; s++) begin
				plruBits[s] <= '0;
				for (int w = 0; w < L2_WAYS; w++) begin
					lineMd[s][w] <= '{tag: '0, valid: 1'b0, dirty: 1'b0};
					dataArray[s][w] <= '0;
				end
			end
			for (int i = 0; i < L2_MSHR_COUNT; i++) begin
				mshr[i] <= '{valid: 1'b0, addr: '0, tail: '0};
				for (int q = 0; q < L2_MSHR_QUEUE_SIZE; q++) begin
					missQueues[i][q] <= '{isWrite: 1'b0, writeData: '0};
				end
			end
		end else begin
			evictWriteReqReg <= 1'b0;

			if (serviceMshrValid && memReadRespValid && memReadRespReady) begin
				logic [PADDR_WIDTH-1:0] mshrAddr;
				logic [L2_INDEX_WIDTH-1:0] fillIndex;
				logic [L2_TAG_WIDTH-1:0] fillTag;
				logic [L2_WAY_WIDTH-1:0] fillWay;
				logic [DATA_WIDTH-1:0] refillLine;
				logic refillDirty;

				mshrAddr = mshr[serviceMshrIdx].addr;
				fillIndex = mshrAddr[OFFSET_WIDTH +: L2_INDEX_WIDTH];
				fillTag = mshrAddr[OFFSET_WIDTH + L2_INDEX_WIDTH +: L2_TAG_WIDTH];
				fillWay = chooseFillWay(fillIndex);
				refillLine = memData;
				refillDirty = 1'b0;

				// Write back dirty victim (no dedicated write buffer in this version).
				if (lineMd[fillIndex][fillWay].valid && lineMd[fillIndex][fillWay].dirty) begin
					evictAddrReg <= {
						lineMd[fillIndex][fillWay].tag,
						fillIndex,
						{OFFSET_WIDTH{1'b0}}
					};
					evictDataReg <= dataArray[fillIndex][fillWay];
					evictWriteReqReg <= 1'b1;
				end

				// Apply coalesced writes in MSHR queue to the refilled line.
				for (int q = 0; q < L2_MSHR_QUEUE_SIZE; q++) begin
					if (q < mshr[serviceMshrIdx].tail && missQueues[serviceMshrIdx][q].isWrite) begin
						// Requests are 64-bit beats; current interface does not carry per-request byte offset.
						refillLine[63:0] = missQueues[serviceMshrIdx][q].writeData;
						refillDirty = 1'b1;
					end
				end

				dataArray[fillIndex][fillWay] <= refillLine;
				lineMd[fillIndex][fillWay] <= '{tag: fillTag, valid: 1'b1, dirty: refillDirty};
				updatePlruOnAccess(fillIndex, fillWay);

				mshr[serviceMshrIdx] <= '{valid: 1'b0, addr: '0, tail: '0};
				for (int q = 0; q < L2_MSHR_QUEUE_SIZE; q++) begin
					missQueues[serviceMshrIdx][q] <= '{isWrite: 1'b0, writeData: '0};
				end
			end
		end
	end

	

	always_comb begin
		memAddr = '0;
		if (evictWriteReqReg) begin
			memAddr = evictAddrReg;
		end else if (serviceMshrValid) begin
			memAddr = mshr[serviceMshrIdx].addr;
		end
		memWriteReqValid = evictWriteReqReg;
	end

	assign memData = memWriteReqValid ? evictDataReg : {DATA_WIDTH{1'bz}};
endmodule: llcd /* verilator lint_off EOFNEWLINE */