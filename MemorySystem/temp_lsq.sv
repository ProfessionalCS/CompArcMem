/* verilator lint_off EOFNEWLINE */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off DECLFILENAME */

`timescale 1ns/1ps

// Icarus-friendly temporary LSQ clone.
// Goal: preserve the public interface and most of the original behavior,
// while avoiding unsupported constructs such as `break` and packed-array
// dynamic indexing in module port expressions.

typedef enum logic[2:0] {
    OP_MEM_LOAD = 0,
    OP_MEM_STORE = 1,
    OP_MEM_RESOLVE = 2,
    OP_TLB_FILL = 4
} op_e;

module lsq #(
    parameter int N = 16,
    parameter int Q_SIZE = 8
) (
    input logic clk,
    input logic rst_n,
    input logic [120:0] trace_line,

    input logic tlb_hit,
    input logic [29:0] tlb_paddr,

    input logic cache_ready,
    input logic cache_ret_valid,
    input logic [63:0] cache_ret_data,

    output logic tlb_req,
    output logic [47:0] tlb_vaddr,
    output logic tlb_fill,
    output logic [29:0] fill_tlb_paddr,
    output logic [47:0] fill_tlb_vaddr,

    output logic cache_req,
    output logic cache_we,
    output logic [29:0] cache_paddr,
    output logic [63:0] cache_wdata
);
    localparam int LOAD_QUEUE_SIZE = N >> 1;
    localparam int STORE_QUEUE_SIZE = N >> 1;
    localparam int ENTRY_SIZE = 155;
    localparam int EA_SIZE = 48;
    localparam int PA_SIZE = 30;
    localparam int DATA_SIZE = 64;
    localparam int TRACE_ID_SIZE = 4;

    localparam int VALID_IDX = ENTRY_SIZE - 1;
    localparam int RESOLVED_IDX = VALID_IDX - 1;
    localparam int EA_IDX = RESOLVED_IDX - 1;
    localparam int VVALID_IDX = EA_IDX - EA_SIZE;
    localparam int DATA_IDX = VVALID_IDX - 1;
    localparam int TRACE_ID_IDX = DATA_IDX - DATA_SIZE;
    localparam int SQ_TAIL_IDX = TRACE_ID_IDX - TRACE_ID_SIZE;
    localparam int LQ_TAIL_IDX = SQ_TAIL_IDX - $clog2(STORE_QUEUE_SIZE);
    localparam int PA_IDX = LQ_TAIL_IDX - $clog2(LOAD_QUEUE_SIZE);

    op_e trace_op;
    logic [3:0] trace_id;
    logic [47:0] trace_vaddr;
    logic trace_vaddr_is_valid;
    logic trace_value_is_valid;
    logic [63:0] trace_value;

    assign trace_op = op_e'(trace_line[54:52]);
    assign trace_id = trace_line[51:48];
    assign trace_vaddr = trace_line[47:0];
    assign tlb_vaddr = trace_line[47:0];
    assign trace_vaddr_is_valid = trace_line[55];
    assign trace_value_is_valid = trace_line[120];
    assign trace_value = trace_line[119:56];

    assign tlb_fill = (trace_line[54:52] == 3'(OP_TLB_FILL));
    assign fill_tlb_paddr = trace_line[85:56];
    assign fill_tlb_vaddr = trace_line[47:0];

    logic tlb_pending;
    logic tlb_pending_is_load;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] tlb_pending_idx;

    logic cache_pending;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] cache_pending_idx;

    // Use unpacked arrays so variable indexing is accepted by Icarus.
    logic [ENTRY_SIZE-1:0] load_entries [0:LOAD_QUEUE_SIZE-1];
    logic [ENTRY_SIZE-1:0] store_entries [0:STORE_QUEUE_SIZE-1];
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] load_head, load_tail;
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] store_head, store_tail;

    logic load_is_full, load_is_empty;
    logic store_is_full, store_is_empty;

    logic [120:0] trace_line_prev;

    logic [LOAD_QUEUE_SIZE-1:0] load_matches;
    logic [STORE_QUEUE_SIZE-1:0] store_matches;

    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] load_update_idx;
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] store_update_idx;

    logic [STORE_QUEUE_SIZE-1:0] stores_before_load_mask, stores_after_store_mask;
    logic [LOAD_QUEUE_SIZE-1:0]  loads_after_store_mask;

    logic [STORE_QUEUE_SIZE-1:0] final_stores_before_load;
    logic [LOAD_QUEUE_SIZE-1:0]  final_loads_after_store;
    logic [STORE_QUEUE_SIZE-1:0] final_stores_after_store;

    logic [$clog2(STORE_QUEUE_SIZE)-1:0] fwd_store_to_load_idx;
    logic [$clog2(STORE_QUEUE_SIZE)-1:0] tmp_store_idx;
    logic suppress_wb_stores_after_store;

    logic rerun_invalidate_loads;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] rerun_load_idx;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] tmp_load_idx;

    logic [$clog2(STORE_QUEUE_SIZE)-1:0] load_update_sq_tail;
    logic [$clog2(LOAD_QUEUE_SIZE)-1:0] store_update_lq_tail;

    function automatic int circ_distance(input int head_i, input int idx_i, input int qsize_i);
        begin
            if (idx_i >= head_i)
                circ_distance = idx_i - head_i;
            else
                circ_distance = idx_i + qsize_i - head_i;
        end
    endfunction

    always_comb begin
        load_is_empty = (load_head == load_tail);
        store_is_empty = (store_head == store_tail);
        load_is_full = ($clog2(LOAD_QUEUE_SIZE)'(load_tail + 1) == load_head);
        store_is_full = ($clog2(STORE_QUEUE_SIZE)'(store_tail + 1) == store_head);
    end

    // Find matching effective addresses.
    always_comb begin
        for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
            load_matches[i] = (load_entries[i][EA_IDX-:EA_SIZE] == trace_vaddr) &&
                              load_entries[i][VALID_IDX] &&
                              load_entries[i][RESOLVED_IDX];
        end
        for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
            store_matches[i] = (store_entries[i][EA_IDX-:EA_SIZE] == trace_vaddr) &&
                               store_entries[i][VALID_IDX] &&
                               store_entries[i][RESOLVED_IDX];
        end
    end

    // Find indices for resolving instructions out of order.
    always_comb begin
        load_update_idx = '0;
        store_update_idx = '0;

        for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
            if (load_entries[i][VALID_IDX] && load_entries[i][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id)
                load_update_idx = $clog2(LOAD_QUEUE_SIZE)'(i);
        end
        for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
            if (store_entries[i][VALID_IDX] && store_entries[i][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id)
                store_update_idx = $clog2(STORE_QUEUE_SIZE)'(i);
        end

        load_update_sq_tail = load_entries[load_update_idx][SQ_TAIL_IDX-:$clog2(STORE_QUEUE_SIZE)];
        store_update_lq_tail = store_entries[store_update_idx][LQ_TAIL_IDX-:$clog2(LOAD_QUEUE_SIZE)];
    end

    // Circular before/after masks.
    always_comb begin
        int dist_j;
        int dist_i;

        stores_before_load_mask = '0;
        loads_after_store_mask = '0;
        stores_after_store_mask = '0;

        dist_j = circ_distance(store_head, load_update_sq_tail, STORE_QUEUE_SIZE);
        for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
            dist_i = circ_distance(store_head, i, STORE_QUEUE_SIZE);
            stores_before_load_mask[i] = (dist_i < dist_j) && store_entries[i][VALID_IDX];
        end

        dist_j = circ_distance(load_head, store_update_lq_tail, LOAD_QUEUE_SIZE);
        for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
            dist_i = circ_distance(load_head, i, LOAD_QUEUE_SIZE);
            loads_after_store_mask[i] = (dist_i > dist_j) && load_entries[i][VALID_IDX];
        end

        dist_j = circ_distance(store_head, store_update_idx, STORE_QUEUE_SIZE);
        for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
            dist_i = circ_distance(store_head, i, STORE_QUEUE_SIZE);
            stores_after_store_mask[i] = (dist_i > dist_j) && store_entries[i][VALID_IDX];
        end
    end

    assign final_stores_before_load = store_matches & stores_before_load_mask;
    assign final_loads_after_store = load_matches & loads_after_store_mask;
    assign final_stores_after_store = store_matches & stores_after_store_mask;

    always_comb begin
        logic found_younger_same_ea;

        fwd_store_to_load_idx = '0;
        suppress_wb_stores_after_store = 1'b0;
        found_younger_same_ea = 1'b0;

        for (int i = 0; i < STORE_QUEUE_SIZE; i++) begin
            tmp_store_idx = $clog2(STORE_QUEUE_SIZE)'(store_head + i);
            if (final_stores_before_load[tmp_store_idx])
                fwd_store_to_load_idx = tmp_store_idx;
        end

        for (int i = 1; i < STORE_QUEUE_SIZE; i++) begin
            tmp_store_idx = $clog2(STORE_QUEUE_SIZE)'(store_head + i);
            if (!found_younger_same_ea &&
                store_entries[tmp_store_idx][VALID_IDX] &&
                store_entries[tmp_store_idx][RESOLVED_IDX] &&
                (store_entries[tmp_store_idx][EA_IDX-:EA_SIZE] == store_entries[store_head][EA_IDX-:EA_SIZE])) begin
                suppress_wb_stores_after_store = 1'b1;
                found_younger_same_ea = 1'b1;
            end
        end
    end

    always_comb begin
        logic found_rerun_load;

        rerun_invalidate_loads = 1'b0;
        rerun_load_idx = '0;
        found_rerun_load = 1'b0;

        for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
            tmp_load_idx = $clog2(LOAD_QUEUE_SIZE)'(load_head + i);
            if (!found_rerun_load &&
                load_entries[tmp_load_idx][VALID_IDX] &&
                load_entries[tmp_load_idx][RESOLVED_IDX] &&
                !load_entries[tmp_load_idx][VVALID_IDX] &&
                !(tlb_pending && tlb_pending_is_load && tlb_pending_idx == tmp_load_idx) &&
                !(cache_pending && cache_pending_idx == tmp_load_idx)) begin
                rerun_invalidate_loads = 1'b1;
                rerun_load_idx = tmp_load_idx;
                found_rerun_load = 1'b1;
            end
        end
    end

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

            trace_line_prev <= '0;

            load_head <= '0;
            load_tail <= '0;
            store_head <= '0;
            store_tail <= '0;

            for (int i = 0; i < LOAD_QUEUE_SIZE; i++)
                load_entries[i] <= '0;
            for (int i = 0; i < STORE_QUEUE_SIZE; i++)
                store_entries[i] <= '0;

        end else begin
            cache_req <= 0;
            tlb_req <= 0;

            for (int i = 0; i < LOAD_QUEUE_SIZE; i++) begin
                if (final_loads_after_store[i])
                    load_entries[i][VVALID_IDX] <= 0;
            end

            if (cache_pending && cache_ret_valid) begin
                load_entries[cache_pending_idx][VVALID_IDX] <= 1;
                load_entries[cache_pending_idx][DATA_IDX-:DATA_SIZE] <= cache_ret_data;
                cache_pending <= 0;
            end

            if (tlb_pending && tlb_hit) begin
                tlb_req <= 0;
                tlb_pending <= 0;

                if (tlb_pending_is_load) begin
                    load_entries[tlb_pending_idx][RESOLVED_IDX] <= 1;
                    load_entries[tlb_pending_idx][PA_IDX-:PA_SIZE] <= tlb_paddr;

                    if (cache_ready) begin
                        cache_req <= 1;
                        cache_we <= 0;
                        cache_paddr <= tlb_paddr;
                        cache_wdata <= '0;
                        cache_pending_idx <= tlb_pending_idx;
                        cache_pending <= 1;
                    end
                end else begin
                    store_entries[tlb_pending_idx][RESOLVED_IDX] <= 1;
                    store_entries[tlb_pending_idx][PA_IDX-:PA_SIZE] <= tlb_paddr;
                end
            end

            if (trace_line != trace_line_prev) begin
                trace_line_prev <= trace_line;

                case (trace_op)
                    OP_MEM_LOAD: begin
                        if (!load_is_full) begin
                            load_entries[load_tail][VALID_IDX] <= 1;
                            load_entries[load_tail][RESOLVED_IDX] <= 0;
                            load_entries[load_tail][EA_IDX-:EA_SIZE] <= trace_vaddr;
                            load_entries[load_tail][VVALID_IDX] <= 0;
                            load_entries[load_tail][DATA_IDX-:DATA_SIZE] <= '0;
                            load_entries[load_tail][TRACE_ID_IDX-:TRACE_ID_SIZE] <= trace_id;
                            load_entries[load_tail][SQ_TAIL_IDX-:$clog2(STORE_QUEUE_SIZE)] <= store_tail;
                            load_entries[load_tail][LQ_TAIL_IDX-:$clog2(LOAD_QUEUE_SIZE)] <= '0;
                            load_entries[load_tail][PA_IDX-:PA_SIZE] <= '0;

                            load_tail <= $clog2(LOAD_QUEUE_SIZE)'(load_tail + 1);
                            tlb_req <= 1;
                            tlb_pending <= 1;
                            tlb_pending_is_load <= 1;
                            tlb_pending_idx <= load_tail;
                        end
                    end

                    OP_MEM_STORE: begin
                        if (!store_is_full) begin
                            store_entries[store_tail][VALID_IDX] <= 1;
                            store_entries[store_tail][RESOLVED_IDX] <= 0;
                            store_entries[store_tail][EA_IDX-:EA_SIZE] <= trace_vaddr;
                            store_entries[store_tail][VVALID_IDX] <= trace_value_is_valid;
                            store_entries[store_tail][DATA_IDX-:DATA_SIZE] <= trace_value;
                            store_entries[store_tail][TRACE_ID_IDX-:TRACE_ID_SIZE] <= trace_id;
                            store_entries[store_tail][SQ_TAIL_IDX-:$clog2(STORE_QUEUE_SIZE)] <= '0;
                            store_entries[store_tail][LQ_TAIL_IDX-:$clog2(LOAD_QUEUE_SIZE)] <= load_tail;
                            store_entries[store_tail][PA_IDX-:PA_SIZE] <= '0;

                            store_tail <= $clog2(STORE_QUEUE_SIZE)'(store_tail + 1);
                            tlb_req <= 1;
                            tlb_pending <= 1;
                            tlb_pending_is_load <= 0;
                            tlb_pending_idx <= store_tail;
                        end
                    end

                    OP_MEM_RESOLVE: begin
                        if (load_entries[load_update_idx][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id &&
                            load_entries[load_update_idx][VALID_IDX]) begin
                            load_entries[load_update_idx][RESOLVED_IDX] <= 1;
                            load_entries[load_update_idx][EA_IDX-:EA_SIZE] <= trace_vaddr;

                            if (|final_stores_before_load) begin
                                load_entries[load_update_idx][VVALID_IDX] <= 1;
                                load_entries[load_update_idx][DATA_IDX-:DATA_SIZE] <=
                                    store_entries[fwd_store_to_load_idx][DATA_IDX-:DATA_SIZE];
                            end else begin
                                tlb_req <= 1;
                                tlb_pending <= 1;
                                tlb_pending_is_load <= 1;
                                tlb_pending_idx <= load_update_idx;
                            end

                        end else if (store_entries[store_update_idx][TRACE_ID_IDX-:TRACE_ID_SIZE] == trace_id &&
                                     store_entries[store_update_idx][VALID_IDX]) begin
                            store_entries[store_update_idx][RESOLVED_IDX] <= 1;
                            store_entries[store_update_idx][EA_IDX-:EA_SIZE] <= trace_vaddr;

                            if (|final_stores_after_store) begin
                                // suppressed: younger store to same EA exists
                            end else begin
                                tlb_req <= 1;
                                tlb_pending <= 1;
                                tlb_pending_is_load <= 0;
                                tlb_pending_idx <= store_update_idx;
                            end
                        end
                    end

                    default: begin
                    end
                endcase

            end else if (rerun_invalidate_loads && !tlb_pending && !cache_pending) begin
                tlb_req <= 1;
                tlb_pending <= 1;
                tlb_pending_is_load <= 1;
                tlb_pending_idx <= rerun_load_idx;
            end

            if (load_entries[load_head][VALID_IDX] &&
                load_entries[load_head][RESOLVED_IDX] &&
                load_entries[load_head][VVALID_IDX]) begin
                if (!load_is_empty) begin
                    load_entries[load_head][VALID_IDX] <= 0;
                    load_head <= $clog2(LOAD_QUEUE_SIZE)'(load_head + 1);
                end
            end

            if (store_entries[store_head][VALID_IDX] &&
                store_entries[store_head][RESOLVED_IDX] &&
                store_entries[store_head][VVALID_IDX]) begin
                if (!store_is_empty) begin
                    if (!suppress_wb_stores_after_store) begin
                        cache_req <= 1;
                        cache_we <= 1;
                        cache_paddr <= store_entries[store_head][PA_IDX-:PA_SIZE];
                        cache_wdata <= store_entries[store_head][DATA_IDX-:DATA_SIZE];
                    end

                    store_entries[store_head][VALID_IDX] <= 0;
                    store_head <= $clog2(STORE_QUEUE_SIZE)'(store_head + 1);
                end
            end
        end
    end

endmodule
