`timescale 1ns/1ps

// Load to store forwarding

// Separate load and store instead of combined

// figure out how to implement both combined and separate
// A combined load-store queue (LSQ) with 16 entries.

//     "Combined" means that there is a single hardware buffer which contains both loads and stores


// ------------------- Load-Store Queue -------------------
// Responsibilities:
// 1, 16 entries (all loads and stores that enter LSQ before getting to the cache)
// 2. RAW (load after store) forwarding
// 3. Stores are commited in order
// 4. Memory ordering is true (load and store respect memory dependencies)
// 5. Stores can be resolved OOO (both values and addresses)
// 6.

// Loads must search stores before them in the queue. 

// Stores must search operations after the

// loads can violate ordering with earlier stores

// both loads and stores in program order.

// entries have resolved and unresolved



// -------------------------------------

// Current plan:
// Instruction
//    to
// Load-Store Queue (LSQ) -- memory ordering
//    to
// L1 dTLB (virtual → physical) -- address translation
//    to
// L1 Data Cache (VIPT) -- cache stores data
//    to
// L2 Cache (PIPT) -- store data
//    to
// DRAM

// LSQ
// 16 entries
// Keep track of all loads and stores
// Correct memory ordering
// store to load forwarding
// OOO execution of the memory operations (but stores are not commit quite yet)

// Entry fields?precise exceptions
// valid
// load or store type
// address
// is address valid?
// store data
// data valid?

// Loads
// wait for query
// wait for address to finish computing
// search all earlier stores
// check the following cases (slides)

// Cases ^^^
// 1.
// Matching store (so store and load addr are teh same)
// forward the store data to the load
// Loads do NOT need to access cache data
// 2.
// earlier store is not resolved yet (address is not valid)
// store will resolve later (stall any loads later than it)
// WHEN STORES RESOLVES
// search later loads and stores so that you can update those fields

// Data for stores are resolved 
// maintain precise exceptions + speculative execution
// 3.
// no conflicts
// load can access L1 cache (no dependences in the LSQ)


// Stores are moved to L1
// modify cache line (in the cache, not in the LSQ)
// Dirty lines can be evicted to L2 then to memory


// Ideas to implement:
// load and store queue (supposed to be combined first) -- EC is figuring out how to have them separate
// head and tail pointers (circular if possible)
    // standard, indicate empty indicate full

// check address match vectors


// TLB
// lu addr and 


// Request the address 




// Format of entry:

// TODO: addr, whether load or store, valid addr, valid data
// Addr 48b
// Data 64b (relevant for stores, but for loads, just fill the 64 bits in)
// L or S 1b
// Valid 1b         // Related to finding the addr?
// Resolved 1b      // Related to finding the data? (store)
// Exec (operation completed) 1b
// Total: 48 + 64 + 1 + 1 + 1 = 115b TODO: fix this

// Queue (literal queue, no additional LSQ)
// Assume load and store queue both get 8 entries for 16 total entries
module queue #(parameter int N = 8) (
    input logic clk,
    input logic rst_n, // Assume active low reset

    input logic enqueue, // Signal to add an entry to the queue
    input logic dequeue, // Signal to remove an entry from the queue
    input logic [114:0] entry, // Either load or store entry

    output logic [$clog2(N)-1:0][114:0] entries, // I want to expose the inner workings of the queue for matching vectors
    output logic success,
);

logic [$clog2(N)-1:0] head = 0; // Head ptr
logic [$clog2(N)-1:0] tail = 0; // Tail ptr

// Check if full (tail has caught up with the head, so one index less than head, with wraparound)
logic is_full;
assign is_full = ((tail + 1) % N == head);
// Check if empty (tail is equal to the head)
logic is_empty;
assign is_empty = (tail == head);

// Synchronous
// Add entry and remove entries from the queue
always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin
        head <= 0;
        tail <= 0;
        success <= 0;
        // TODO: clear all entries at the beginning

    end else if (entry && !is_full && enqueue) begin   // Add entry to the queue if not full
        // Add entry to the queue at tail index
        entries[tail] <= entry;
        tail <= (tail + 1) % N; // Move tail ptr with wraparound
        success <= 1; // Indicate successful enqueue

    end else if (!is_empty && dequeue) begin // Remove entry from the queue if not empty (consider entry this resolved)
        // TODO: Remove entry at head index (return)
        head <= (head + 1) % N; // Move head ptr with wraparound
        success <= 1; // Indicate successful dequeue

    end else if (!enqueue && !dequeue) begin
        success <= 0; // No operation, clear success signal

    end else begin
        success <= 0; // Indicate unsuccessful enqueue/ dequeue (queue full or empty)
    end

end

endmodule : queue



// Enum provided by the assignment
typedef enum logic[2:0] {
    OP_MEM_LOAD = 0,    // Perform a memory load
    OP_MEM_STORE = 1,   // Send a memory store
    OP_MEM_RESOLVE = 2, // Resolve an unresolved address
    OP_TLB_FILL = 4     // Fill a line of the TLB 
} op_e;

// Load store queue (LSQ) (aka the controller module)
module lsq (
    input logic clk,
    input logic rst_n, // Assume active low rese

    // Signals predefined from the traces that get fed into the LSQ
    logic [120:0] trace_line, // Break this trace line into different components

    // Signls to the TLB

    // Signals to the L1 cache
);

op_e trace_op;
assign trace_op = trace_line[54:52];
logic [3:0] trace_id;
assign trace_id = trace_line[51:48];
logic [47:0] trace_vaddr;
assign trace_vaddr = trace_line[47:0];
logic trace_vaddr_is_valid;
assign trace_vaddr_is_valid = trace_line[55];   // Only relevant to mem operations
logic trace_value_is_valid;
assign trace_value_is_valid = trace_line[120];  // Only relevant to store operations
logic [63:0] trace_value;
assign trace_value = trace_line[119:56];        // Only relevant to store operations
logic [29:0] trace_tlb_paddr;
assign trace_tlb_paddr = trace_line[85:56];     // Only relevant to TLB fill operations

localparam int LOAD_QUEUE_SIZE = 8;
localparam int STORE_QUEUE_SIZE = 8;

// Load and store queues
wire [$clog2(LOAD_QUEUE_SIZE)-1:0][114:0] load_entries;
wire [$clog2(STORE_QUEUE_SIZE)-1:0][114:0] store_entries;

// Match bit vector

// Init load queue
queue #(.N(LOAD_QUEUE_SIZE)) load_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enqueue(), // TODO: connect enqueue signal
    .dequeue(), // TODO: connect dequeue signal
    .entry(),   // TODO: connect entry signal
    .entries(load_entries),
    .success(),
);

// Init store queue
queue #(.N(STORE_QUEUE_SIZE)) store_queue (
    .clk    (clk),
    .rst_n(rst_n),
    .enqueue(), // TODO: connect enqueue signal
    .dequeue(), // TODO: connect dequeue signal
    .entry(),   // TODO: connect entry signal
    .entries(store_entries),
    .success(),
);

// Basic operationsoperations
// 1. Find all operations that match EA (combinational)
// The entries from each queue are exposed for us to find matches
always_comb begin : match_addr
    // Synthesizeable for loop (parallel comparators)
    // https://verificationacademy.com/forums/t/synthesizable-loop/34146/2
    for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
        // TODO
    end

    for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
        // TODO
    end
end

// Synchronous
always_ff @(posedge clk or negedge rst_n) begin : controller
    if (!rst_n) begin
        // TODO

    end else begin
        // At any point in time of these operations,
        // Default to requesting from the TLB

        case (trace_op)
            OP_MEM_LOAD: begin
                end
            OP_MEM_STORE: begin
                end
            OP_MEM_RESOLVE: begin   // Resolve unresolved address
                end
            OP_TLB_FILL: begin  // Fill line in the TLB
                end
            default: begin
                // Do nothing for now
            end
    
end

// 2. Find all stores before load
// 3. Find all loads after store
// 4. Find all stores after store

// Any stores are RESOLVED on the clock (synchronous)
// Any loads are done NOT on the clock but updated based on stores (combinational?)
// Any stores are updated combinationally based on stores that get RESOLVED (combinational?)

// Store to load forwarding scan

// Scan earlier entries for stores



// Additional logic for load-store forwarding and stores updating future loads


endmodule : lsq
