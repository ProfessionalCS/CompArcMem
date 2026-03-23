`timescale 1ns/1ps
/* verilator lint_off EOFNEWLINE */
/* verilator lint_off WIDTHEXPAND */
module dtlb_tb;

    // ------------------------------------------------------------------
    // DUT parameters
    // ------------------------------------------------------------------
    localparam int unsigned NUM_ENTRIES = 16;
    localparam int unsigned VADDR_BITS  = 48;
    localparam int unsigned PADDR_BITS  = 30;
    localparam int unsigned PAGE_OFF    = 12;

    // ------------------------------------------------------------------
    // Signal declarations
    // ------------------------------------------------------------------
    logic                   clk, rst_n;
    logic                   lookup_req;
    logic [VADDR_BITS-1:0]  lookup_vaddr;
    logic                   lookup_hit;
    logic [PADDR_BITS-1:0]  lookup_paddr;
    logic                   fill_req;
    logic [VADDR_BITS-1:0]  fill_vaddr;
    logic [PADDR_BITS-1:0]  fill_paddr;

    // ------------------------------------------------------------------
    // DUT instantiation
    // ------------------------------------------------------------------
    dtlb #(
        .NUM_ENTRIES (NUM_ENTRIES),
        .VADDR_BITS  (VADDR_BITS),
        .PADDR_BITS  (PADDR_BITS),
        .PAGE_OFF    (PAGE_OFF)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_req_i   (lookup_req),
        .lookup_vaddr_i (lookup_vaddr),
        .lookup_hit_o   (lookup_hit),
        .lookup_paddr_o (lookup_paddr),
        .fill_req_i     (fill_req),
        .fill_vaddr_i   (fill_vaddr),
        .fill_paddr_i   (fill_paddr)
    );

    // Clock
    initial clk = 1'b0;
    always #5 clk <= ~clk;

    int pass_cnt, fail_cnt;

    // ------------------------------------------------------------------
    // Check helper
    // ------------------------------------------------------------------
    task automatic check(
        input string                name,
        input logic                 got_hit,
        input logic [PADDR_BITS-1:0] got_paddr,
        input logic                 exp_hit,
        input logic [PADDR_BITS-1:0] exp_paddr
    );
        if (got_hit !== exp_hit || (exp_hit && got_paddr !== exp_paddr)) begin
            $display("FAIL [%s]: hit=%b paddr=%08h | expected hit=%b paddr=%08h",
                     name, got_hit, got_paddr, exp_hit, exp_paddr);
            fail_cnt++;
        end else begin
            $display("PASS [%s]", name);
            pass_cnt++;
        end
    endtask

    // ------------------------------------------------------------------
    // Fill task
    // ------------------------------------------------------------------
    task automatic do_fill(
        input logic [VADDR_BITS-1:0] va,
        input logic [PADDR_BITS-1:0] pa
    );
        @(negedge clk);
        fill_req   = 1'b1;
        fill_vaddr = va;
        fill_paddr = pa;
        @(negedge clk);
        fill_req = 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Lookup task
    // ------------------------------------------------------------------
    task automatic do_lookup(
        input  logic [VADDR_BITS-1:0] va,
        output logic                  hit,
        output logic [PADDR_BITS-1:0] paddr
    );
        @(negedge clk);
        lookup_req   = 1'b1;
        lookup_vaddr = va;
        @(posedge clk); #1;
        lookup_req = 1'b0;
        hit   = lookup_hit;
        paddr = lookup_paddr;
    endtask

    // Convenience: build a virtual address from a VPN (zero page offset)
    function automatic logic [VADDR_BITS-1:0] make_vaddr(input int unsigned vpn);
        return VADDR_BITS'(vpn) << PAGE_OFF;
    endfunction

    // Convenience: build a physical address from a PPN (zero page offset)
    function automatic logic [PADDR_BITS-1:0] make_paddr(input int unsigned ppn);
        return PADDR_BITS'(ppn) << PAGE_OFF;
    endfunction

    logic                   h;
    logic [PADDR_BITS-1:0]  p;

    initial begin
        pass_cnt     = 0;
        fail_cnt     = 0;
        rst_n        = 1'b0;
        fill_req     = 1'b0;
        lookup_req   = 1'b0;
        fill_vaddr   = '0;
        fill_paddr   = '0;
        lookup_vaddr = '0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ------------------------------------------------------------------
        // Test 1: miss on empty TLB
        // ------------------------------------------------------------------
        do_lookup(VADDR_BITS'(48'h0000_1234_5000), h, p);
        check("miss_on_empty", h, p, 1'b0, '0);

        // ------------------------------------------------------------------
        // Test 2: fill then hit (same VPN, different offset)
        // VPN=0xABCDE, PPN=0x00042
        // ------------------------------------------------------------------
        do_fill(VADDR_BITS'(48'h0000_ABCD_E000),
                {(PADDR_BITS - PAGE_OFF)'(18'h00042), PAGE_OFF'(0)});
        do_lookup(VADDR_BITS'(48'h0000_ABCD_E0A0), h, p);
        check("fill_then_hit", h, p,
              1'b1, {(PADDR_BITS - PAGE_OFF)'(18'h00042), PAGE_OFF'(12'h0A0)});

        // ------------------------------------------------------------------
        // Test 3: different VPN -> miss
        // ------------------------------------------------------------------
        do_lookup(VADDR_BITS'(48'h0000_ABCD_F000), h, p);
        check("diff_vpn_miss", h, p, 1'b0, '0);

        // ------------------------------------------------------------------
        // Test 4: fill NUM_ENTRIES entries, verify all hit
        // ------------------------------------------------------------------
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            do_fill(make_vaddr(i), make_paddr(i + 1));
        end
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            // Lookup with offset 0x100 within the page
            do_lookup(make_vaddr(i) | VADDR_BITS'(12'h100), h, p);
            check($sformatf("full_tlb_hit_%0d", i), h, p,
                  1'b1, make_paddr(i + 1) | PADDR_BITS'(12'h100));
        end

        // ------------------------------------------------------------------
        // Test 5: (NUM_ENTRIES + 1)th fill causes eviction; new entry must hit
        // ------------------------------------------------------------------
        do_fill(VADDR_BITS'(48'h0001_0000_0000),
                {(PADDR_BITS - PAGE_OFF)'(18'h1DEAD & 18'h3FFFF), PAGE_OFF'(0)});
        do_lookup(VADDR_BITS'(48'h0001_0000_0200), h, p);
        check("evict_new_entry_hits", h, p,
              1'b1, {(PADDR_BITS - PAGE_OFF)'(18'h1DEAD & 18'h3FFFF), PAGE_OFF'(12'h200)});

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n=== %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        $finish;
    end

    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

/* verilator lint_off EOFNEWLINE */
/* verilator lint_off WIDTHEXPAND*/
endmodule