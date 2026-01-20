`include "defines.svh"
/*==============================================================
    LSU.sv  (single-issue, 1 outstanding load)
    - Stores: execute to fill SQ entry (addr/data), commit marks SQ entry,
              drain in-order from SQ head via dmem store port.
    - Loads: scheduled OoO conservatively:
              * wait until all older stores have addr+data ready
              * try store-to-load forward (youngest older store wins)
              * else issue to dmem load port (single outstanding)
    - WB: single-ported; 1-entry WB buffer (backpressure-safe like BRU/ALU)
==============================================================*/
module LSU (
    input logic clk,
    input logic rst_n,

    // RS interface
    input  logic        req_valid_st,
    input  logic        req_valid_ld,
    output logic        req_ready_st,
    output logic        req_ready_ld,
    input  rs_uop_t     req_uop [1:0], // [0]=store, [1]=load

    // Operand values (from PRF)
    input  logic [31:0] rs1_val [1:0], // [0]=store, [1]=load
    input  logic [31:0] rs2_val [1:0], // [0]=store, [1]=load

    // SQ allocate/commit interface
    input  sq_entry_t   sq_entry_in,
    input  logic        sq_entry_in_valid,
    output logic        sq_entry_in_ready,
    output sq_entry_t   sq_entry_out,

    // Commit interface (from ROB)
    input  logic        commit_valid,
    input  logic        commit_ready,
    input  logic        commit_is_store,
    input  logic [ROB_W-1:0] commit_rob_idx,
    input  logic [EPOCH_W-1:0]       commit_epoch,

    // Flush control (from ROB / trap)
    input  logic        flush_valid,

    // Recovery interface (from ROB branch mispredict)
    input  logic        recover_valid,
    input  logic [ROB_W-1:0] recover_rob_idx,
    input  logic [EPOCH_W-1:0]       recover_epoch,

    // memory interface
    dmem_if.master  dmem,

    // writeback interface
    output logic        wb_valid,
    input  logic        wb_ready,
    output logic        wb_uses_rd,
    output logic [EPOCH_W-1:0]       wb_epoch,
    output logic [ROB_W-1:0]  wb_rob_idx,
    output logic [PHYS_W-1:0] wb_prd_new,
    output logic [31:0]       wb_pc,
    output logic [31:0] wb_data,

    output logic        wb_valid_st,
    input  logic        wb_ready_st,
    output logic        wb_uses_rd_st,
    output logic [EPOCH_W-1:0]       wb_epoch_st,
    output logic [ROB_W-1:0]  wb_rob_idx_st,
    output logic [31:0]       wb_pc_st
);

    // ============================================================
    // Helpers
    // ============================================================
    localparam int LDTAG_W = 4; // must match dmem_if default/instantiation

    function automatic logic [63:0] store_pack64(
        input logic [31:0] wdata32,
        input logic [2:0]  addr_lo
    );
        logic [63:0] tmp;
        begin
            tmp = 64'b0;
            if (addr_lo[2]) tmp[63:32] = wdata32;
            else            tmp[31:0]  = wdata32;
            return tmp;
        end
    endfunction

    function automatic logic [7:0] store_wstrb(
        input mem_size_e  sz,
        input logic [2:0] addr_lo
    );
        logic [7:0] m;
        begin
            m = 8'b0;
            unique case (sz)
                MSZ_B: m = (8'b1  << addr_lo);
                MSZ_H: m = (8'b11 << {addr_lo[2:1], 1'b0});
                MSZ_W: m = (addr_lo[2] ? 8'b1111_0000 : 8'b0000_1111);
                default: m = 8'b0;
            endcase
            return m;
        end
    endfunction

    // Helper function: Extract 32-bit word from 64-bit data based on address
    function automatic logic [31:0] extract_word64(
        input logic [63:0] data64,
        input logic [2:0]  addr_lo
    );
        logic [31:0] word;
        begin
            // Select upper or lower 32 bits based on addr[2]
            word = addr_lo[2] ? data64[63:32] : data64[31:0];
            return word;
        end
    endfunction

    // Modified load_extract32: first extract word, then extract byte/half
    function automatic logic [31:0] load_extract32(
        input logic [63:0] raw64,      // Changed to 64-bit input
        input logic [2:0]  addr_lo,    // Changed to 3 bits (includes word select)
        input mem_size_e   sz,
        input logic        is_unsigned
    );
        logic [31:0] word32;
        logic [31:0] res;
        logic [7:0]  b;
        logic [15:0] h;
        begin
            // First extract the correct 32-bit word from 64-bit data
            word32 = extract_word64(raw64, addr_lo);
            
            // Then extract byte/halfword from the 32-bit word
            res = 32'b0;
            unique case (sz)
                MSZ_B: begin
                    b = word32 >> (addr_lo[1:0]*8);
                    res = is_unsigned ? {24'b0, b} : {{24{b[7]}}, b};
                end
                MSZ_H: begin
                    h = word32 >> ({addr_lo[1],1'b0}*8);
                    res = is_unsigned ? {16'b0, h} : {{16{h[15]}}, h};
                end
                MSZ_W: res = word32;
                default: res = word32;
            endcase
            return res;
        end
    endfunction


    function automatic logic older_than(
        input logic [ROB_W-1:0] a,
        input logic [ROB_W-1:0] b,
        input logic [EPOCH_W-1:0] a_epoch,
        input logic [EPOCH_W-1:0] b_epoch
    );
        return ((a_epoch < b_epoch) || 
                ((a_epoch == b_epoch) && (a < b)));
    endfunction

    function automatic logic [3:0] byte_mask_32(
        input logic [1:0] off,
        input logic [1:0] size  // 0:1B, 1:2B, 2:4B
    );
        logic [3:0] m;
        begin
            unique case (size)
            2'd0: m = 4'b0001 << off;                 // 1 byte
            2'd1: m = 4'b0011 << {off[1],1'b0};       // 2 bytes (off[0]==0)
            2'd2: m = 4'b1111;                        // 4 bytes (off==0)
            default: m = 4'b0000;
            endcase
            return m;
        end
    endfunction

    function automatic logic [7:0] get_byte (
        input logic [31:0] data,
        input logic [1:0]  byte_off
    );
        begin
            get_byte = data[byte_off*8 +: 8];
        end
    endfunction

    function automatic logic [3:0] fw_hit_mask (
        input mem_size_e mem_size,
        input logic [1:0] addr_lo
    );
        begin
            unique case (mem_size)
                MSZ_B: fw_hit_mask = ~(4'b0001 << addr_lo);
                MSZ_H: fw_hit_mask = ~(4'b0011 << {addr_lo[1],1'b0});
                MSZ_W: fw_hit_mask = 4'b0000;
                default: fw_hit_mask = 4'b0000;
            endcase
        end
    endfunction



    // ============================================================
    // AGU (current RS uop)
    // ============================================================
    logic        is_load_req, is_store_req;
    logic [31:0] agu_addr [1:0];
    logic [31:0] agu_data;
    mem_size_e   agu_size [1:0];
    logic        agu_unsigned;

    assign is_load_req  = (req_uop[1].bundle.uop_class == UOP_LOAD) && req_valid_ld;
    assign is_store_req = (req_uop[0].bundle.uop_class == UOP_STORE) && req_valid_st;

    generate
        for (genvar i = 0; i < 2; i++) begin : AGU_GEN
            assign agu_size[i]     = req_uop[i].bundle.mem_size;
            assign agu_addr[i]     = rs1_val[i] + req_uop[i].bundle.imm;
        end
    endgenerate

    always_comb begin
        unique case (agu_size[0])
            MSZ_B: agu_data = rs2_val[0][7:0] << ({agu_addr[0][1:0], 3'b0}); // replicate byte
            MSZ_H: agu_data = rs2_val[0][15:0] << ({agu_addr[0][1], 4'b0}); // replicate half
            MSZ_W: agu_data = rs2_val[0];
            default: agu_data = rs2_val[0];
        endcase
    end                      // store data
    assign agu_unsigned = (req_uop[1].bundle.op == OP_LBU) || (req_uop[1].bundle.op == OP_LHU);

    // Store "execute" identity (used to fill an existing SQ entry)
    logic [ROB_W-1:0] st_rob_idx;
    logic [EPOCH_W-1:0]            st_epoch;
    logic [31:0]      mem_addr;
    logic [31:0]      mem_data;
    logic             st_valid;

    assign st_rob_idx = req_uop[0].rob_idx;
    assign st_epoch   = req_uop[0].epoch;
    assign mem_addr   = agu_addr[0];
    assign mem_data   = agu_data;
    assign st_valid   = is_store_req && req_ready_st && req_valid_st;

    // ============================================================
    // Store Queue (SQ) storage & pointers  (UNCHANGED LOGIC)
    // ============================================================
    sq_entry_t sq_entries [SQ_SIZE-1:0];
    logic valid [SQ_SIZE-1:0];

    logic [$clog2(SQ_SIZE)-1:0] tail_ptr;
    logic [$clog2(SQ_SIZE)-1:0] last_tail_ptr;
    logic [$clog2(SQ_SIZE)-1:0] head_ptr;
    logic [$clog2(SQ_SIZE):0] count;

    logic sq_entry_in_fire;
    assign sq_entry_in_fire = sq_entry_in_valid && sq_entry_in_ready;

    logic commit_fire;
    assign commit_fire = commit_valid && commit_ready;

    // NOTE: your original SQ logic referenced mem_wr_ready.
    // Drive it from the store port "ready" (and committed+ready entry at head).
    // If your dmem_if uses different signal names, map them here.
    logic mem_wr_ready;
    assign mem_wr_ready = dmem.st_ready;

    logic mem_wr_fire;
    assign mem_wr_fire = mem_wr_ready && valid[head_ptr] && sq_entries[head_ptr].committed
                        && sq_entries[head_ptr].addr_rdy
                        && sq_entries[head_ptr].data_rdy;

    logic st_busy;

    logic st_fire;
    assign st_fire = st_valid; // simple: store-exec writes addr/data when a store uop arrives

    // ============================================================
    // Load exec + WB buffer state (reset/cleared on flush/recover)
    // ============================================================
    logic        ld_busy;
    logic [31:0] ld_addr_q;
    mem_size_e   ld_size_q;
    logic        ld_unsigned_q;
    logic [ROB_W-1:0]  ld_rob_q;
    logic [PHYS_W-1:0] ld_prd_q;
    logic [EPOCH_W-1:0]            ld_epoch_q;

    logic        wb_buf_valid;
    logic [31:0] wb_buf_data;
    logic [ROB_W-1:0]  wb_buf_rob_idx;
    logic [PHYS_W-1:0] wb_buf_prd_new;
    logic [EPOCH_W-1:0]        wb_buf_epoch;
    logic        wb_buf_uses_rd;
    logic        wb_fire;
    logic [31:0] wb_buf_pc;

    // ============================================================
    // SQ always_ff (UNCHANGED LOGIC; only depends on ld_busy/wb_buf_valid clears)
    // ============================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < SQ_SIZE; i++) begin
                valid[i] <= 1'b0;
                sq_entries[i].committed <= 1'b0;
                sq_entries[i].sent <= 1'b0;
                sq_entries[i].addr_rdy <= 1'b0;
                sq_entries[i].data_rdy <= 1'b0;
            end
            head_ptr      <= '0;
            tail_ptr      <= '0;
            last_tail_ptr <= '0;
            count         <= '0;
        end else if (flush_valid) begin
            for (int i = 0; i < SQ_SIZE; i++) begin
                valid[i] <= 1'b0;
                sq_entries[i].committed <= 1'b0;
                sq_entries[i].sent <= 1'b0;
                sq_entries[i].addr_rdy <= 1'b0;
                sq_entries[i].data_rdy <= 1'b0;
            end
            head_ptr      <= '0;
            tail_ptr      <= '0;
            last_tail_ptr <= '0;
            count         <= '0;
        end else if (recover_valid) begin
            for (int i = 0; i < SQ_SIZE; i++) begin
                if (valid[i]
                    && (sq_entries[i].rob_idx == recover_rob_idx)
                    && (sq_entries[i].epoch   == recover_epoch)) begin
                    valid[i] <= 1'b0;
                    count <= count - 1;
                    tail_ptr <= i;
                end
            end
            last_tail_ptr <= tail_ptr;
        end else begin
            last_tail_ptr <= tail_ptr;

            if (sq_entry_in_fire) begin
                sq_entries[tail_ptr] <= sq_entry_in;
                valid[tail_ptr] <= 1'b1;
                tail_ptr <= tail_ptr + 1;
            end

            if (mem_wr_fire) begin
                st_busy <= 1'b1;
                dmem.st_resp_ready <= 1'b1; // ready to accept response
            end

            if (dmem.st_resp_valid && dmem.st_resp_ready) begin
                // Store writeback from dmem
                valid[head_ptr] <= 1'b0;
                sq_entries[head_ptr].sent <= 1'b1;
                head_ptr <= head_ptr + 1;
                st_busy <= 1'b0;
                dmem.st_resp_ready <= 1'b0;
            end



            if (commit_fire && commit_is_store) begin
                for (int i = 0; i < SQ_SIZE; i++) begin
                    if (valid[i]
                        && (sq_entries[i].rob_idx == commit_rob_idx)
                        && (sq_entries[i].epoch   == commit_epoch)) begin
                        sq_entries[i].committed <= 1'b1;
                    end
                end
            end

            unique case ({sq_entry_in_fire, mem_wr_fire})
                2'b10: count <= (count != SQ_SIZE) ? count + 1 : count; // push only
                2'b01: count <= (count != 0) ? count - 1 : count; // pop only
                default: count <= count;
            endcase

            if (st_fire) begin
                for (int i = 0; i < SQ_SIZE; i++) begin
                    if (sq_entries[i].rob_idx == st_rob_idx && sq_entries[i].epoch == st_epoch) begin
                        sq_entries[i].addr <= mem_addr;
                        sq_entries[i].addr_rdy <= 1'b1;
                        sq_entries[i].data <= mem_data;
                        sq_entries[i].data_rdy <= 1'b1;
                    end
                end
            end
        end
    end

    // SQ output logic (simple FIFO behavior)
    assign sq_entry_out      = sq_entries[head_ptr];
    assign sq_entry_in_ready = (count != SQ_SIZE);

    // ============================================================
    // Store drain to memory (in-order from SQ head)
    // - You can refine "committed && addr_rdy && data_rdy" gating as desired.
    // ============================================================
    logic head_can_send;
    assign head_can_send =
        valid[head_ptr] &&
        sq_entries[head_ptr].committed &&
        sq_entries[head_ptr].addr_rdy &&
        sq_entries[head_ptr].data_rdy;

    assign dmem.st_valid = head_can_send;
    assign dmem.st_addr  = sq_entries[head_ptr].addr;
    assign dmem.st_wdata = store_pack64(sq_entries[head_ptr].data, sq_entries[head_ptr].addr[2:0]);
    assign dmem.st_wstrb = store_wstrb(sq_entries[head_ptr].mem_size, sq_entries[head_ptr].addr[2:0]);
    // If your interface has st_tag, set it here; otherwise omit.

    // ============================================================
    // Conservative load scheduling (wait on older stores' info)
    // ============================================================
    logic [SQ_SIZE-1:0] st_info_rdy;
    logic [SQ_SIZE-1:0] older;
    always_comb begin
        for (int i = 0; i < SQ_SIZE; i++) begin
            older[i] = older_than(sq_entries[i].rob_idx, req_uop[1].rob_idx, sq_entries[i].epoch, req_uop[1].epoch);
            st_info_rdy[i] = (sq_entries[i].addr_rdy && sq_entries[i].data_rdy && 
                             (sq_entries[i].committed || older[i])) || (~valid[i]) || (~older[i]);
        end
    end

    logic all_st_info_rdy;
    assign all_st_info_rdy = &st_info_rdy;

    // ============================================================
    // Load request holding register (for non-forwarded loads waiting on dmem)
    // ============================================================
    logic        ld_req_valid;
    logic [31:0] ld_req_addr;
    mem_size_e   ld_req_size;
    logic        ld_req_unsigned;
    logic [ROB_W-1:0]  ld_req_rob;
    logic [PHYS_W-1:0] ld_req_prd;
    logic [EPOCH_W-1:0]        ld_req_epoch;

    // Accept new load request if:
    // - Valid load from RS
    // - All older stores ready
    // - No pending request in holding register
    // - WB buffer available
    logic can_accept_load;
    assign can_accept_load = req_valid_ld && 
                            !ld_req_valid && 
                            all_st_info_rdy && 
                            (!wb_buf_valid || wb_fire) &&
                            !ld_busy && (~recover_valid) && (~flush_valid);

    // sq entries start from the head, assume SQ_SIZE is power of 2
    sq_entry_t sq_entries_ordered [SQ_SIZE-1:0];
    logic valid_ordered [SQ_SIZE-1:0];
    logic [$clog2(SQ_SIZE)-1:0] idx_ordered [SQ_SIZE-1:0];
    always_comb begin
        for (int i = 0; i < SQ_SIZE; i++) begin
            idx_ordered[i] = head_ptr + i;
            sq_entries_ordered[i] = sq_entries[idx_ordered[i]];
            valid_ordered[i] = valid[idx_ordered[i]];
        end 
    end

    // Forwarding check (only valid when accepting new request)
    // need to check all four bytes
    logic [3:0] fw_hit_comb_young;
    logic [31:0] fw_data_comb_young;
    logic [3:0] fw_hit_comb_committed;
    logic [31:0] fw_data_comb_committed;
    logic need_mem_load;
    logic [3:0] overlap_mask [SQ_SIZE-1:0];

    always_comb begin
        fw_hit_comb_young = 4'b0;
        fw_data_comb_young = 32'b0;
        fw_hit_comb_committed = 4'b0;
        fw_data_comb_committed = 32'b0;

        // unique case (agu_size[1])
        //     MSZ_B: begin
        //         fw_hit_comb_young = (4'b1110 << agu_addr[1][1:0]);
        //         fw_hit_comb_committed = (4'b0001 << agu_addr[1][1:0]);
        //     end
        //     MSZ_H: begin
        //         if (agu_addr[1][1] == 1'b0) begin
        //             fw_hit_comb_young = 4'b1100;
        //             fw_hit_comb_committed = 4'b1100;
        //         end else begin
        //             fw_hit_comb_young = 4'b0011;
        //             fw_hit_comb_committed = 4'b0011;
        //         end
        //     end
        //     MSZ_W: begin
        //         fw_hit_comb_young = 4'b0000;
        //         fw_hit_comb_committed = 4'b0000;
        //     end
        //     default: begin
        //         fw_hit_comb_young = 4'b0000;
        //         fw_hit_comb_committed = 4'b0000;
        //     end
        // endcase

        if (can_accept_load) begin
            for (int i = 0; i < SQ_SIZE; i++) begin
                overlap_mask[i] = byte_mask_32(agu_addr[1][1:0], agu_size[1]) &
                                  byte_mask_32(sq_entries_ordered[i].addr[1:0], sq_entries_ordered[i].mem_size);
                if (valid_ordered[i] &&
                    sq_entries_ordered[i].addr_rdy &&
                    sq_entries_ordered[i].data_rdy &&
                    (sq_entries_ordered[i].addr[31:2] == agu_addr[1][31:2]) &&
                    (|overlap_mask[i]) &&
                    older[idx_ordered[i]]) begin
                    // Younger store words match
                    for (int b = 0; b < 4; b++) begin
                        if (overlap_mask[i][b]) begin
                            fw_hit_comb_young[b] = 1'b1;
                            fw_data_comb_young[b*8 +: 8] = sq_entries_ordered[i].data[b*8 +: 8];
                        end
                    end
                end

                if (valid_ordered[i] &&
                    sq_entries_ordered[i].committed &&
                    sq_entries_ordered[i].addr_rdy &&
                    sq_entries_ordered[i].data_rdy &&
                    (|overlap_mask[i]) &&
                    (sq_entries_ordered[i].addr[31:2] == agu_addr[1][31:2])) begin
                    // Oldest committed store match
                    for (int b = 0; b < 4; b++) begin
                        if (overlap_mask[i][b]) begin
                            fw_hit_comb_committed[b] = 1'b1;
                            fw_data_comb_committed[b*8 +: 8] = sq_entries_ordered[i].data[b*8 +: 8];
                        end
                    end
                end
            end
        end
    end

    // Combine forwarding hits
    logic [3:0] fw_hit_comb_arr;
    logic [3:0] fw_hit_comb_arr_ff;
    logic fw_hit_comb;
    logic fw_hit_ff;
    logic [31:0] fw_data_comb;
    logic [31:0] fw_hit_data_ff;
    assign need_mem_load = ~(&(fw_hit_comb_arr | fw_hit_mask(agu_size[1], agu_addr[1][1:0])));
    assign fw_hit_comb_arr = fw_hit_comb_young | fw_hit_comb_committed;
    assign fw_hit_comb = |fw_hit_comb_arr;
    always_comb begin
        fw_data_comb = 32'b0;
        for (int b = 0; b < 4; b++) begin
            if (fw_hit_comb_young[b]) begin
                fw_data_comb[b*8 +: 8] = fw_data_comb_young[b*8 +: 8];
            end else if (fw_hit_comb_committed[b]) begin
                fw_data_comb[b*8 +: 8] = fw_data_comb_committed[b*8 +: 8];
            end
        end
    end

    // registered forwarding hits (for load holding register path)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fw_hit_comb_arr_ff <= 4'b0000;
            fw_hit_data_ff <= 32'b0;
            fw_hit_ff <= 1'b0;
        end else if (flush_valid) begin
            fw_hit_comb_arr_ff <= 4'b0000;
            fw_hit_data_ff <= 32'b0;
            fw_hit_ff <= 1'b0;
        end else begin
            if (need_mem_load && can_accept_load) begin
                fw_hit_comb_arr_ff <= fw_hit_comb_arr;
                fw_hit_data_ff <= fw_data_comb;
                fw_hit_ff <= fw_hit_comb;
            end
        end
    end

    // Load request holding register state machine
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ld_req_valid <= 1'b0;
            wb_buf_pc <= 32'b0;
        end else if (flush_valid) begin
            ld_req_valid <= 1'b0;
        end else begin
            if (can_accept_load) begin
                if (fw_hit_comb && !need_mem_load) begin
                    // Forwarded immediately, don't hold request
                    ld_req_valid <= 1'b0;
                end else begin
                    // Need to go to memory, hold the request
                    ld_req_valid   <= 1'b1;
                    ld_req_addr    <= agu_addr[1];
                    ld_req_size    <= agu_size[1];
                    ld_req_unsigned <= agu_unsigned;
                    ld_req_rob     <= req_uop[1].rob_idx;
                    ld_req_prd     <= req_uop[1].prd_new;
                    ld_req_epoch   <= req_uop[1].epoch;
                end
                wb_buf_pc <= req_uop[1].bundle.pc;
            end else if (ld_req_valid && dmem.ld_ready) begin
                // Request accepted by memory, clear holding register
                ld_req_valid <= 1'b0;
            end
        end
    end

    // ============================================================
    // Memory interface (issue from holding register)
    // ============================================================
    assign dmem.ld_valid = ld_req_valid;
    assign dmem.ld_addr  = ld_req_addr;
    assign dmem.ld_tag   = '0;

    logic ld_fire;
    assign ld_fire = dmem.ld_valid && dmem.ld_ready;

    // ============================================================
    // Track in-flight load (memory response expected)
    // ============================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ld_busy <= 1'b0;
        end else if (flush_valid) begin
            ld_busy <= 1'b0;
        end else begin
            if (ld_fire) begin
                // Load issued to memory - mark busy and capture metadata
                ld_busy       <= 1'b1;
                dmem.ld_resp_ready <= 1'b1;
            end else if (ld_busy && dmem.ld_resp_valid && (!wb_buf_valid || wb_fire)) begin
                // Clear ld_busy when response is accepted into WB buffer
                ld_busy <= 1'b0;
            end
        end
    end

    always_comb begin
        ld_addr_q     = ld_req_addr;
        ld_size_q     = ld_req_size;
        ld_unsigned_q = ld_req_unsigned;
        ld_rob_q      = ld_req_rob;
        ld_prd_q      = ld_req_prd;
        ld_epoch_q    = ld_req_epoch;
    end

    // ============================================================
    // Load data formation + WB buffer (1-entry, backpressure-safe)
    // ============================================================
    logic [31:0] load_data;
    logic [31:0] load_data_bf_merge;
    logic [63:0] fw_data64;
    always_comb begin
        if (can_accept_load && fw_hit_comb && ~need_mem_load) begin
            // Forwarded load data - store data is already 32-bit
            // Pack it into 64-bit format for uniform processing
            // Forwarded load data - store data is already 32-bit
            // Pack it into 64-bit format for uniform processing
            fw_data64 = store_pack64(fw_data_comb, agu_addr[1][2:0]);
            load_data = load_extract32(fw_data64, agu_addr[1][2:0], agu_size[1], agu_unsigned);
        end else if (fw_hit_ff) begin
            // Memory response data - already 64-bit
            load_data_bf_merge = load_extract32(dmem.ld_resp_data, ld_addr_q[2:0], ld_size_q, ld_unsigned_q);
            for (int b = 0; b < 4; b++) begin
                if (fw_hit_comb_arr_ff[b]) begin
                    load_data[b*8 +: 8] = fw_hit_data_ff[b*8 +: 8];
                end else begin
                    load_data[b*8 +: 8] = load_data_bf_merge[b*8 +: 8];
                end
            end
        end else begin
            // Memory response data - already 64-bit
            load_data = load_extract32(dmem.ld_resp_data, ld_addr_q[2:0], ld_size_q, ld_unsigned_q);
        end
    end

    // WB buffer enqueue conditions:
    // 1. Forwarded load: can_accept_load && fw_hit_comb && !wb_buf_valid
    // 2. Memory response: ld_busy && dmem.ld_resp_valid && !wb_buf_valid
    logic wb_buf_enq;
    assign wb_buf_enq = (can_accept_load && fw_hit_comb && ~need_mem_load) || 
                        (ld_busy && dmem.ld_resp_valid);

    // WB buffer dequeue: downstream accepts
    assign wb_fire = wb_buf_valid && wb_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_buf_valid <= 1'b0;
            wb_buf_data <= '0;
            wb_buf_rob_idx <= '0;
            wb_buf_prd_new <= '0;
            wb_buf_epoch <= '0;
            wb_buf_uses_rd <= 1'b0;
        end else if (flush_valid) begin
            wb_buf_valid <= 1'b0;
        end else begin
            if (wb_buf_enq) begin
                wb_buf_valid   <= 1'b1;
                wb_buf_data    <= load_data;
                if (can_accept_load && fw_hit_comb && ~need_mem_load) begin
                    // Forwarded path metadata
                    wb_buf_rob_idx <= req_uop[1].rob_idx;
                    wb_buf_prd_new <= req_uop[1].prd_new;
                    wb_buf_epoch   <= req_uop[1].epoch;
                end else begin
                    // Memory response path metadata
                    wb_buf_rob_idx <= ld_rob_q;
                    wb_buf_prd_new <= ld_prd_q;
                    wb_buf_epoch   <= ld_epoch_q;
                end
                wb_buf_uses_rd <= 1'b1;

            end else if (wb_fire) begin
                wb_buf_valid <= 1'b0;
            end
        end
    end

    // ============================================================
    // External handshakes
    // ============================================================
    assign req_ready_ld = can_accept_load;
    assign req_ready_st = wb_ready_st;

    assign wb_valid   = wb_buf_valid;
    assign wb_data    = wb_buf_data;
    assign wb_rob_idx = wb_buf_rob_idx;
    assign wb_prd_new = wb_buf_prd_new;
    assign wb_epoch   = wb_buf_epoch;
    assign wb_uses_rd = wb_buf_uses_rd;
    assign wb_pc      = wb_buf_pc;

    assign wb_valid_st   = req_valid_st;
    assign wb_uses_rd_st = 1'b0;
    assign wb_epoch_st   = req_uop[0].epoch;
    assign wb_rob_idx_st = req_uop[0].rob_idx;
    assign wb_pc_st      = req_uop[0].bundle.pc;
endmodule
