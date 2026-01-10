// ============================================================================
// Extensible Data Memory Model
// ============================================================================
// Features:
// - Configurable latency (fixed or variable)
// - FIFO-based request/response queues for pipelining
// - Load/Store port arbitration
// - FPGA-friendly (inferred block RAM)
// - Extensible to cache hierarchies
// - Configurable memory size and initialization
// ============================================================================

`include "defines.svh"

module dmem_model #(
    parameter int MEM_SIZE_KB = 64,              // Memory size in KB
    parameter int LD_LATENCY_MIN = 1,            // Minimum load latency (cycles)
    parameter int LD_LATENCY_MAX = 1,            // Maximum load latency (random if > MIN)
    parameter int ST_LATENCY = 0,                // Store commit latency (0 = immediate)
    parameter int LD_REQ_FIFO_DEPTH = 4,         // Load request FIFO depth
    parameter int LD_RESP_FIFO_DEPTH = 4,        // Load response FIFO depth
    parameter int ST_REQ_FIFO_DEPTH = 4,         // Store request FIFO depth
    parameter int LDTAG_W = 4,                   // Load tag width
    parameter bit ENABLE_STALL = 1,              // Enable random memory stalls
    parameter real STALL_PROBABILITY = 0.0,      // Probability of stall [0.0-1.0]
    parameter string HEXFILE = "",               // Memory initialization file
    parameter bit VERBOSE = 0                    // Enable debug messages
)(
    input  logic clk,
    input  logic rst_n,
    
    dmem_if.slave dmem
);

    // ========================================================================
    // Memory Array
    // ========================================================================
    localparam int MEM_WORDS = (MEM_SIZE_KB * 1024) / 4;  // 32-bit words
    localparam int ADDR_W = $clog2(MEM_WORDS);
    
    logic [31:0] mem [0:MEM_WORDS-1];
    
    initial begin
        if (HEXFILE != "") begin
            $readmemh(HEXFILE, mem);
            if (VERBOSE) $display("[DMEM] Loaded memory from %s", HEXFILE);
        end else begin
            for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h0;
        end
    end

    // ========================================================================
    // Load Request FIFO
    // ========================================================================
    typedef struct packed {
        logic [31:0]       addr;
        logic [2:0]        size;
        logic [LDTAG_W-1:0] tag;
        int                latency;  // Assigned latency for this request
    } ld_req_t;
    
    ld_req_t ld_req_fifo [0:LD_REQ_FIFO_DEPTH-1];
    logic [$clog2(LD_REQ_FIFO_DEPTH+1)-1:0] ld_req_count;
    logic [$clog2(LD_REQ_FIFO_DEPTH)-1:0] ld_req_head, ld_req_tail;
    
    wire ld_req_full  = (ld_req_count == LD_REQ_FIFO_DEPTH);
    wire ld_req_empty = (ld_req_count == 0);
    
    // ========================================================================
    // Load Response FIFO
    // ========================================================================
    typedef struct packed {
        logic [LDTAG_W-1:0] tag;
        logic [63:0]        data;
        logic               err;
    } ld_resp_t;
    
    ld_resp_t ld_resp_fifo [0:LD_RESP_FIFO_DEPTH-1];
    logic [$clog2(LD_RESP_FIFO_DEPTH+1)-1:0] ld_resp_count;
    logic [$clog2(LD_RESP_FIFO_DEPTH)-1:0] ld_resp_head, ld_resp_tail;
    
    wire ld_resp_full  = (ld_resp_count == LD_RESP_FIFO_DEPTH);
    wire ld_resp_empty = (ld_resp_count == 0);
    
    // ========================================================================
    // Store Request FIFO
    // ========================================================================
    typedef struct packed {
        logic [31:0] addr;
        logic [2:0]  size;
        logic [63:0] wdata;
        logic [7:0]  wstrb;
        int          latency;  // Cycles until store commits
    } st_req_t;
    
    st_req_t st_req_fifo [0:ST_REQ_FIFO_DEPTH-1];
    logic [$clog2(ST_REQ_FIFO_DEPTH+1)-1:0] st_req_count;
    logic [$clog2(ST_REQ_FIFO_DEPTH)-1:0] st_req_head, st_req_tail;
    
    wire st_req_full  = (st_req_count == ST_REQ_FIFO_DEPTH);
    wire st_req_empty = (st_req_count == 0);

    // ========================================================================
    // Load Pipeline State
    // ========================================================================
    // Track in-flight loads with their countdown timers
    typedef struct packed {
        logic valid;
        int   cycles_remaining;
        ld_req_t req;
    } ld_pipeline_entry_t;
    
    localparam int LD_PIPE_DEPTH = LD_LATENCY_MAX + 2;
    ld_pipeline_entry_t ld_pipeline [0:LD_PIPE_DEPTH-1];

    // ========================================================================
    // Random Latency Generator
    // ========================================================================
    function automatic int get_random_latency(int min_lat, int max_lat);
        if (min_lat == max_lat) return min_lat;
        return min_lat + ($urandom % (max_lat - min_lat + 1));
    endfunction
    
    // ========================================================================
    // Memory Stall Generator
    // ========================================================================
    logic mem_stalled;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_stalled <= 1'b0;
        end else if (ENABLE_STALL) begin
            // Random stall based on probability
            automatic real rand_val = $urandom / (2.0**32);
            mem_stalled <= (rand_val < STALL_PROBABILITY);
        end else begin
            mem_stalled <= 1'b0;
        end
    end

    // ========================================================================
    // Load Request Interface
    // ========================================================================
    assign dmem.ld_ready = !ld_req_full && !mem_stalled;
    
    wire ld_req_fire = dmem.ld_valid && dmem.ld_ready;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_req_count <= '0;
            ld_req_head <= '0;
            ld_req_tail <= '0;
        end else begin
            // Enqueue load request
            if (ld_req_fire) begin
                ld_req_fifo[ld_req_tail].addr <= dmem.ld_addr;
                ld_req_fifo[ld_req_tail].size <= dmem.ld_size;
                ld_req_fifo[ld_req_tail].tag  <= dmem.ld_tag;
                ld_req_fifo[ld_req_tail].latency <= 
                    get_random_latency(LD_LATENCY_MIN, LD_LATENCY_MAX);
                
                ld_req_tail <= (ld_req_tail + 1) % LD_REQ_FIFO_DEPTH;
                ld_req_count <= ld_req_count + 1;
                
                if (VERBOSE) begin
                    $display("[DMEM] T=%0t Load req: addr=0x%08h tag=%0d", 
                             $time, dmem.ld_addr, dmem.ld_tag);
                end
            end
        end
    end

    // ========================================================================
    // Load Pipeline Processing
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < LD_PIPE_DEPTH; i++) begin
                ld_pipeline[i].valid <= 1'b0;
                ld_pipeline[i].cycles_remaining <= 0;
            end
        end else begin
            // Issue new load from request FIFO if space in pipeline
            logic can_issue = 1'b0;
            int issue_slot = -1;
            
            for (int i = 0; i < LD_PIPE_DEPTH; i++) begin
                if (!ld_pipeline[i].valid && !can_issue) begin
                    can_issue = 1'b1;
                    issue_slot = i;
                end
            end
            
            if (can_issue && !ld_req_empty && !ld_resp_full) begin
                ld_pipeline[issue_slot].valid <= 1'b1;
                ld_pipeline[issue_slot].req <= ld_req_fifo[ld_req_head];
                ld_pipeline[issue_slot].cycles_remaining <= 
                    ld_req_fifo[ld_req_head].latency;
                
                ld_req_head <= (ld_req_head + 1) % LD_REQ_FIFO_DEPTH;
                ld_req_count <= ld_req_count - 1;
            end
            
            // Decrement counters and complete loads
            for (int i = 0; i < LD_PIPE_DEPTH; i++) begin
                if (ld_pipeline[i].valid) begin
                    if (ld_pipeline[i].cycles_remaining > 0) begin
                        ld_pipeline[i].cycles_remaining <= 
                            ld_pipeline[i].cycles_remaining - 1;
                    end else if (!ld_resp_full) begin
                        // Load completes - read memory and enqueue response
                        automatic logic [31:0] addr = ld_pipeline[i].req.addr;
                        automatic logic [31:0] word_addr = addr[31:2];
                        automatic logic [31:0] word_data;
                        
                        // Bounds checking
                        if (word_addr < MEM_WORDS) begin
                            word_data = mem[word_addr];
                        end else begin
                            word_data = 32'hDEADBEEF;
                            if (VERBOSE) begin
                                $display("[DMEM] ERROR: Load OOB addr=0x%08h", addr);
                            end
                        end
                        
                        // Enqueue response (duplicate word in both halves)
                        ld_resp_fifo[ld_resp_tail].tag <= ld_pipeline[i].req.tag;
                        ld_resp_fifo[ld_resp_tail].data <= {word_data, word_data};
                        ld_resp_fifo[ld_resp_tail].err <= 1'b0;
                        
                        ld_resp_tail <= (ld_resp_tail + 1) % LD_RESP_FIFO_DEPTH;
                        ld_resp_count <= ld_resp_count + 1;
                        
                        ld_pipeline[i].valid <= 1'b0;
                        
                        if (VERBOSE) begin
                            $display("[DMEM] T=%0t Load resp: addr=0x%08h data=0x%08h tag=%0d", 
                                     $time, addr, word_data, ld_pipeline[i].req.tag);
                        end
                    end
                end
            end
        end
    end

    // ========================================================================
    // Load Response Interface
    // ========================================================================
    assign dmem.ld_resp_valid = !ld_resp_empty;
    assign dmem.ld_resp_tag   = ld_resp_fifo[ld_resp_head].tag;
    assign dmem.ld_resp_data  = ld_resp_fifo[ld_resp_head].data;
    assign dmem.ld_resp_err   = ld_resp_fifo[ld_resp_head].err;
    
    wire ld_resp_fire = dmem.ld_resp_valid && dmem.ld_resp_ready;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_resp_head <= '0;
        end else begin
            if (ld_resp_fire) begin
                ld_resp_head <= (ld_resp_head + 1) % LD_RESP_FIFO_DEPTH;
                ld_resp_count <= ld_resp_count - 1;
            end
        end
    end

    // ========================================================================
    // Store Request Interface
    // ========================================================================
    assign dmem.st_ready = !st_req_full && !mem_stalled;
    
    wire st_req_fire = dmem.st_valid && dmem.st_ready;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_req_count <= '0;
            st_req_head <= '0;
            st_req_tail <= '0;
        end else begin
            // Enqueue store request
            if (st_req_fire) begin
                st_req_fifo[st_req_tail].addr    <= dmem.st_addr;
                st_req_fifo[st_req_tail].size    <= dmem.st_size;
                st_req_fifo[st_req_tail].wdata   <= dmem.st_wdata;
                st_req_fifo[st_req_tail].wstrb   <= dmem.st_wstrb;
                st_req_fifo[st_req_tail].latency <= ST_LATENCY;
                
                st_req_tail <= (st_req_tail + 1) % ST_REQ_FIFO_DEPTH;
                st_req_count <= st_req_count + 1;
                
                if (VERBOSE) begin
                    $display("[DMEM] T=%0t Store req: addr=0x%08h data=0x%016h", 
                             $time, dmem.st_addr, dmem.st_wdata);
                end
            end
        end
    end

    // ========================================================================
    // Store Processing
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // No state needed for store completion tracking
        end else begin
            // Process oldest store if latency expired
            if (!st_req_empty) begin
                if (st_req_fifo[st_req_head].latency <= 0) begin
                    // Commit store to memory
                    automatic logic [31:0] addr = st_req_fifo[st_req_head].addr;
                    automatic logic [31:0] word_addr = addr[31:2];
                    automatic logic [31:0] store_data;
                    automatic logic [7:0]  wstrb = st_req_fifo[st_req_head].wstrb;
                    
                    // Extract correct 32-bit word based on address[2]
                    if (addr[2]) begin
                        store_data = st_req_fifo[st_req_head].wdata[63:32];
                    end else begin
                        store_data = st_req_fifo[st_req_head].wdata[31:0];
                    end
                    
                    // Bounds checking and write
                    if (word_addr < MEM_WORDS) begin
                        // Apply byte strobe
                        logic [31:0] old_data = mem[word_addr];
                        logic [31:0] new_data = old_data;
                        
                        for (int b = 0; b < 4; b++) begin
                            if (wstrb[b]) begin
                                new_data[b*8 +: 8] = store_data[b*8 +: 8];
                            end
                        end
                        
                        mem[word_addr] <= new_data;
                        
                        if (VERBOSE) begin
                            $display("[DMEM] T=%0t Store commit: addr=0x%08h data=0x%08h", 
                                     $time, addr, new_data);
                        end
                    end else begin
                        if (VERBOSE) begin
                            $display("[DMEM] ERROR: Store OOB addr=0x%08h", addr);
                        end
                    end
                    
                    // Remove from FIFO
                    st_req_head <= (st_req_head + 1) % ST_REQ_FIFO_DEPTH;
                    st_req_count <= st_req_count - 1;
                    
                end else begin
                    // Decrement latency
                    st_req_fifo[st_req_head].latency <= 
                        st_req_fifo[st_req_head].latency - 1;
                end
            end
        end
    end

    // ========================================================================
    // Debug/Statistics
    // ========================================================================
    `ifdef SIMULATION
    int total_loads = 0;
    int total_stores = 0;
    int total_stalls = 0;
    
    always_ff @(posedge clk) begin
        if (ld_req_fire) total_loads++;
        if (st_req_fire) total_stores++;
        if (mem_stalled && (dmem.ld_valid || dmem.st_valid)) total_stalls++;
    end
    
    final begin
        if (VERBOSE) begin
            $display("========================================");
            $display("DMEM Statistics");
            $display("========================================");
            $display("Total Loads:  %0d", total_loads);
            $display("Total Stores: %0d", total_stores);
            $display("Total Stalls: %0d", total_stalls);
            $display("========================================");
        end
    end
    `endif

endmodule


// ============================================================================
// Cache-Ready Data Memory Model (Future Extension)
// ============================================================================
// This wrapper demonstrates how to extend to a cache hierarchy
// ============================================================================

module dmem_with_cache #(
    parameter int CACHE_SIZE_KB = 8,
    parameter int CACHE_LINE_SIZE = 64,  // bytes
    parameter int CACHE_WAYS = 2,
    parameter int MEM_SIZE_KB = 256,
    parameter int MEM_LATENCY = 10,
    parameter int LDTAG_W = 4,
    parameter bit VERBOSE = 0
)(
    input  logic clk,
    input  logic rst_n,
    
    dmem_if.slave dmem_cpu,    // CPU-facing interface
    dmem_if.master dmem_mem    // Memory-facing interface (for future L2/DRAM)
);

    // ========================================================================
    // L1 Cache Instance (Placeholder - to be implemented)
    // ========================================================================
    // For now, just pass-through to memory model
    // Future: Add cache_controller module here
    
    logic [LDTAG_W-1:0] ld_tag_map [16];  // Map internal tags to CPU tags
    
    // Simple pass-through for demonstration
    assign dmem_cpu.ld_ready = dmem_mem.ld_ready;
    assign dmem_mem.ld_valid = dmem_cpu.ld_valid;
    assign dmem_mem.ld_addr  = dmem_cpu.ld_addr;
    assign dmem_mem.ld_size  = dmem_cpu.ld_size;
    assign dmem_mem.ld_tag   = dmem_cpu.ld_tag;
    
    assign dmem_cpu.ld_resp_valid = dmem_mem.ld_resp_valid;
    assign dmem_cpu.ld_resp_tag   = dmem_mem.ld_resp_tag;
    assign dmem_cpu.ld_resp_data  = dmem_mem.ld_resp_data;
    assign dmem_cpu.ld_resp_err   = dmem_mem.ld_resp_err;
    assign dmem_mem.ld_resp_ready = dmem_cpu.ld_resp_ready;
    
    assign dmem_cpu.st_ready = dmem_mem.st_ready;
    assign dmem_mem.st_valid = dmem_cpu.st_valid;
    assign dmem_mem.st_addr  = dmem_cpu.st_addr;
    assign dmem_mem.st_size  = dmem_cpu.st_size;
    assign dmem_mem.st_wdata = dmem_cpu.st_wdata;
    assign dmem_mem.st_wstrb = dmem_cpu.st_wstrb;
    
    // Future cache implementation would:
    // 1. Check cache tags for hits
    // 2. Handle misses by requesting from dmem_mem
    // 3. Maintain coherence state
    // 4. Support write-back or write-through policy

endmodule