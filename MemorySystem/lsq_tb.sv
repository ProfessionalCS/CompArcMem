/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
`timescale 1ns/1ps

module lsq_tb;

    logic clk, rst_n;
    logic [120:0] trace_line;

    // Requests from LSQ to the TLB
    logic lsq_tlb_req;
    logic [47:0] lsq_tlb_vaddr;

    // Known addr translations
    // Don't touch these in the TB, they will get forwarded from the LSQ to the TLB
    logic lsq_tlb_fill;
    logic [47:0] lsq_tlb_vaddr_fill;
    logic [29:0] lsq_tlb_paddr_fill;

    // TLB outputs
    logic tlb_lookup_hit;
    logic [29:0] tlb_lookup_paddr;

    lsq #(.N(16)) dut_lsq (
        .clk (clk),
        .rst_n (rst_n),
        .trace_line (trace_line),
        .tlb_req (lsq_tlb_req),         // Lookup
        .tlb_vaddr (lsq_tlb_vaddr),     // Lookup
        .tlb_hit(tlb_lookup_hit),
        .tlb_paddr(tlb_lookup_paddr),
        .tlb_fill(lsq_tlb_fill),                // FF 
        .fill_tlb_paddr(lsq_tlb_paddr_fill),    // FF
        .fill_tlb_vaddr(lsq_tlb_vaddr_fill)     // FF
    );

    dtlb dut_tlb (
        .clk (clk),
        .rst_n (rst_n),
        // Lookup (from LSQ)
        .lookup_req_i (lsq_tlb_req),        // LSQ asks for translation 
        .lookup_vaddr_i (lsq_tlb_vaddr),    // VADDR from LSQ 
        .lookup_hit_o (tlb_lookup_hit),
        .lookup_paddr_o (tlb_lookup_paddr),
        // Fill (forwarded from LSQ or from TB)
        .fill_req_i (lsq_tlb_fill),
        .fill_vaddr_i (lsq_tlb_vaddr_fill),
        .fill_paddr_i (lsq_tlb_paddr_fill)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Entry fields (should match lsq.sv)
    localparam int ENTRY_SIZE = 125;
    localparam int VALID_IDX = 124;
    localparam int RESOLVED_IDX = 123;
    localparam int EA_IDX = 122;
    localparam int EA_SIZE = 48;
    localparam int VVALID_IDX = 74;
    localparam int DATA_IDX = 73;
    localparam int DATA_SIZE = 64;
    localparam int TRACE_ID_IDX = 9;
    localparam int SQ_TAIL_IDX = 5;
    localparam int LQ_TAIL_IDX = 2;

    // Hierarchical references -> get access LSQ internal signals
    // https://forums.accellera.org/topic/2073-how-to-access-verilog-module-internal-signals-in-uvm-testbench/
    wire [7:0][ENTRY_SIZE-1:0] load_entries = dut_lsq.load_entries;
    wire [7:0][ENTRY_SIZE-1:0] store_entries = dut_lsq.store_entries;
    wire [2:0] load_head = dut_lsq.load_head;
    wire [2:0] load_tail = dut_lsq.load_tail;
    wire [2:0] store_head = dut_lsq.store_head;
    wire [2:0] store_tail = dut_lsq.store_tail;
    wire load_success = dut_lsq.load_success;
    wire store_success = dut_lsq.store_success;
    wire [7:0] final_stores_before_load = dut_lsq.final_stores_before_load;
    wire [7:0] final_loads_after_store = dut_lsq.final_loads_after_store;
    wire [7:0] final_stores_after_store = dut_lsq.final_stores_after_store;

    // Test counters
    int pass_count, fail_count;

    // ----------------------------------------------------------------------------------------------------
    //
    // Helpers
    //    
    // ----------------------------------------------------------------------------------------------------

    function automatic logic [120:0] make_trace (
        input logic [2:0]  op_val,
        input logic [3:0]  tid,
        input logic [47:0] vaddr,
        input logic va_valid,
        input logic [63:0] val,
        input logic vv, // Value valid
        input logic [29:0] paddr // TLB stuff
    );
        logic [120:0] t = '0;
        t[47:0]   = vaddr;
        t[51:48]  = tid;
        t[54:52]  = op_val;
        t[55]     = va_valid;
        // val [119:56] and paddr [85:56] overlap — they are mutually exclusive
        // by design (TLB_FILL uses paddr, STORE uses val, never both).
        // Write val first so that paddr overwrites the overlapping bits last.
        t[119:56] = val;
        t[85:56]  = paddr;
        t[120]    = vv;

        return t;
    endfunction

    // Drive a trace, wait at least 3 rising edges for everything to complet:
    // TODO: might need to account for more cycles as we add the other caches?
    // Cycle 1: trace_id change detected, registers latches in LSQ
    // Cycle 2: enqueue/update fires to the queue (between cycle 1 and cycle 2, parallel comb logic will exec)
    // Cycle 3: combinational forwarding vectors will settle and be ready to latch again/ read
    task automatic drive_trace (
        input logic [120:0] tl
    );
        @(negedge clk); // Prep on negedge so that LSQ gets on posedge
        trace_line = tl;
        repeat(3) @(posedge clk); // Wait on 3 posedge clks 
        #1; // Wait 
    endtask

    task automatic drive_trace_idle (
        input logic [120:0] tl
    );
        drive_trace(tl);
        @(negedge clk); // Prep
        trace_line = '0;  // Idle after driving the trace (give some breathing room in between firing different traces)
        @(posedge clk); // Lock-in trace
        #1; // Wait
    endtask

    task automatic do_reset ();
        @(negedge clk); // Prep
        rst_n = 1'b0; 
        trace_line = '0;
        repeat(4) @(posedge clk); // Clear the window (3 cycles + 1 additional cycle)
        @(negedge clk); // Prep again
        rst_n = 1'b1; // Void reset
        @(posedge clk); // Lock-in reset
        #1; // Wait
    endtask

    // Just reference the TLB TB code
    task automatic do_tlb_lookup (
        input  logic [47:0] va,
        output logic hit,
        output logic [29:0] paddr
    );
        @(negedge clk);
        lsq_tlb_req = 1'b1; // Prep request
        lsq_tlb_vaddr = va; // Prep addr
        @(posedge clk); #1; // Sample after rising edge where output is registered
        lsq_tlb_req = 1'b0; // Clear request
        hit = tlb_lookup_hit; // Check for TLB hits
        paddr = tlb_lookup_paddr; // Grab the physical addr
    endtask

    // ----------------------------------------------------------------------------------------------------
    //
    // Check helpers
    //
    // ----------------------------------------------------------------------------------------------------
    // General checker for bits
    task automatic check_bool (
        input string name, 
        input logic got, 
        input logic exp
    );
        if (got !== exp) begin 
            $display("FAIL [%s]  got=%b  expected=%b", name, got, exp); 
            fail_count++; 
        
        end else begin 
            $display("PASS [%s]  val=%b", name, got); 
            pass_count++; 
        end

    endtask

    // Checking the data
    task automatic check_val (
        input string name, 
        input logic [63:0] got, 
        input logic [63:0] exp    
    );
        if (got !== exp) begin 
            $display("FAIL [%s]  got=0x%016h  expected=0x%016h", name, got, exp); 
            fail_count++; 
        
        end else begin 
            $display("  PASS [%s]  val=0x%016h", name, got); 
            pass_count++; 
        end

    endtask

    // ----------------------------------------------------------------------------------------------------
    //
    // Dump helpers
    //
    // ----------------------------------------------------------------------------------------------------
    task automatic dump_load_queue ();
        $display("[LQ] head=%0d  tail=%0d  success=%b", load_head, load_tail, load_success);
        for (int i = 0; i < 8; i++)
            $display("      LQ[%0d] V=%b  R=%b  tid=%h  ea=%012h  vval=%b  data=%016h  sq_tail=%0d  lq_tail=%0d",
                i,
                load_entries[i][VALID_IDX],
                load_entries[i][RESOLVED_IDX],
                load_entries[i][TRACE_ID_IDX-:4],
                load_entries[i][EA_IDX-:EA_SIZE],
                load_entries[i][VVALID_IDX],
                load_entries[i][DATA_IDX-:DATA_SIZE],
                load_entries[i][SQ_TAIL_IDX-:3],
                load_entries[i][LQ_TAIL_IDX-:3]);
    endtask

    task automatic dump_store_queue ();
        $display("[SQ] head=%0d  tail=%0d  success=%b", store_head, store_tail, store_success);
        for (int i = 0; i < 8; i++)
            $display("      SQ[%0d] V=%b  R=%b  tid=%h  ea=%012h  vval=%b  data=%016h  sq_tail=%0d  lq_tail=%0d",
                i,
                store_entries[i][VALID_IDX],
                store_entries[i][RESOLVED_IDX],
                store_entries[i][TRACE_ID_IDX-:4],
                store_entries[i][EA_IDX-:EA_SIZE],
                store_entries[i][VVALID_IDX],
                store_entries[i][DATA_IDX-:DATA_SIZE],
                store_entries[i][SQ_TAIL_IDX-:3],
                store_entries[i][LQ_TAIL_IDX-:3]);
    endtask

    // Checking forwarding logic
    task automatic dump_fwd ();
        $display("[FWD] stores_before_load=%08b  loads_after_store=%08b  stores_after_store=%08b",
                 final_stores_before_load, 
                 final_loads_after_store, 
                 final_stores_after_store);
    endtask

    // ----------------------------------------------------------------------------------------------------
    //
    // Main
    //
    // ----------------------------------------------------------------------------------------------------
    logic [120:0] tl; // Trace
    logic h; // 
    logic [29:0] p;

    initial begin
        pass_count = 0; 
        fail_count = 0;
        do_reset();

        $display("================= LSQ + dTLB Testbench =================");

        // -------------------------------------------------------------------------
        // TC1: TLB Fill + Lookup
        //
        // Force LSQ to raise TLB_req and output the physical addr on tlb_paddr
        // dTLB needs to VPN -> PPN to get the PA
        // Mapping: vaddr page 0xDEADB xxx  ->  ppn 0x12345
        //   lookup  0xDEADB_0A0  should return  0x12345_0A0
        // -------------------------------------------------------------------------
        $display("\nTC1: TLB fill + lookup");

        tl = make_trace(3'd4, 4'h1, 48'hDEAD_B000, 1'b0, '0, 1'b0, {18'h12345, 12'h0});
        
        // Start driving
        @(negedge clk); trace_line = tl;
        
        // The LSQ processes on the next posedge
        // We wait for that posedge + a tiny margin to sample the OUTPUT of the LSQ.
        @(posedge clk);
        #1; 

        // Check while the trace is still active and the LSQ is asserting the fill
        check_bool("TC1a_lsq_raises_tlb_fill", lsq_tlb_fill, 1'b1);
        check_val ("TC1b_lsq_outputs_correct_paddr", {34'b0, lsq_tlb_paddr_fill}, {34'b0, 30'({18'h12345, 12'h0})});

        // Now it is safe to go to idle
        trace_line = '0;
        repeat(2) @(posedge clk);

        // Test the lookup
        do_tlb_lookup(48'hDEAD_B0A0, h, p);
        $display("  Lookup vaddr=0xDEADB0A0: hit=%b, paddr=0x%h", h, p);
        check_bool("TC1c_tlb_lookup_hits", h, 1'b1);
        check_val ("TC1d_tlb_paddr_has_right_ppn", {34'b0, p}, {34'b0, 30'({18'h12345, 12'h0A0})});
        
        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n========================================================");
        $display("%0d PASSED   %0d FAILED", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
            
        end else begin 
            $display("SOME TESTS FAILED, SEE FAILED CASES ABOVE");
        end
        $display("========================================================\n");
        $finish;
    end

    // Terminate if runs for too long
    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
