`timescale 1ns/1ps
// Page size : configurable via PAGE_OFF (default 12 = 4 KiB)
// VPN       : VADDR_BITS - PAGE_OFF bits
// PPN       : PADDR_BITS - PAGE_OFF bits

/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND*/
module dtlb #(
    parameter int unsigned NUM_ENTRIES = 16,   // must be a power of 2
    parameter int unsigned VADDR_BITS  = 48,
    parameter int unsigned PADDR_BITS  = 30,
    parameter int unsigned PAGE_OFF    = 12    // log2(page size), e.g. 12 = 4 KiB pages
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // Lookup port
    input  logic                  lookup_req_i,
    input  logic [VADDR_BITS-1:0] lookup_vaddr_i,

    // Output
    output logic                  lookup_hit_o,
    output logic [PADDR_BITS-1:0] lookup_paddr_o,

    // Fill port (from OP_TLB_FILL trace entries)
    // lower PAGE_OFF bits of fill_vaddr_i and fill_paddr_i are page offset, unused
    input  logic                  fill_req_i,
    input  logic [VADDR_BITS-1:0] fill_vaddr_i,
    input  logic [PADDR_BITS-1:0] fill_paddr_i
);
/* verilator lint_on UNUSEDSIGNAL */

    //parameters
    localparam int unsigned VPN_BITS       = VADDR_BITS - PAGE_OFF;
    localparam int unsigned PPN_BITS       = PADDR_BITS - PAGE_OFF;
    localparam int unsigned PLRU_BITS      = NUM_ENTRIES - 1;
    localparam int unsigned IDX_BITS       = $clog2(NUM_ENTRIES);
    localparam int unsigned DEPTH          = $clog2(NUM_ENTRIES); // tree depth = log2(N)
    localparam int unsigned PLRU_LEAF_BASE = NUM_ENTRIES / 2 - 1;

    // Elaboration-time sanity check
    initial begin
        assert ((NUM_ENTRIES & (NUM_ENTRIES - 1)) == 0)
            else $fatal(1, "dtlb: NUM_ENTRIES (%0d) must be a power of 2", NUM_ENTRIES);
        assert (NUM_ENTRIES >= 2)
            else $fatal(1, "dtlb: NUM_ENTRIES must be at least 2");
        assert (VADDR_BITS > PAGE_OFF)
            else $fatal(1, "dtlb: VADDR_BITS must be greater than PAGE_OFF");
        assert (PADDR_BITS > PAGE_OFF)
            else $fatal(1, "dtlb: PADDR_BITS must be greater than PAGE_OFF");
    end

    // TLB storage
    logic                valid [NUM_ENTRIES];
    logic [VPN_BITS-1:0] vpn   [NUM_ENTRIES];
    logic [PPN_BITS-1:0] ppn   [NUM_ENTRIES];
    logic [PLRU_BITS-1:0] plru_tree;

    // Lookup hit detection (combinational)
    logic [VPN_BITS-1:0]    lookup_vpn;
    assign lookup_vpn = lookup_vaddr_i[VADDR_BITS-1:PAGE_OFF];

    logic [NUM_ENTRIES-1:0] hit_vec;
    logic [IDX_BITS-1:0]    hit_idx;
    logic                   any_hit;

    genvar g;
    generate
        for (g = 0; g < NUM_ENTRIES; g++) begin : gen_hit
            assign hit_vec[g] = valid[g] & (vpn[g] == lookup_vpn);
        end
    endgenerate

    always_comb begin
        hit_idx = '0;
        any_hit = 1'b0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (hit_vec[i]) begin
                hit_idx = IDX_BITS'(i);
                any_hit = 1'b1;
            end
        end
    end

    // Fill hit detection (combinational)
    logic [VPN_BITS-1:0] fill_vpn;
    logic [PPN_BITS-1:0] fill_ppn;
    assign fill_vpn = fill_vaddr_i[VADDR_BITS-1:PAGE_OFF];
    assign fill_ppn = fill_paddr_i[PADDR_BITS-1:PAGE_OFF];

    logic [NUM_ENTRIES-1:0] fill_hit_vec;
    logic [IDX_BITS-1:0]    fill_hit_idx;
    logic                   fill_any_hit;

    generate
        for (g = 0; g < NUM_ENTRIES; g++) begin : gen_fill_hit
            assign fill_hit_vec[g] = valid[g] & (vpn[g] == fill_vpn);
        end
    endgenerate

    always_comb begin
        fill_hit_idx = '0;
        fill_any_hit = 1'b0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (fill_hit_vec[i]) begin
                fill_hit_idx = IDX_BITS'(i);
                fill_any_hit = 1'b1;
            end
        end
    end

    // First invalid slot (for cold fills)
    logic [IDX_BITS-1:0] first_invalid;
    logic                any_invalid;

    always_comb begin
        first_invalid = '0;
        any_invalid   = 1'b0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (!valid[i] && !any_invalid) begin
                first_invalid = IDX_BITS'(i);
                any_invalid   = 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Pseudo-LRU victim selection (parameterised tree walk)
    //
    // Tree node layout (0-indexed), generalised for any power-of-2 NUM_ENTRIES:
    //   node 0                                     : root
    //   nodes 1..2                                 : level 1
    //   ...
    //   nodes PLRU_LEAF_BASE..PLRU_BITS-1          : leaf-level nodes (each governs a pair)
    //
    // Walk descends DEPTH-1 levels from root, then decodes the final leaf node.
    // Bit=0 -> go left (lower index); Bit=1 -> go right (higher index)
    // ------------------------------------------------------------------
    logic [IDX_BITS-1:0] victim_idx;

    always_comb begin
        logic [IDX_BITS-1:0] curr;
        curr = '0;  // start at root
        // Descend DEPTH-1 levels to reach the leaf-level node
        for (int d = 0; d < DEPTH - 1; d++)
            curr = plru_tree[curr] ? IDX_BITS'(curr * 2 + 2) : IDX_BITS'(curr * 2 + 1);
        // Decode which of the two entries the leaf node points to
        victim_idx = plru_tree[curr]
                        ? IDX_BITS'((curr - IDX_BITS'(PLRU_LEAF_BASE)) * 2 + 1)
                        : IDX_BITS'((curr - IDX_BITS'(PLRU_LEAF_BASE)) * 2);
    end

    // Pseudo-LRU update function (parameterised walk from leaf to root)
    // Flips nodes along the leaf->root path to point AWAY from accessed entry.
    function automatic logic [PLRU_BITS-1:0] plru_update(
        input logic [PLRU_BITS-1:0] tree,
        input logic [IDX_BITS-1:0]  idx
    );
        logic [PLRU_BITS-1:0] t;
        logic [IDX_BITS-1:0]  node, parent;

        t    = tree;
        // Leaf-level node governing this entry: PLRU_LEAF_BASE + idx/2
        node    = IDX_BITS'(PLRU_LEAF_BASE) + IDX_BITS'({1'b0, idx[IDX_BITS-1:1]});
        t[node] = ~idx[0];  // point away from this leaf
        // Walk up DEPTH-1 edges to reach and update the root
        for (int d = 0; d < DEPTH - 1; d++) begin
            parent    = IDX_BITS'((node - 1) >> 1);
            t[parent] = (node == IDX_BITS'(parent * 2 + 2)) ? 1'b0 : 1'b1;
            node      = parent;
        end
        return t;
    endfunction

    // Fill write index selection
    logic [IDX_BITS-1:0] fill_write_idx;
    always_comb begin
        if      (fill_any_hit) fill_write_idx = fill_hit_idx;
        else if (any_invalid)  fill_write_idx = first_invalid;
        else                   fill_write_idx = victim_idx;
    end

    // Sequential state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                valid[i] <= 1'b0;
                vpn[i]   <= '0;
                ppn[i]   <= '0;
            end
            plru_tree      <= '0;
            lookup_hit_o   <= 1'b0;
            lookup_paddr_o <= '0;
        end else begin

            // Fill: write new translation
            if (fill_req_i) begin
                valid[fill_write_idx] <= 1'b1;
                vpn  [fill_write_idx] <= fill_vpn;
                ppn  [fill_write_idx] <= fill_ppn;
                plru_tree <= plru_update(plru_tree, fill_write_idx);
            end

            // Lookup: register output, update PLRU
            lookup_hit_o <= lookup_req_i & any_hit;
            if (lookup_req_i && any_hit) begin
                lookup_paddr_o <= {ppn[hit_idx], lookup_vaddr_i[PAGE_OFF-1:0]};
                if (fill_req_i)
                    plru_tree <= plru_update(plru_update(plru_tree, fill_write_idx), hit_idx);
                else
                    plru_tree <= plru_update(plru_tree, hit_idx);
            end else begin
                lookup_paddr_o <= '0;
            end

        end
    end
/* verilator lint_off WIDTHEXPAND*/
/* verilator lint_off EOFNEWLINE */
endmodule