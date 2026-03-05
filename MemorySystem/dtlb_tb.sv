`timescale 1ns/1ps
/*verilator lint_off EOFNEWLINE */
module dtlb_tb;

    logic        clk, rst_n;
    logic        lookup_req;
    logic [47:0] lookup_vaddr;
    logic        lookup_hit;
    logic [29:0] lookup_paddr;
    logic        fill_req;
    logic [47:0] fill_vaddr;
    logic [29:0] fill_paddr;

    dtlb dut (
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

    // -------------------------------------------------------------------------
    // Check helper
    // -------------------------------------------------------------------------
    task automatic check(
        input string       name,
        input logic        got_hit,
        input logic [29:0] got_paddr,
        input logic        exp_hit,
        input logic [29:0] exp_paddr
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

    // -------------------------------------------------------------------------
    // Fill task — blocking assignments, runs inside initial block
    // -------------------------------------------------------------------------
    task automatic do_fill(input logic [47:0] va, input logic [29:0] pa);
        @(negedge clk);
        fill_req   = 1'b1;
        fill_vaddr = va;
        fill_paddr = pa;
        @(negedge clk);
        fill_req = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Lookup task — output is registered, valid one cycle after request
    // -------------------------------------------------------------------------
    task automatic do_lookup(
        input  logic [47:0] va,
        output logic        hit,
        output logic [29:0] paddr
    );
        @(negedge clk);
        lookup_req   = 1'b1;
        lookup_vaddr = va;
        @(posedge clk); #1;  // sample after rising edge where output is registered
        lookup_req = 1'b0;
        hit   = lookup_hit;
        paddr = lookup_paddr;
    endtask

    logic       h;
    logic[29:0] p;

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
        do_lookup(48'h0000_1234_5000, h, p);
        check("miss_on_empty", h, p, 1'b0, 30'h0);

        // ------------------------------------------------------------------
        // Test 2: fill then hit (same VPN, different offset)
        // VPN=0xABCDE, PPN=0x00042
        // ------------------------------------------------------------------
        do_fill(48'h0000_ABCD_E000, {18'h00042, 12'h0});
        do_lookup(48'h0000_ABCD_E0A0, h, p);
        check("fill_then_hit", h, p, 1'b1, {18'h00042, 12'h0A0});

        // ------------------------------------------------------------------
        // Test 3: different VPN -> miss
        // ------------------------------------------------------------------
        do_lookup(48'h0000_ABCD_F000, h, p);
        check("diff_vpn_miss", h, p, 1'b0, 30'h0);

        // ------------------------------------------------------------------
        // Test 4: fill 16 entries, verify all hit
        // ------------------------------------------------------------------
        for (int i = 0; i < 16; i++) begin
            do_fill(48'(i * 48'h1000), {18'(i + 1), 12'h0});
        end
        for (int i = 0; i < 16; i++) begin
            do_lookup(48'(i * 48'h1000 + 48'h100), h, p);
            check($sformatf("full_tlb_hit_%0d", i), h, p,
                  1'b1, {18'(i + 1), 12'h100});
        end

        // ------------------------------------------------------------------
        // Test 5: 17th fill causes eviction; new entry must hit
        // ------------------------------------------------------------------
        do_fill(48'h0001_0000_0000, {18'h1DEAD & 18'h3FFFF, 12'h0});
        do_lookup(48'h0001_0000_0200, h, p);
        check("evict_new_entry_hits", h, p,
              1'b1, {18'h1DEAD & 18'h3FFFF, 12'h200});

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
/*verilator lint_off EOFNEWLINE */
endmodule
