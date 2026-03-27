`timescale 1ns/1ps
/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off BLKSEQ */

// ════════════════════════════════════════════════════════════════════════════
// L2_lru — L2 cache with FIFO replacement policy (for MPKI comparison)
//
//   Carbon copy of L2_copy.sv with Tree-PLRU swapped for FIFO replacement.
//   FIFO: each set has a pointer to the next way to evict; pointer advances
//   on every install regardless of access pattern (no hit updates).
//
//   Prints MPKI stats at end of simulation for comparison vs L2_copy (PLRU).
// ════════════════════════════════════════════════════════════════════════════

module L2_lru #(
    parameter int WAYS        = 4,       // associativity
    parameter int SETS        = 16,      // number of sets
    parameter int MSHR_COUNT  = 4,       // outstanding miss trackers
    parameter int MEM_LINES   = 4096,    // backing-memory depth (lines)
    parameter int MEM_LATENCY = 3,       // memory-fetch cycles (sim only)
    parameter bit USE_AVALON  = 1'b0     // 0 = sim backing_mem, 1 = external Avalon
)(
    input  logic         clk,
    input  logic         rst_n,

    // ── L1 read-miss interface ──────────────────────────────────────────
    input  logic         l2_req_valid,
    input  logic [29:0]  l2_req_addr,
    output logic         l2_resp_valid,
    output logic [511:0] l2_resp_data,

    // ── L1 dirty-writeback interface ────────────────────────────────────
    input  logic         wb_valid,
    input  logic [29:0]  wb_addr,
    input  logic [511:0] wb_data,

    // ── External memory interface (active only when USE_AVALON=1) ──────
    output logic         ext_mem_rd_req,
    output logic [23:0]  ext_mem_rd_addr,
    input  logic         ext_mem_rd_valid,
    input  logic [511:0] ext_mem_rd_data,
    output logic         ext_mem_wr_req,
    output logic [23:0]  ext_mem_wr_addr,
    output logic [511:0] ext_mem_wr_data,
    input  logic         ext_mem_wr_done,
    input  logic         ext_mem_busy
);

localparam bit L2_VERBOSE = 1'b0;

// ━━━ Derived geometry ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
localparam int WAY_W     = $clog2(WAYS);
localparam int INDEX_W   = $clog2(SETS);
localparam int TAG_W     = 24 - INDEX_W;
localparam int MEM_IDX_W = $clog2(MEM_LINES);
localparam int MSHR_ID_W = (MSHR_COUNT > 1) ? $clog2(MSHR_COUNT) : 1;
localparam logic [3:0] MEM_LAT_INIT = MEM_LATENCY - 1;

// ━━━ Cache arrays ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
logic [511:0]      data_array  [0:WAYS-1][0:SETS-1];
logic [TAG_W-1:0]  tag_array   [0:WAYS-1][0:SETS-1];
logic              valid_array [0:WAYS-1][0:SETS-1];
logic              dirty_array [0:WAYS-1][0:SETS-1];

// ── FIFO replacement: one pointer per set (wraps mod WAYS) ──────────────
logic [WAY_W-1:0] fifo_ptr [0:SETS-1];

// ━━━ MSHR ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
typedef struct packed {
    logic valid;
    logic [23:0] block_addr;
    logic mem_sent;
} mshr_t;

mshr_t mshr [0:MSHR_COUNT-1];

// ━━━ Backing memory (sim only) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
localparam int ACTUAL_MEM_LINES = USE_AVALON ? 1 : MEM_LINES;
logic [511:0] backing_mem [0:ACTUAL_MEM_LINES-1];

logic                  mem_busy;
logic [3:0]            mem_counter;
logic [23:0]           mem_pend_addr;
logic [MSHR_ID_W-1:0] mem_pend_id;

// ━━━ Avalon eviction FIFO ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
logic [1:0]   evict_valid;
logic [23:0]  evict_addr  [0:1];
logic [511:0] evict_data  [0:1];
logic         evict_pending;
assign evict_pending = |evict_valid;
logic         evict_full;
assign evict_full = &evict_valid;

logic         avm_rd_arrived;

// ━━━ Input-stage registers ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
logic         s1_req_valid;
logic [29:0]  s1_req_addr;
logic         s1_wb_valid;
logic [29:0]  s1_wb_addr;
logic [511:0] s1_wb_data;

// ━━━ Deferred buffers ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
logic         defer_valid;
logic [511:0] defer_data;
logic         defer_wb_valid;
logic [29:0]  defer_wb_addr;
logic [511:0] defer_wb_data;

// ━━━ Address decode ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
logic [23:0]        s1_req_blk;
logic [INDEX_W-1:0] s1_req_idx;
logic [TAG_W-1:0]   s1_req_tag;

assign s1_req_blk = s1_req_addr[29:6];
assign s1_req_idx = s1_req_blk[INDEX_W-1:0];
assign s1_req_tag = s1_req_blk[23:INDEX_W];

logic [23:0]        s1_wb_blk;
logic [INDEX_W-1:0] s1_wb_idx;
logic [TAG_W-1:0]   s1_wb_tag;

assign s1_wb_blk = s1_wb_addr[29:6];
assign s1_wb_idx = s1_wb_blk[INDEX_W-1:0];
assign s1_wb_tag = s1_wb_blk[23:INDEX_W];

// ━━━ Tag-hit detection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
logic [WAYS-1:0]  s1_req_way_hit;
logic             s1_req_hit;
logic [WAY_W-1:0] s1_req_hit_w;

always_comb begin
    for (int i = 0; i < WAYS; i++)
        s1_req_way_hit[i] = valid_array[i][s1_req_idx] &&
                             (tag_array[i][s1_req_idx] == s1_req_tag);
    s1_req_hit = |s1_req_way_hit;
    s1_req_hit_w = '0;
    for (int i = WAYS-1; i >= 0; i--)
        if (s1_req_way_hit[i]) s1_req_hit_w = i[WAY_W-1:0];
end

logic [WAYS-1:0]  s1_wb_way_hit;
logic             s1_wb_hit;
logic [WAY_W-1:0] s1_wb_hit_w;

always_comb begin
    for (int i = 0; i < WAYS; i++)
        s1_wb_way_hit[i] = valid_array[i][s1_wb_idx] &&
                            (tag_array[i][s1_wb_idx] == s1_wb_tag);
    s1_wb_hit = |s1_wb_way_hit;
    s1_wb_hit_w = '0;
    for (int i = WAYS-1; i >= 0; i--)
        if (s1_wb_way_hit[i]) s1_wb_hit_w = i[WAY_W-1:0];
end

// ━━━ FIFO replacement helpers ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Pick install way: first invalid, else FIFO victim (no hit-update needed)
function automatic logic [WAY_W-1:0] find_install_way(
    input logic [INDEX_W-1:0] sidx
);
    logic found;
    found = 1'b0;
    for (int i = 0; i < WAYS; i++) begin
        if (!valid_array[i][sidx] && !found) begin
            find_install_way = i[WAY_W-1:0];
            found = 1'b1;
        end
    end
    if (!found)
        find_install_way = fifo_ptr[sidx];  // FIFO victim
endfunction

// ━━━ MPKI counters (simulation only) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
`ifndef SYNTHESIS
integer mpki_accesses;
integer mpki_misses;

