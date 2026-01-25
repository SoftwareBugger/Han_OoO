`include "defines.svh"
`include "periph_defines.svh"

module mmio (
    input  logic clk,
    input  logic rst_n,

    // CPU side (CPU is master, interconnect is slave)
    dmem_if.slave  cpu_dmem,

    // Real memory side (interconnect is master)
    dmem_if.master mem_dmem,

    // Peripheral MMIO side (interconnect is master)
    mmio_if.master spi_mmio,
    mmio_if.master uart_mmio
);

    // ============================================================
    // Address map decode helpers
    // ============================================================

    function automatic logic is_spi_addr(input logic [31:0] a);
        return (a[31:12] == SPI_BASE[31:12]);
    endfunction

    function automatic logic is_uart_addr(input logic [31:0] a);
        return (a[31:12] == UART_BASE[31:12]);
    endfunction

    function automatic logic [63:0] mmio_pack_rdata32(
        input logic [31:0] rdata32,
        input logic        addr_word_sel  // addr[2]
    );
        logic [63:0] rdata64;
        begin
            rdata64 = 64'h0;

            if (addr_word_sel) begin
            // odd word → upper 32 bits
            rdata64[63:32] = rdata32;
            end else begin
            // even word → lower 32 bits
            rdata64[31:0]  = rdata32;
            end

            return rdata64;
        end
    endfunction

    function automatic logic [31:0] mmio_unpack_wdata32(
    input logic [63:0] wdata64,
    input logic        addr_word_sel   // addr[2]
    );
    begin
        return addr_word_sel ? wdata64[63:32] : wdata64[31:0];
    end
    endfunction


    function automatic logic [3:0] mmio_unpack_wstrb32(
    input logic [7:0]  wstrb64,
    input logic        addr_word_sel   // addr[2]
    );
    begin
        return addr_word_sel ? wstrb64[7:4] : wstrb64[3:0];
    end
    endfunction



    // decode each channel independently (because ld_addr vs st_addr)
    logic st_hit_spi, st_hit_uart, st_hit_mem;
    logic ld_hit_spi, ld_hit_uart, ld_hit_mem;

    assign st_hit_spi  = is_spi_addr(cpu_dmem.st_addr);
    assign st_hit_uart = is_uart_addr(cpu_dmem.st_addr);
    assign st_hit_mem  = !(st_hit_spi || st_hit_uart);

    assign ld_hit_spi  = is_spi_addr(cpu_dmem.ld_addr);
    assign ld_hit_uart = is_uart_addr(cpu_dmem.ld_addr);
    assign ld_hit_mem  = !(ld_hit_spi || ld_hit_uart);

    // ============================================================
    // Track in-flight LOAD target for correct response routing
    // (Assumes at most 1 outstanding load)
    // ============================================================
    typedef enum logic [1:0] { T_MEM=2'd0, T_SPI=2'd1, T_UART=2'd2 } tgt_e;

    logic               ld_inflight;
    logic               st_inflight;

    // demuxing from master side
    // dmem side
    assign mem_dmem.ld_tag = cpu_dmem.ld_tag;
    assign mem_dmem.ld_valid = cpu_dmem.ld_valid & ld_hit_mem;
    assign mem_dmem.ld_addr = cpu_dmem.ld_addr;
    assign mem_dmem.ld_size = cpu_dmem.ld_size;
    assign mem_dmem.ld_resp_ready = cpu_dmem.ld_resp_ready;
    assign mem_dmem.st_valid = cpu_dmem.st_valid & st_hit_mem;
    assign mem_dmem.st_addr  = cpu_dmem.st_addr;
    assign mem_dmem.st_size  = cpu_dmem.st_size;
    assign mem_dmem.st_wdata = cpu_dmem.st_wdata;
    assign mem_dmem.st_wstrb = cpu_dmem.st_wstrb;
    assign mem_dmem.st_resp_ready = cpu_dmem.st_resp_ready;

    // SPI MMIO side
    assign spi_mmio.mmio_valid = (cpu_dmem.ld_valid & cpu_dmem.ld_ready & ld_hit_spi) | (cpu_dmem.st_valid & cpu_dmem.st_ready & st_hit_spi);
    assign spi_mmio.mmio_we    = cpu_dmem.st_valid & cpu_dmem.st_ready & st_hit_spi;
    assign spi_mmio.mmio_addr  = cpu_dmem.st_valid ? cpu_dmem.st_addr[ADDR_W-1:0] : cpu_dmem.ld_addr[ADDR_W-1:0];
    assign spi_mmio.mmio_wdata = mmio_unpack_wdata32(cpu_dmem.st_wdata, cpu_dmem.st_addr[2]);
    assign spi_mmio.mmio_wstrb = mmio_unpack_wstrb32(cpu_dmem.st_wstrb, cpu_dmem.st_addr[2]);

    // UART MMIO side
    assign uart_mmio.mmio_valid = (cpu_dmem.ld_valid & cpu_dmem.ld_ready & ld_hit_uart) | (cpu_dmem.st_valid & cpu_dmem.st_ready & st_hit_uart);
    assign uart_mmio.mmio_we    = cpu_dmem.st_valid & cpu_dmem.st_ready & st_hit_uart;
    assign uart_mmio.mmio_addr  = cpu_dmem.st_valid ? cpu_dmem.st_addr[ADDR_W-1:0] : cpu_dmem.ld_addr[ADDR_W-1:0];
    assign uart_mmio.mmio_wdata = mmio_unpack_wdata32(cpu_dmem.st_wdata, cpu_dmem.st_addr[2]);
    assign uart_mmio.mmio_wstrb = mmio_unpack_wstrb32(cpu_dmem.st_wstrb, cpu_dmem.st_addr[2]);

    // intentionally using synchronous reset for FPGA friendliness
    logic ld_is_spi;
    logic ld_is_uart;
    logic ld_is_mem;
    logic st_is_spi;
    logic st_is_uart;
    logic st_is_mem;
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            ld_inflight <= 1'b0;
            st_inflight <= 1'b0;
            ld_is_mem  <= 1'b0;
            ld_is_spi  <= 1'b0;
            ld_is_uart <= 1'b0;
            st_is_mem  <= 1'b0;
            st_is_spi  <= 1'b0;
            st_is_uart <= 1'b0;
        end else begin
            if (cpu_dmem.ld_valid & cpu_dmem.ld_ready) begin
                ld_inflight <= 1'b1;
                ld_is_mem  <= ld_hit_mem;
                ld_is_spi  <= ld_hit_spi;
                ld_is_uart <= ld_hit_uart;
            end else if (cpu_dmem.ld_resp_ready & cpu_dmem.ld_resp_valid) begin
                ld_inflight <= 1'b0;
            end
            if (cpu_dmem.st_valid & cpu_dmem.st_ready) begin
                st_inflight <= 1'b1;
                st_is_mem  <= st_hit_mem;
                st_is_spi  <= st_hit_spi;
                st_is_uart <= st_hit_uart;
            end else if (cpu_dmem.st_resp_ready & cpu_dmem.st_resp_valid) begin
                st_inflight <= 1'b0;
            end
        end
    end

    // response fire can invalidate in-flight status
    logic ld_resp_fire;
    assign ld_resp_fire = cpu_dmem.ld_resp_ready & cpu_dmem.ld_resp_valid;
    logic st_resp_fire;
    assign st_resp_fire = cpu_dmem.st_resp_ready & cpu_dmem.st_resp_valid;

    // output muxing
    always_comb begin
        cpu_dmem.ld_ready = 1'b0;
        cpu_dmem.ld_resp_valid = 1'b0;
        cpu_dmem.ld_resp_data = 32'h0;
        cpu_dmem.ld_resp_tag = cpu_dmem.ld_tag;
        cpu_dmem.ld_resp_err = 1'b0;
        cpu_dmem.st_ready = 1'b0;
        cpu_dmem.st_resp_valid = 1'b0;

        if (ld_hit_mem) begin
            cpu_dmem.ld_ready = mem_dmem.ld_ready;
        end else if (ld_hit_spi) begin
            cpu_dmem.ld_ready = spi_mmio.mmio_ready;
        end else if (ld_hit_uart) begin
            cpu_dmem.ld_ready = uart_mmio.mmio_ready;
        end

        if (st_hit_mem) begin
            cpu_dmem.st_ready = mem_dmem.st_ready;
        end else if (st_hit_spi) begin
            cpu_dmem.st_ready = spi_mmio.mmio_ready & (~cpu_dmem.ld_valid);
        end else if (st_hit_uart) begin
            cpu_dmem.st_ready = uart_mmio.mmio_ready & (~cpu_dmem.ld_valid);
        end

        if (ld_inflight || (cpu_dmem.ld_valid && cpu_dmem.ld_ready)) begin
            if (ld_is_mem || ld_hit_mem) begin
                cpu_dmem.ld_resp_valid = mem_dmem.ld_resp_valid;
                cpu_dmem.ld_resp_data = mem_dmem.ld_resp_data;
                cpu_dmem.ld_resp_err   = mem_dmem.ld_resp_err;
            end else if (ld_is_spi) begin
                cpu_dmem.ld_resp_valid = 1'b1; // valid at next cycle of request
                cpu_dmem.ld_resp_data = mmio_pack_rdata32(spi_mmio.mmio_rdata, cpu_dmem.ld_addr[2]);
                cpu_dmem.ld_resp_err   = 1'b0; // no error signaling from MMIO
            end else if (ld_is_uart) begin
                cpu_dmem.ld_resp_valid = 1'b1; // valid at next cycle of request
                cpu_dmem.ld_resp_data = mmio_pack_rdata32(uart_mmio.mmio_rdata, cpu_dmem.ld_addr[2]);
                cpu_dmem.ld_resp_err   = 1'b0; // no error signaling from MMIO
            end
        end
        if (st_inflight || (cpu_dmem.st_valid && cpu_dmem.st_ready)) begin
            if (st_is_mem || st_hit_mem) begin
                cpu_dmem.st_resp_valid = mem_dmem.st_resp_valid;
            end else if (st_is_spi) begin
                cpu_dmem.st_resp_valid = 1'b1; // valid at next cycle of request
            end else if (st_is_uart) begin
                cpu_dmem.st_resp_valid = 1'b1; // valid at next cycle of request
            end
        end

        // ready signals: memory is dual port so fine but MMIOs we can prioritize either
        // if (ld_hit_mem || st_hit_mem) begin
        //     cpu_dmem.ld_ready = mem_dmem.ld_ready;
        //     cpu_dmem.st_ready = mem_dmem.st_ready;
        // end else if (hit_spi) begin
        //     cpu_dmem.ld_ready = cpu_dmem.ld_valid & spi_mmio.mmio_ready;
        //     cpu_dmem.st_ready = cpu_dmem.st_valid & spi_mmio.mmio_ready & (~cpu_dmem.ld_valid);
        // end else if (hit_uart) begin
        //     cpu_dmem.ld_ready = cpu_dmem.ld_valid & uart_mmio.mmio_ready;
        //     cpu_dmem.st_ready = cpu_dmem.st_valid & uart_mmio.mmio_ready & (~cpu_dmem.ld_valid);
        // end
    end
endmodule
