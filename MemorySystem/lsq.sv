/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off DECLFILENAME */

`timescale 1ns/1ps

// ----------------------------------------------------------------------------------------------------
// 
// Format of LSQ entry
//
// ----------------------------------------------------------------------------------------------------

// Format of entry:
// Valid            | 1b          | Active instruction vs. inactive instruction
// Resolved         | 1b          | Address has been calculated by the processor
// Addr             | 48b         | Virtual address
// Value Valid      | 1b          | Data is valid (for stores)
// Data             | 64b         | Data
// Trace ID         | 4b          | Trace ID for matching with trace lines
// SQ Tail          | 3b          | Only for store queue, indicates the position in the store queue for forwarding
// LQ Tail          | 3b          | Only for load queue, indicates the position in the load queue for forwarding
// Total: 1 + 1 + 48 + 1 + 64 + 4 + 3 + 3 = 125 bits per entry

// ----------------------------------------------------------------------------------------------------
// 
// Load-Store Queue (LSQ)
//
// ----------------------------------------------------------------------------------------------------

// Enum provided by the assignment
typedef enum logic[2:0] {
    OP_MEM_LOAD = 0,    // Perform a memory load
    OP_MEM_STORE = 1,   // Send a memory store
    OP_MEM_RESOLVE = 2, // Resolve an unresolved address
    OP_TLB_FILL = 4     // Fill a line of the TLB 
} op_e;

// Load store queue (LSQ) (aka the controller module)
module lsq # (
    parameter int N = 16,
    parameter int Q_SIZE = 8
) (
    input logic clk,
    input logic rst_n, // Assume active low rese

    // Signals predefined from the traces that get fed into the LSQ
    input logic [120:0] trace_line, // Break this trace line into different components

    // Signals from the TLB
    input logic tlb_hit,
    input logic [29:0] tlb_paddr,

    // Signals from $L1
    input logic cache_ready,
    input logic cache_ret_valid,
    input logic [63:0] cache_ret_data, // Read

    // Signals to the TLB
    output logic tlb_req,
    output logic [47:0] tlb_vaddr,  // Registered vaddr stable for the full cycle tlb_req is high
    // Forward fill
    output logic tlb_fill,
    output logic [29:0] fill_tlb_paddr, // Forward the physical addr
    output logic [47:0] fill_tlb_vaddr,  // Forward the virtual addr

    // Signals to $L1
    output logic cache_req,
    output logic cache_we,
    output logic [29:0] cache_paddr,
    output logic [63:0] cache_wdata
);     
    op_e trace_op;
    logic [3:0] trace_id;
    logic [47:0] trace_vaddr;
    logic trace_vaddr_is_valid;     // Only relevant to mem operations
    logic trace_value_is_valid;     // Only relevant to store operations
    logic [63:0] trace_value;       // Only relevant to store operations

    assign trace_op = op_e'(trace_line[54:52]);
    assign trace_id = trace_line[51:48];
    assign trace_vaddr = trace_line[47:0];
    assign tlb_vaddr = trace_line[47:0];            // Latch vaddr so it stays stable while tlb_req is high (same cycle as the queues)
    assign trace_vaddr_is_valid = trace_line[55];
    assign trace_value_is_valid = trace_line[120];
    assign trace_value = trace_line[119:56];

    // TLB forward fill from processor -> bypass LSQ -> TLB
    assign tlb_fill = (trace_line[54:52] == 3'(OP_TLB_FILL));
    assign fill_tlb_paddr = trace_line[85:56];
    assign fill_tlb_vaddr = trace_line[47:0];
    
    localparam int LOAD_QUEUE_SIZE = N>>1;  // 16 entries -> 8 loads and 8 stores
    localparam int STORE_QUEUE_SIZE = N>>1;
    localparam int ENTRY_SIZE = 125;
    localparam int EA_SIZE = 48;
    localparam int PA_SIZE = 30;
    localparam int DATA_SIZE = 64;

    // Format of entry:
    // Valid            | 1b          | Active instruction vs. inactive instruction
    // Resolved         | 1b          | Address has been calculated by the processor
    // Addr             | 48b         | Address
    // Value Valid      | 1b          | Data is valid (for stores)
    // Data             | 64b         | Data
    // Trace ID         | 4b          | Trace ID for matching with trace lines
    // SQ Tail          | 3b          | Only for store queue, indicates the position in the store queue for forwarding
    // LQ Tail          | 3b          | Only for load queue, indicates the position in the load queue for forwarding

    localparam int VALID_IDX = ENTRY_SIZE - 1;
    localparam int RESOLVED_IDX = VALID_IDX - 1;
    localparam int EA_IDX = RESOLVED_IDX - 1;
    localparam int VVALID_IDX = EA_IDX - EA_SIZE;
    // Format of entry:
    // Valid            | 1b          | Active instruction vs. inactive instruction
    // Resolved         | 1b          | Address has been calculated by the processor
    // Addr             | 48b         | Address
    // Value Valid      | 1b          | Data is valid (for stores)
    // Data             | 64b         | Data
    // Trace ID         | 4b          | Trace ID for matching with trace lines
    // SQ Tail          | 3b          | Only for store queue, indicates the position in the store queue for forwarding
    // LQ Tail          | 3b          | Only for load queue, indicates the position in the load queue for forwarding

    localparam int DATA_IDX = VVALID_IDX - 1;
    localparam int TRACE_ID_IDX = DATA_IDX - DATA_SIZE;
    localparam int SQ_TAIL_IDX = TRACE_ID_IDX - 4;
    localparam int LQ_TAIL_IDX = SQ_TAIL_IDX - 3;

    logic tlb_pending;                                      // TLB response is expected next cycle
    logic tlb_pending_is_load;                              // 1 = LOAD queue, 0 = STORE queue
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] tlb_pending_idx;    // queue slot of the entry awaiting translation

    logic cache_pending;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] cache_pending_idx;  // LQ entry that is waiting for cache data

    logic [3:0] trace_id_prev;

    // Load and store queue stuff
    logic [LOAD_QUEUE_SIZE-1:0][ENTRY_SIZE-1:0] load_entries;
    logic [STORE_QUEUE_SIZE-1:0][ENTRY_SIZE-1:0] store_entries;
    logic [LOAD_QUEUE_SIZE-1:0] load_matches;
    logic [STORE_QUEUE_SIZE-1:0] store_matches;

    logic enqueue_load, enqueue_store;
    logic dequeue_load, dequeue_store;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] load_head, load_tail;
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] store_head, store_tail;
    logic load_success, store_success;

    logic load_update, store_update;
    // 2 Cycle latency cache means HOLD onto the actually-being-registered load and stores
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] load_update_idx;        // Combinational result
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] store_update_idx;      // Combination result
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] load_update_idx_stable; // For synchronous blocks
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] store_update_idx_stable;   // For synchronous blocks
    // Buses for manually injecting updates into the queue (idk if this makes sense or not)
    logic [ENTRY_SIZE-1:0] load_entry_bus;
    logic [ENTRY_SIZE-1:0] store_entry_bus;

    logic [STORE_QUEUE_SIZE-1:0] stores_before_load_mask, stores_after_store_mask;
    logic [LOAD_QUEUE_SIZE-1:0]  loads_after_store_mask;

    // Final bit vectors combining matching EA and before/ after logic for forwarding and updates
    logic [STORE_QUEUE_SIZE-1:0] final_stores_before_load;
    logic [LOAD_QUEUE_SIZE-1:0]  final_loads_after_store;
    logic [STORE_QUEUE_SIZE-1:0] final_stores_after_store;
    
    // Match bit vector
    // When load or store resolves, we have to find all matching EA to do the following:
    // Store:
    // 1. Update any later loads that match the store (store broadcasts EA to later loads 
    // that might have completed before store resolved -> rexecute this load and everything after it)
    // 2. Update any later stores that match the store (store broadcasts EA to later stores
    // that would update the same EA, useful for saving in-order commits to the $L1)
    // Load:
    // 1. Broadcast EA to earlier stores (forwarding data from LSQ vs memory or cache as 
    // that would have stale data if not yet committed)

    // Init load and store queue and all additional features
    // Note: The queues synchronously clock in the entries
    // Note: Create an additional bus to handle manually update entries (probably security violation, oh well)
    _queue #(.N(LOAD_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE)) load_queue (
        .clk(clk),
        .rst_n(rst_n),
        .head(load_head),
        .tail(load_tail),
        .enqueue(enqueue_load),
        .dequeue(dequeue_load),
        .entry(load_entry_bus),
        .update(load_update),
        .update_idx(load_update_idx_stable),
        .entries(load_entries),
        .success(load_success)
    );

    _queue #(.N(STORE_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE)) store_queue (
        .clk(clk),
        .rst_n(rst_n),
        .head(store_head),
        .tail(store_tail),
        .enqueue(enqueue_store),
        .dequeue(dequeue_store),
        .entry(store_entry_bus),
        .update(store_update),
        .update_idx(store_update_idx_stable),
        .entries(store_entries),
        .success(store_success)
    );

    _match #(.Q_SIZE(LOAD_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) load_match (
        .ea(trace_vaddr),
        .entries(load_entries),
        .matching_eas(load_matches)
    );

    _match #(.Q_SIZE(STORE_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) store_match (
        .ea(trace_vaddr),
        .entries(store_entries),
        .matching_eas(store_matches)
    );

    // Generate the LSQ operations
    // 1. Load instruction after exec stores (exec load, use information from prev stores)
    _before_and_after #(.Q_SIZE(STORE_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) stores_before_load (
        .head(store_head),
        .tail(store_tail),
        .j(load_entries[load_update_idx][SQ_TAIL_IDX+:3]), // Get the SQ tail index for the load being updated
        .entries(store_entries),
        .before_matches(stores_before_load_mask),
        .after_matches()  // Unused
    );

    // 2. Store instruction after exec loads (exec store, update later loads that might have gone ahead)
    _before_and_after #(.Q_SIZE(LOAD_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) loads_after_store (
        .head(load_head),
        .tail(load_tail),
        .j(store_entries[store_update_idx][LQ_TAIL_IDX+:3]), // Get the LQ tail index for the store being updated
        .entries(load_entries),
        .before_matches(), // Unused
        .after_matches(loads_after_store_mask)
    );

    // 3. Store instruction after exec stores (exec store, update later stores that might depend on this store)
    _before_and_after #(.Q_SIZE(STORE_QUEUE_SIZE), .ENTRY_SIZE(ENTRY_SIZE), .EA_SIZE(EA_SIZE)) stores_after_store (
        .head(store_head),
        .tail(store_tail),
        .j(store_update_idx), // Compare against the current store being executed (index)
        .entries(store_entries),
        .before_matches(), // Unused
        .after_matches(stores_after_store_mask)
    );
    
    // Final bit vectors that combined the matching EA and before/ after logic
    always_comb begin
        final_stores_before_load = store_matches & stores_before_load_mask;
        final_loads_after_store = load_matches  & loads_after_store_mask;
        final_stores_after_store = store_matches & stores_after_store_mask;
    end

    // Find indices for resolving instructions out of order (in either queue)
    always_comb begin
        load_update_idx = '0; 
        store_update_idx = '0;

        for (int i = 0; i < LOAD_QUEUE_SIZE; i++) 
            // If instruction is valid (active) and trace id is aligned with current instruction executing, then we have index for current execution
            if (load_entries[i][VALID_IDX] && load_entries[i][TRACE_ID_IDX-:4] == trace_id) 
                load_update_idx = $clog2(LOAD_QUEUE_SIZE)'(i); // Convert idx to the correct dimension
        for (int i = 0; i < STORE_QUEUE_SIZE; i++) 
            if (store_entries[i][VALID_IDX] && store_entries[i][TRACE_ID_IDX-:4] == trace_id) 
                store_update_idx = $clog2(STORE_QUEUE_SIZE)'(i);
    end

    // Combinational entry bus
    // load_entry_bus / store_entry_bus are the data inputs to _queue
    // _queue uses non-blocking <= to enqueue entries -> it will take entries from the busses at the posedge
    always_comb begin
        // Load entry bus
        load_entry_bus = '0;

        if (cache_pending && cache_ret_valid) begin
            // Cache returned load data
            load_entry_bus = load_entries[cache_pending_idx];
            load_entry_bus[VVALID_IDX] = 1;
            load_entry_bus[DATA_IDX-:DATA_SIZE] = cache_ret_data;

        end else if (tlb_pending && tlb_hit && tlb_pending_is_load) begin
            // TLB hit for a load
            // Set resolved bit
            load_entry_bus = load_entries[tlb_pending_idx] | (ENTRY_SIZE'(1) << RESOLVED_IDX);

        end else if (trace_id != trace_id_prev) begin
            // New trace
            case (trace_op)
                OP_MEM_LOAD: begin
                    load_entry_bus = {
                        1'b1,                  // Valid
                        1'b0,                  // Resolved (already known since trace_vaddr_is_valid is passed...? That doesn't seem right)
                        trace_vaddr,           // EA virtual
                        1'b0,                  // Value valid (filled by cache)
                        64'b0,                 // Data (filled by cache)
                        trace_id,              // Trace ID
                        store_tail,            // SQ tail snapshot for forwarding
                        3'b0                   // LQ tail unused for loads
                    };
                end
                OP_MEM_RESOLVE: begin
                    // Find the trace with the same id and update (if missing EA)
                    // Check if the entry is valid instruction (not retired/ committed)
                    if (load_entries[load_update_idx][TRACE_ID_IDX-:4] == trace_id && load_entries[load_update_idx][VALID_IDX]) begin
                        load_entry_bus = (
                                load_entries[load_update_idx]           // Get the already stored entry
                                | (ENTRY_SIZE'(1) << RESOLVED_IDX))     // Set resolved (assumes processor comes back with the right EA)
                                & ~(((ENTRY_SIZE'(1) << EA_SIZE) - 1)   // Mask (all EA bits are flipped to 1, then zeroed (NOT operation), then shifted into place)
                                << (EA_IDX - EA_SIZE + 1));             // Clear old EA
                        load_entry_bus[EA_IDX-:EA_SIZE] = trace_vaddr;  // Write new EA
                    end
                end
                default: begin
                end
            endcase
        end

        // Store entry bus
        store_entry_bus = '0;

        if (tlb_pending && tlb_hit && !tlb_pending_is_load) begin
            // TLB hit for a store 
            // Set resolved bit
            store_entry_bus = store_entries[tlb_pending_idx] | (ENTRY_SIZE'(1) << RESOLVED_IDX);

        end else if (trace_id != trace_id_prev) begin
            case (trace_op)
                OP_MEM_STORE: begin
                    store_entry_bus = {
                        1'b1,                  // Valid
                        1'b0,                  // Resolved
                        trace_vaddr,           // EA virtual
                        trace_value_is_valid,  // Value valid
                        trace_value,           // Store data
                        trace_id,              // Trace ID
                        3'b0,                  // SQ tail unused for stores
                        load_tail              // LQ tail snapshot for forwarding
                    };
                end
                OP_MEM_RESOLVE: begin
                    // Do the same as the load bus
                    if (store_entries[store_update_idx][TRACE_ID_IDX-:4] == trace_id && store_entries[store_update_idx][VALID_IDX]) begin
                        store_entry_bus = (
                            store_entries[store_update_idx]
                            | (ENTRY_SIZE'(1) << RESOLVED_IDX))
                            & ~(((ENTRY_SIZE'(1) << EA_SIZE) - 1)
                            << (EA_IDX - EA_SIZE + 1));
                        store_entry_bus[EA_IDX-:EA_SIZE] = trace_vaddr;
                    end
                end
                default: ;
            endcase
        end
    end

    // Synchronous
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cache_req <= 0;
            cache_we <= 0;
            cache_paddr <= '0;
            cache_wdata <= '0;
            cache_pending <= 0;
            cache_pending_idx <= '0;

            tlb_req <= 0;
            tlb_pending <= 0;   
            tlb_pending_is_load <= 0;
            tlb_pending_idx <= '0;

            load_update_idx_stable <= '0;
            store_update_idx_stable <= '0;

            trace_id_prev <= '0;
            enqueue_load <= 0;
            enqueue_store <= 0;
            dequeue_load <= 0; // Not really used...
            dequeue_store <= 0; // Not really used...
            load_update <= 0;
            store_update <= 0;

        end else begin
            // Clear enqueue signals if not a new operation (Defaults)
            enqueue_load <= 0;
            enqueue_store <= 0;
            load_update <= 0;
            store_update <= 0;

            cache_req <= 0;
            cache_pending <= 0;

            tlb_req <= 0;
            tlb_pending <= 0;

            // Cache handler
            // $L1 has 2 cycle latency
            // Cache pending is only ever triggered by load requests (so we know it's a load and we just have to wait for valid data)
            if (cache_pending && cache_ret_valid) begin
                load_update <= 1;
                load_update_idx_stable <= cache_pending_idx;
            end
    
            // TLB handler
            // Has 1 cycle latency
            // Cycle N: tlb_pending is waiting upon $L1 response and tlb_req is triggered
            // Cycle N+1: the TLB registered outputs are valid
            // On a hit: update the entry with the physical address
            // On a miss: leave the entry unresolved; the processor must send OP_MEM_RESOLVE after the page-walk is done ?
            if (tlb_pending) begin
                if (tlb_hit) begin
                    // Set resolved in the correct queue entry
                    if (tlb_pending_is_load) begin
                        load_update <= 1;
                        load_update_idx_stable <= tlb_pending_idx;
                    end else begin
                        store_update <= 1;
                        store_update_idx_stable <= tlb_pending_idx;
                    end

                    // Forward the translation results (PA) to the cache
                    if (cache_ready) begin
                        cache_req <= 1;
                        cache_paddr <= tlb_paddr;
                        cache_we <= ~tlb_pending_is_load;   // 0=load, 1=store

                        if (tlb_pending_is_load) begin
                            cache_wdata <= '0;
                            cache_pending <= 1;
                            cache_pending_idx <= tlb_pending_idx;
                        end else begin
                            // Store (send right away)
                            cache_wdata <= store_entries[tlb_pending_idx][DATA_IDX-:DATA_SIZE];
                            cache_pending <= 0;
                        end
                    end
                    // TODO: What if cache is not ready?
                end
                // TODO: TLB miss (idk)
            end

            // Check for new operations (register memory loads and stores)
            if (trace_id != trace_id_prev) begin
                // Update the previous trace tracker
                trace_id_prev <= trace_id;

                // Need to hear request and queue on first cycle
                case (trace_op)
                    OP_MEM_LOAD: begin
                        enqueue_load <= 1;

                        // TLB request
                        tlb_req <= 1;
                        tlb_pending <= 1;
                        tlb_pending_is_load <= 1;
                        tlb_pending_idx <= load_tail;   // Get the tail (recently added load)
                    end

                    OP_MEM_STORE: begin
                        enqueue_store <= 1;

                        // TLB request if there is no store forwarding (check stores before load)
                        if (!|final_stores_before_load) begin
                            tlb_req             <= 1;
                            tlb_pending         <= 1;
                            tlb_pending_is_load <= 1;
                            tlb_pending_idx     <= load_update_idx;
                        end
                    end

                    OP_MEM_RESOLVE: begin   // Resolve unresolved address
                        // Determine which queue holds this trace's ID and update it
                        if (load_entries[load_update_idx][TRACE_ID_IDX-:4] == trace_id && load_entries[load_update_idx][VALID_IDX]) begin
                            load_update <= 1;
                            load_update_idx_stable <= load_update_idx;
                            tlb_req <= 1;
                            tlb_pending <= 1;
                            tlb_pending_is_load <= 1;
                            tlb_pending_idx <= load_update_idx;

                        end else if (store_entries[store_update_idx][TRACE_ID_IDX-:4] == trace_id && store_entries[store_update_idx][VALID_IDX])begin
                            store_update <= 1;
                            store_update_idx_stable <= store_update_idx;
                            tlb_req <= 1;
                            tlb_pending <= 1;
                            tlb_pending_is_load <= 0;
                            tlb_pending_idx <= store_update_idx;
                        end
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule

// ----------------------------------------------------------------------------------------------------
// 
// Helpers
//
// ----------------------------------------------------------------------------------------------------

// Queue (literal queue for managing adding and removing entries, no additional LSQ)
// Assume load and store queue both get 8 entries for 16 total entries
module _queue #(
    parameter int N = 8,
    parameter int ENTRY_SIZE = 125
) (
    input logic clk,
    input logic rst_n, // Assume active low reset

    input logic enqueue, // Signal to add an entry to the queue
    input logic dequeue, // Signal to remove an entry from the queue
    input logic [ENTRY_SIZE-1:0] entry, // Either load or store entry

    input logic update,  // Signal to update an entry in the queue
    input logic [$clog2(N)-1:0] update_idx,

    // Internals exposed as outputs
    output logic [$clog2(N)-1:0] head,
    output logic [$clog2(N)-1:0] tail,
    output logic [N-1:0][ENTRY_SIZE-1:0] entries, // I want to expose the inner workings of the queue for matching vectors
    
    output logic success
);
    localparam VALID_IDX = ENTRY_SIZE - 1;

    logic [$clog2(N)-1:0] head_ptr, tail_ptr;
    assign head = head_ptr;
    assign tail = tail_ptr;
    // Check if full (tail has caught up with the head, so one index less than head, with wraparound)
    logic is_full, is_empty;
    assign is_full = (($clog2(N)'(tail_ptr + 1)) % N == head_ptr);
    assign is_empty = (tail_ptr == head_ptr); // Check if empty (tail is equal to the head)

    // Synchronous
    // Add entry and remove entries from the queue
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= 0;
            tail_ptr <= 0;
            success <= 0;
            for (int i = 0; i < N; i++) begin
                entries[i] <= '0;
            end

        end else begin
            // Resolving addresses
            if (update) begin
                entries[update_idx] <= entry;
            end

            success <= 0; // Default to unsuccessful unless we do an enqueue or dequeue successfully
            // Queue and dequeue operations
            if (enqueue && !is_full) begin   // Add entry to the queue if not full
                // Add entry to the queue at tail index
                entries[tail_ptr] <= entry;
                tail_ptr <= $clog2(N)'((tail_ptr + 1) % N); // Move tail ptr with wraparound
                success <= 1; // Indicate successful enqueue

            end else if (dequeue && !is_empty) begin // Remove entry from the queue if not empty (consider entry this resolved)
                entries[head_ptr][VALID_IDX] <= 0; // Indicate invalid upon dequeue (committed instruction)
                head_ptr <= $clog2(N)'((head_ptr + 1) % N); // Move head ptr with wraparound
                success <= 1; // Indicate successful dequeue
            end
        end
    end

endmodule

// Combinational logic helper for finding matching EA amongst all load and store queues
// Incorporates before and after logic (from the slides)
module _match #(
    parameter int Q_SIZE = 8,
    parameter int ENTRY_SIZE = 125,
    parameter int EA_SIZE = 48  // Num of bits in the EA
) (
    input logic [EA_SIZE-1:0] ea, // The EA to compare with

    input logic [Q_SIZE-1:0][ENTRY_SIZE-1:0] entries, // With only EA and valid+resolved bits exposed
    output logic [Q_SIZE-1:0] matching_eas
);
    localparam VALID_IDX = ENTRY_SIZE - 1;
    localparam RESOLVED_IDX = VALID_IDX - 1;
    localparam EA_IDX = RESOLVED_IDX - 1;

    // Find matching EA
    always_comb begin
        // Synthesizeable for loop (parallel comparators)
        for (int i = 0; i < Q_SIZE; i++) begin
            matching_eas[i] = (entries[i][EA_IDX-:EA_SIZE] == ea) &&
                        entries[i][VALID_IDX] &&     // Check if valid bit is set (non-retired instruction)
                        entries[i][RESOLVED_IDX];    // Check if resolved bit is set (EA has been resolved) 
        end
    end

endmodule

// Combinational logic helper for finding before and after matches
// before(j) returns a bit vector that contains a 1 for all valid queue entries that are before position j
// after(j) returns a bit vector that contains a 1 for all valid queue entries that are after position j
module _before_and_after #(
    parameter int Q_SIZE = 8,
    parameter int ENTRY_SIZE = 125,
    parameter int EA_SIZE = 48
) (
    input logic [$clog2(Q_SIZE)-1:0] head,
    input logic [$clog2(Q_SIZE)-1:0] tail,
    input logic [$clog2(Q_SIZE)-1:0] j,

    input logic [Q_SIZE-1:0][ENTRY_SIZE-1:0] entries, // With only EA and valid+resolved bits exposed

    output logic [Q_SIZE-1:0] before_matches,
    output logic [Q_SIZE-1:0] after_matches
);
    localparam VALID_IDX = ENTRY_SIZE - 1;
    localparam RESOLVED_IDX = VALID_IDX - 1;
    localparam EA_IDX = RESOLVED_IDX - 1;

    // Get the valid bits (active entries, active but may not be resolved instructions)
    logic [Q_SIZE-1:0] valid_bits;
    always_comb begin
        for (int i = 0; i < Q_SIZE; i++) begin
            valid_bits[i] = entries[i][VALID_IDX];
        end 
    end

    logic [Q_SIZE-1:0] prec_head, prec_tail, prec_j, map_tail, map_j;
    logic [Q_SIZE-1:0] raw_before, raw_after;

    always_comb begin
        // Helper prec and map functions
        // prec(j) returns bit vector of 1s for all queue entries before j
        prec_head = (Q_SIZE'(1) << head) - 1'b1;    // Bit vector of size 8 shifted by head and indicate 1s where everything else is after head
        prec_tail = (Q_SIZE'(1) << tail) - 1'b1;
        prec_j = (Q_SIZE'(1) << j) - 1'b1;
        // map(j) returns bit vector of 1 at position j and 0s elsewhere
        map_tail = Q_SIZE'(1) << tail;
        map_j = Q_SIZE'(1) << j;

        // before(j) logic 
        if (j >= head) 
            raw_before = ~prec_head & prec_j;
        else
            raw_before = ~prec_head | prec_j;

        // after(j) logic 
        if (j <= tail) 
            raw_after = ~prec_j & ~map_j & (prec_tail | map_tail);
        else
            raw_after = (~prec_j | prec_tail | map_tail) & ~map_j;

        // Combine calculated masks with the valid bits of the entries
        before_matches = raw_before & valid_bits;
        after_matches  = raw_after  & valid_bits;
    end
    
endmodule