initial begin
    mpki_accesses = 0;
    mpki_misses   = 0;
end

final begin
    $display("[L2_lru  FIFO] accesses=%0d  misses=%0d  MPKI=%.2f",
        mpki_accesses, mpki_misses,
        (mpki_accesses > 0) ? (1000.0 * mpki_misses / mpki_accesses) : 0.0);
end
`endif

// ━━━ Main sequential logic ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        l2_resp_valid  <= 1'b0;
        l2_resp_data   <= '0;
        s1_req_valid   <= 1'b0;
        s1_req_addr    <= '0;
        s1_wb_valid    <= 1'b0;
        s1_wb_addr     <= '0;
        s1_wb_data     <= '0;
        defer_valid    <= 1'b0;
        defer_data     <= '0;
        defer_wb_valid <= 1'b0;
        defer_wb_addr  <= '0;
        defer_wb_data  <= '0;
        mem_busy       <= 1'b0;
        mem_counter    <= '0;
        mem_pend_addr  <= '0;
        mem_pend_id    <= '0;
        evict_valid    <= 2'b00;
        evict_addr[0]  <= '0;
        evict_addr[1]  <= '0;
        evict_data[0]  <= '0;
        evict_data[1]  <= '0;
        avm_rd_arrived <= 1'b0;
        ext_mem_rd_req  <= 1'b0;
        ext_mem_rd_addr <= '0;
        ext_mem_wr_req  <= 1'b0;
        ext_mem_wr_addr <= '0;
        ext_mem_wr_data <= '0;

        for (int i = 0; i < MSHR_COUNT; i++) begin
            mshr[i].valid      <= 1'b0;
            mshr[i].block_addr <= '0;
            mshr[i].mem_sent   <= 1'b0;
        end
        for (int w = 0; w < WAYS; w++)
            for (int s = 0; s < SETS; s++) begin
                valid_array[w][s] <= 1'b0;
                dirty_array[w][s] <= 1'b0;
                tag_array[w][s]   <= '0;
                data_array[w][s]  <= '0;
            end
        for (int s = 0; s < SETS; s++)
            fifo_ptr[s] <= '0;   // FIFO: reset all pointers to way 0

    end else begin : process
        logic refill_active;
        logic [INDEX_W-1:0] refill_set;
        refill_active = 1'b0;
        refill_set    = '0;

        // ── Stage 0: Capture inputs ──────────────────────────────────────
        s1_req_valid <= l2_req_valid;
        s1_req_addr  <= l2_req_addr;
        s1_wb_valid  <= wb_valid;
        s1_wb_addr   <= wb_addr;
        s1_wb_data   <= wb_data;

        // ── MPKI: count every new request ────────────────────────────────
        `ifndef SYNTHESIS
        if (l2_req_valid) mpki_accesses <= mpki_accesses + 1;
        `endif

        // ── Default ──────────────────────────────────────────────────────
        l2_resp_valid  <= 1'b0;
        ext_mem_rd_req <= 1'b0;
        ext_mem_wr_req <= 1'b0;

        // ════════════════════════════════════════════════════════════════
        //  A: Deferred hit
        // ════════════════════════════════════════════════════════════════
        if (defer_valid) begin
            l2_resp_valid <= 1'b1;
            l2_resp_data  <= defer_data;
            defer_valid   <= 1'b0;
        end

        // ════════════════════════════════════════════════════════════════
        //  B: Memory refill completing
        // ════════════════════════════════════════════════════════════════
        else if (USE_AVALON
                 ? (mem_busy && ext_mem_rd_valid)
                 : (mem_busy && mem_counter == 0)) begin
            logic [23:0]        fill_blk;
            logic [INDEX_W-1:0] fill_idx;
            logic [TAG_W-1:0]   fill_tag;
            logic [WAY_W-1:0]   fill_way;
            logic [511:0]       fill_data;

            fill_blk  = mshr[mem_pend_id].block_addr;
            fill_idx  = fill_blk[INDEX_W-1:0];
            fill_tag  = fill_blk[23:INDEX_W];
            fill_way  = find_install_way(fill_idx);

            if (USE_AVALON)
                fill_data = ext_mem_rd_data;
            else
                fill_data = backing_mem[fill_blk[MEM_IDX_W-1:0]];

            refill_active = 1'b1;
            refill_set    = fill_idx;

            // Evict dirty victim
            if (valid_array[fill_way][fill_idx] &&
                dirty_array[fill_way][fill_idx]) begin
                logic [23:0] evict_blk_local;
                evict_blk_local = {tag_array[fill_way][fill_idx], fill_idx};
                if (USE_AVALON) begin
                    if (!evict_valid[0]) begin
                        evict_valid[0] <= 1'b1;
                        evict_addr[0]  <= evict_blk_local;
                        evict_data[0]  <= data_array[fill_way][fill_idx];
                    end else begin
                        evict_valid[1] <= 1'b1;
                        evict_addr[1]  <= evict_blk_local;
                        evict_data[1]  <= data_array[fill_way][fill_idx];
                    end
                end else begin
                    backing_mem[evict_blk_local[MEM_IDX_W-1:0]] <= data_array[fill_way][fill_idx];
                end
            end

            // Install fetched line
            data_array[fill_way][fill_idx]  <= fill_data;
            tag_array[fill_way][fill_idx]   <= fill_tag;
            valid_array[fill_way][fill_idx] <= 1'b1;
            dirty_array[fill_way][fill_idx] <= 1'b0;
            // FIFO: advance pointer only when evicting (set is full)
            if (&({WAYS{valid_array[0][fill_idx]}} & {WAYS{1'b1}})) begin
                // All ways valid → we used FIFO victim → advance pointer
                fifo_ptr[fill_idx] <= fifo_ptr[fill_idx] + WAY_W'(1);
            end

            l2_resp_valid <= 1'b1;
            l2_resp_data  <= fill_data;

            mshr[mem_pend_id].valid <= 1'b0;
            mem_busy <= 1'b0;

            // Collision: read request also pending in stage-1
            if (s1_req_valid && s1_req_hit) begin
                defer_valid <= 1'b1;
                defer_data  <= data_array[s1_req_hit_w][s1_req_idx];
            end else if (s1_req_valid && !s1_req_hit) begin
                logic mshr_dup, mshr_done;
                mshr_dup  = 1'b0;
                mshr_done = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++)
                    if (mshr[i].valid && mshr[i].block_addr == s1_req_blk)
                        mshr_dup = 1'b1;
                if (!mshr_dup) begin
                    for (int i = 0; i < MSHR_COUNT; i++) begin
                        if (!mshr[i].valid && !mshr_done) begin
                            mshr[i].valid      <= 1'b1;
                            mshr[i].block_addr <= s1_req_blk;
                            mshr[i].mem_sent   <= 1'b0;
                            mshr_done = 1'b1;
                            `ifndef SYNTHESIS
                            mpki_misses <= mpki_misses + 1;
                            `endif
                        end
                    end
                end
            end
        end

        // ════════════════════════════════════════════════════════════════
        //  C: Process latched read request (no refill this cycle)
        // ════════════════════════════════════════════════════════════════
        else if (s1_req_valid) begin
            if (s1_req_hit) begin
                l2_resp_valid <= 1'b1;
                l2_resp_data  <= data_array[s1_req_hit_w][s1_req_idx];
                // FIFO: no update on hit (pure FIFO, not LRU)
                `ifndef SYNTHESIS
                if (L2_VERBOSE) $display("L2_lru: READ HIT  addr=%08h way=%0d set=%0d",
                    s1_req_addr, s1_req_hit_w, s1_req_idx);
                `endif
            end else begin
                logic mshr_dup, mshr_done;
                mshr_dup  = 1'b0;
                mshr_done = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++)
                    if (mshr[i].valid && mshr[i].block_addr == s1_req_blk)
                        mshr_dup = 1'b1;
                if (!mshr_dup) begin
                    for (int i = 0; i < MSHR_COUNT; i++) begin
                        if (!mshr[i].valid && !mshr_done) begin
                            mshr[i].valid      <= 1'b1;
                            mshr[i].block_addr <= s1_req_blk;
                            mshr[i].mem_sent   <= 1'b0;
                            mshr_done = 1'b1;
                            `ifndef SYNTHESIS
                            mpki_misses <= mpki_misses + 1;
                            `endif
                        end
                    end
                end
                `ifndef SYNTHESIS
                if (L2_VERBOSE) $display("L2_lru: READ MISS addr=%08h dup=%0b alloc=%0b",
                    s1_req_addr, mshr_dup, mshr_done);
                `endif
            end
        end

        // ════════════════════════════════════════════════════════════════
        //  D: Memory latency countdown (sim mode only)
        // ════════════════════════════════════════════════════════════════
        if (!USE_AVALON) begin
            if (mem_busy && mem_counter > 0)
                mem_counter <= mem_counter - 1;
        end

        // ════════════════════════════════════════════════════════════════
        //  E: Process latched writeback
        // ════════════════════════════════════════════════════════════════
        if (s1_wb_valid) begin
            if (refill_active && refill_set == s1_wb_idx) begin
                defer_wb_valid <= 1'b1;
                defer_wb_addr  <= s1_wb_addr;
                defer_wb_data  <= s1_wb_data;
            end else begin
                if (s1_wb_hit) begin
                    data_array[s1_wb_hit_w][s1_wb_idx] <= s1_wb_data;
                    dirty_array[s1_wb_hit_w][s1_wb_idx] <= 1'b1;
                    // FIFO: no update on hit
                end else begin
                    logic [WAY_W-1:0] wb_way;
                    wb_way = find_install_way(s1_wb_idx);
                    if (valid_array[wb_way][s1_wb_idx] &&
                        dirty_array[wb_way][s1_wb_idx]) begin
                        logic [23:0] evblk;
                        evblk = {tag_array[wb_way][s1_wb_idx], s1_wb_idx};
                        if (USE_AVALON) begin
                            if (!evict_valid[0]) begin
                                evict_valid[0] <= 1'b1;
                                evict_addr[0]  <= evblk;
                                evict_data[0]  <= data_array[wb_way][s1_wb_idx];
                            end else begin
                                evict_valid[1] <= 1'b1;
                                evict_addr[1]  <= evblk;
                                evict_data[1]  <= data_array[wb_way][s1_wb_idx];
                            end
                        end else begin
                            backing_mem[evblk[MEM_IDX_W-1:0]] <= data_array[wb_way][s1_wb_idx];
                        end
                        fifo_ptr[s1_wb_idx] <= fifo_ptr[s1_wb_idx] + WAY_W'(1);
                    end
                    data_array[wb_way][s1_wb_idx]  <= s1_wb_data;
                    tag_array[wb_way][s1_wb_idx]   <= s1_wb_tag;
                    valid_array[wb_way][s1_wb_idx] <= 1'b1;
                    dirty_array[wb_way][s1_wb_idx] <= 1'b1;
                end
            end
        end

        // Process deferred writeback
        if (defer_wb_valid && !s1_wb_valid) begin
            logic [23:0]        dwb_blk;
            logic [INDEX_W-1:0] dwb_idx;
            logic [TAG_W-1:0]   dwb_tag;
            logic [WAYS-1:0]    dwb_way_hit;
            logic               dwb_hit;
            logic [WAY_W-1:0]   dwb_hit_w;

            dwb_blk = defer_wb_addr[29:6];
            dwb_idx = dwb_blk[INDEX_W-1:0];
            dwb_tag = dwb_blk[23:INDEX_W];

            for (int i = 0; i < WAYS; i++)
                dwb_way_hit[i] = valid_array[i][dwb_idx] &&
                                  (tag_array[i][dwb_idx] == dwb_tag);
            dwb_hit = |dwb_way_hit;
            dwb_hit_w = '0;
            for (int i = WAYS-1; i >= 0; i--)
                if (dwb_way_hit[i]) dwb_hit_w = i[WAY_W-1:0];

            if (dwb_hit) begin
                data_array[dwb_hit_w][dwb_idx] <= defer_wb_data;
                dirty_array[dwb_hit_w][dwb_idx] <= 1'b1;
            end else begin
                logic [WAY_W-1:0] dw;
                dw = find_install_way(dwb_idx);
                if (valid_array[dw][dwb_idx] &&
                    dirty_array[dw][dwb_idx]) begin
                    logic [23:0] evblk;
                    evblk = {tag_array[dw][dwb_idx], dwb_idx};
                    if (USE_AVALON) begin
                        if (!evict_valid[0]) begin
                            evict_valid[0] <= 1'b1;
                            evict_addr[0]  <= evblk;
                            evict_data[0]  <= data_array[dw][dwb_idx];
                        end else begin
                            evict_valid[1] <= 1'b1;
                            evict_addr[1]  <= evblk;
                            evict_data[1]  <= data_array[dw][dwb_idx];
                        end
                    end else begin
                        backing_mem[evblk[MEM_IDX_W-1:0]] <= data_array[dw][dwb_idx];
                    end
                    fifo_ptr[dwb_idx] <= fifo_ptr[dwb_idx] + WAY_W'(1);
                end
                data_array[dw][dwb_idx]  <= defer_wb_data;
                tag_array[dw][dwb_idx]   <= dwb_tag;
                valid_array[dw][dwb_idx] <= 1'b1;
                dirty_array[dw][dwb_idx] <= 1'b1;
            end
            defer_wb_valid <= 1'b0;
        end

        // ════════════════════════════════════════════════════════════════
        //  F: Issue MSHR → memory request
        // ════════════════════════════════════════════════════════════════
        if (USE_AVALON) begin
            if (evict_valid[0] && !ext_mem_busy) begin
                ext_mem_wr_req  <= 1'b1;
                ext_mem_wr_addr <= evict_addr[0];
                ext_mem_wr_data <= evict_data[0];
                evict_valid[0]  <= evict_valid[1];
                evict_addr[0]   <= evict_addr[1];
                evict_data[0]   <= evict_data[1];
                evict_valid[1]  <= 1'b0;
            end else if (!mem_busy && !ext_mem_busy && !evict_pending) begin
                logic issued;
                issued = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++) begin
                    if (mshr[i].valid && !mshr[i].mem_sent && !issued) begin
                        mem_busy        <= 1'b1;
                        mem_pend_addr   <= mshr[i].block_addr;
                        mem_pend_id     <= i[MSHR_ID_W-1:0];
                        mshr[i].mem_sent <= 1'b1;
                        ext_mem_rd_req  <= 1'b1;
                        ext_mem_rd_addr <= mshr[i].block_addr;
                        issued = 1'b1;
                    end
                end
            end
        end else begin
            if (!mem_busy) begin
                logic issued;
                issued = 1'b0;
                for (int i = 0; i < MSHR_COUNT; i++) begin
                    if (mshr[i].valid && !mshr[i].mem_sent && !issued) begin
                        mem_busy      <= 1'b1;
                        mem_counter   <= MEM_LAT_INIT;
                        mem_pend_addr <= mshr[i].block_addr;
                        mem_pend_id   <= i[MSHR_ID_W-1:0];
                        mshr[i].mem_sent <= 1'b1;
                        issued = 1'b1;
                    end
                end
            end
        end

    end // process
end // always_ff

// ━━━ Backing memory initialisation (sim only) ━━━━━━━━━━━━━━━━━━━━━━━━━━━
`ifndef SYNTHESIS
initial begin
    for (int i = 0; i < ACTUAL_MEM_LINES; i++)
        backing_mem[i] = '0;
end
`endif

endmodule
