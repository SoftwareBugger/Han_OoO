#pragma once
#include <stdint.h>
#include <stdbool.h>

/* ============================================================
 * MMIO helpers (volatile at the access point)
 * ============================================================ */
static inline void mmio_write32(uint32_t addr, uint32_t v) {
    *(volatile uint32_t *)addr = v;
}

static uint32_t mmio_read32(uint32_t addr) {
    uint32_t v = *(volatile uint32_t *)addr;
    return v;
}

static inline void delay_cycles(volatile uint32_t n) {
    while (n--) __asm__ volatile("nop");
}

/* ============================================================
 * Base addresses
 * ============================================================ */
#define SPI_BASE    0x80000000u
#define UART_BASE   0x80001000u

/* ============================================================
 * SPI register offsets
 * ============================================================ */
#define SPI_TX    0x00u
#define SPI_RX    0x04u
#define SPI_STATUS  0x08u
#define SPI_CTRL    0x0Cu
#define SPI_CLKDIV  0x10u
#define SPI_GPIO    0x14u

/* ============================================================
 * UART register offsets
 * ============================================================ */
#define UART_DATA     0x00u
#define UART_STATUS   0x04u
#define UART_CTRL     0x08u
#define UART_BAUDDIV  0x0Cu

/* ============================================================
 * UART STATUS bits
 * ============================================================ */
#define UART_RX_VALID      (1u << 0)
#define UART_TX_READY      (1u << 1)
#define UART_TX_PENDING    (1u << 3)
#define UART_RX_OVERRUN    (1u << 4)
#define UART_TX_CAN_ACCEPT (1u << 5)

/* ============================================================
 * SPI STATUS bits
 * ============================================================ */
#define SPI_READY       (1u << 0)   /* can accept TX */
#define SPI_BUSY        (1u << 1)   /* transaction in progress */
#define SPI_CS_ASSERTED (1u << 8)

/* ============================================================
 * SPI CTRL bits
 * ============================================================ */
#define SPI_CTRL_POS_EDGE  (1u << 0)
#define SPI_CTRL_WIDTH8    (1u << 1)
#define SPI_CTRL_CLK_PHASE  (1u << 2)
#define SPI_CTRL_EN        (1u << 8)

/* ============================================================
 * SPI GPIO bits (OLED style)
 * ============================================================ */
#define SPI_GPIO_CS_N   (1u << 0)   /* active low */
#define SPI_GPIO_DC    (1u << 1)
#define SPI_GPIO_RES_N (1u << 2)
// In soc_mmio.h (or your app)
#define SPI_GPIO_VCCEN   (1u << 3)  // pin 9 Vcc Enable (active-high)
#define SPI_GPIO_PMODEN  (1u << 4)  // pin 10 Pmod Enable (active-high)


/* ============================================================
 * UART API (safe + blocking)
 * ============================================================ */
static inline void uart_set_baud(uint32_t div) {
    mmio_write32(UART_BASE + UART_BAUDDIV, div);
}

static uint32_t uart_status(void) {
    return mmio_read32(UART_BASE + UART_STATUS);
}

static inline void uart_putc(char c) {
    while (!(uart_status() & UART_TX_CAN_ACCEPT)) {}
    mmio_write32(UART_BASE + UART_DATA, (uint32_t)(uint8_t)c);
}

static inline void uart_puts_ram(const char *s) {
    while (*s) uart_putc(*s++);
}

static uint8_t uart_getc_blocking(void) {
    while (!(uart_status() & UART_RX_VALID)) {}
    return (uint8_t)mmio_read32(UART_BASE + UART_DATA);
}

static inline char _hex_nibble(uint8_t v) {
    return (v < 10) ? ('0' + v) : ('A' + (v - 10));
}

static inline void uart_puthex8(uint8_t v) {
    uart_putc(_hex_nibble((v >> 4) & 0xF));
    uart_putc(_hex_nibble(v & 0xF));
}

static inline void uart_putdec(int v) {
    char buf[12];
    int i = 0;

    if (v == 0) {
        uart_putc('0');
        return;
    }

    if (v < 0) {
        uart_putc('-');
        v = -v;
    }

    while (v > 0) {
        buf[i++] = '0' + (v % 10);
        v /= 10;
    }

    while (i--) {
        uart_putc(buf[i]);
    }
}

// Print a 32-bit value as 8 hex chars
static inline void uart_puthex(uint32_t v) {
    uart_putc(_hex_nibble((v >> 28) & 0xF));
    uart_putc(_hex_nibble((v >> 24) & 0xF));
    uart_putc(_hex_nibble((v >> 20) & 0xF));
    uart_putc(_hex_nibble((v >> 16) & 0xF));
    uart_putc(_hex_nibble((v >> 12) & 0xF));
    uart_putc(_hex_nibble((v >>  8) & 0xF));
    uart_putc(_hex_nibble((v >>  4) & 0xF));
    uart_putc(_hex_nibble((v >>  0) & 0xF));
}



/* ============================================================
 * MMIO “barrier” primitives (software-only)
 * ============================================================
 *
 * Without a real fence instruction, the most reliable pattern is:
 *   MMIO write -> MMIO readback
 * because it creates an observable dependency in the LSU.
 */

static inline void mmio_write32_rb(uint32_t addr, uint32_t v) {
    mmio_write32(addr, v);
    (void)mmio_read32(addr);  // readback barrier
}

static inline uint32_t spi_status(void) {
    return mmio_read32(SPI_BASE + SPI_STATUS);
}

/* Optional: a generic “I/O barrier” using a benign status read */
static inline void io_barrier(void) {
    (void)spi_status();
}

/* ============================================================
 * GPIO helpers (robust, ordered)
 * ============================================================
 *
 * RMW is OK only if SPI_GPIO is a pure output latch.
 * If it isn’t, you should implement separate SET/CLR registers in hardware.
 */

static inline uint32_t spi_gpio_read(void) {
    return mmio_read32(SPI_BASE + SPI_GPIO);
}

static inline void spi_gpio_write(uint32_t v) {
    mmio_write32_rb(SPI_BASE + SPI_GPIO, v);
}

static inline void spi_gpio_update(uint32_t set, uint32_t clr) {
    uint32_t g = spi_gpio_read();
    g |= set;
    g &= ~clr;
    spi_gpio_write(g);   // includes readback barrier
}

/* ============================================================
 * CS/DC/RES control (ordered)
 * ============================================================
 */

static inline void spi_cs_assert(void) {
    spi_gpio_update(0, SPI_GPIO_CS_N);  // CS_N=0
    io_barrier();                       // ensure visible before any clocks
    delay_cycles(10);                   // tiny margin; not relied upon
}

static inline void spi_cs_deassert(void) {
    /* Ensure any in-flight SPI engine work is finished first */
    while (spi_status() & SPI_BUSY) { }
    io_barrier();                       // ensure BUSY=0 observed before CS high
    spi_gpio_update(SPI_GPIO_CS_N, 0);  // CS_N=1
    io_barrier();
    delay_cycles(10);
}

static inline void spi_dc_cmd(void) {
    spi_gpio_update(0, SPI_GPIO_DC);    // DC=0
    io_barrier();
}

static inline void spi_dc_data(void) {
    spi_gpio_update(SPI_GPIO_DC, 0);    // DC=1
    io_barrier();
}

static inline void spi_res_assert(void) {
    spi_gpio_update(0, SPI_GPIO_RES_N); // RES_N=0
    io_barrier();
}

static inline void spi_res_deassert(void) {
    spi_gpio_update(SPI_GPIO_RES_N, 0); // RES_N=1
    io_barrier();
}

/* Power control pins */
static inline void oled_vccen_on(void)  { spi_gpio_update(SPI_GPIO_VCCEN, 0); }
static inline void oled_vccen_off(void) { spi_gpio_update(0, SPI_GPIO_VCCEN); }

static inline void oled_pmoden_on(void) { spi_gpio_update(SPI_GPIO_PMODEN, 0); }
static inline void oled_pmoden_off(void){ spi_gpio_update(0, SPI_GPIO_PMODEN); }

/* ============================================================
 * SPI init (ordered)
 * ============================================================
 */

static inline void spi_init(uint32_t clkdiv, uint32_t ctrl_bits) {
    mmio_write32_rb(SPI_BASE + SPI_CLKDIV, clkdiv);
    mmio_write32_rb(SPI_BASE + SPI_CTRL,   ctrl_bits);
    io_barrier();
    spi_cs_deassert();
}

/* ============================================================
 * SPI transfer (ROBUST)
 * ============================================================
 *
 * Key points:
 *  - wait READY (device accepts TX)
 *  - write TX with readback barrier (or status read barrier)
 *  - wait BUSY clear (byte finished)
 *  - read RX (even if you ignore it) to create an ordering dependency
 *
 * This makes “TX happened” and “byte finished” non-reorderable in practice,
 * even without a fence instruction.
 */

static inline uint8_t spi_xfer(uint8_t tx) {
    while (!(spi_status() & SPI_READY)) { }

    /* Write TX and immediately create a device-ordering dependency */
    mmio_write32(SPI_BASE + SPI_TX, (uint32_t)tx);
    io_barrier();  // forces the store to be observed before we proceed

    /* Wait for the byte to complete */
    while (spi_status() & SPI_BUSY) { }

    /* Read RX to anchor completion + prevent “RX disappearing” issues */
    uint8_t rx = (uint8_t)mmio_read32(SPI_BASE + SPI_RX);
    io_barrier();
    return rx;
}

/* ============================================================
 * Transaction helpers (THIS is what you were missing)
 * ============================================================
 */

static inline void spi_cmd_begin(void) {
    /* DC must be stable before CS and before first SCLK edge */
    spi_dc_cmd();
    spi_cs_assert();
}

static inline void spi_data_begin(void) {
    spi_dc_data();
    spi_cs_assert();
}

static inline void spi_txn_end(void) {
    spi_cs_deassert();
}

static inline void spi_write_bytes(const uint8_t *buf, int len) {
    for (int i = 0; i < len; i++) {
        (void)spi_xfer(buf[i]);
    }
}

/* ============================================================
 * OLED command helpers (correct framing!)
 * ============================================================
 */

static inline void oled_write_cmd(uint8_t c) {
    spi_cmd_begin();
    (void)spi_xfer(c);
    spi_txn_end();
}

static inline void oled_write_cmd2(uint8_t c, uint8_t d0) {
    spi_cmd_begin();
    (void)spi_xfer(c);
    (void)spi_xfer(d0);
    spi_txn_end();
}

static inline void oled_write_cmdN(const uint8_t *buf, int n) {
    spi_cmd_begin();
    spi_write_bytes(buf, n);
    spi_txn_end();
}

static inline void oled_write_dataN(const uint8_t *buf, int n) {
    spi_data_begin();
    spi_write_bytes(buf, n);
    spi_txn_end();
}

/* ============================================================
 * Reset pulse helper
 * ============================================================
 */
#define SIMULATION
#ifdef SIMULATION
static inline void delay_ms(uint32_t ms) {
    while (ms--) delay_cycles(1); // adjust
}
#else
static inline void delay_ms(uint32_t ms) {
    while (ms--) delay_cycles(50000); // adjust
}
#endif

static inline void oled_reset_pulse(void) {
    spi_res_deassert(); // RES_N=1
    delay_ms(1);
    spi_res_assert();   // RES_N=0
    delay_ms(1);
    spi_res_deassert(); // RES_N=1
    delay_ms(1);
}


void oled_init_ssd1331(void) {
    // 1) D/C low
    spi_cs_assert();
    spi_dc_cmd();

    // 2) RES high
    spi_res_deassert();

    // 3) VCCEN low
    oled_vccen_off();

    // 4) PMODEN high, wait 20ms for 3.3V rail stable
    oled_pmoden_on();
    delay_ms(20);

    // 5) reset pulse
    oled_reset_pulse();

    // 6) unlock
    oled_write_cmd2(0xFD, 0x12);

    // 7) display off
    oled_write_cmd(0xAE);

    // 8) remap / color depth
    oled_write_cmd2(0xA0, 0x72);

    // 9) start line
    oled_write_cmd2(0xA1, 0x00);

    // 10) display offset
    oled_write_cmd2(0xA2, 0x00);

    // 11) normal display
    oled_write_cmd(0xA4);

    // 12) multiplex ratio
    oled_write_cmd2(0xA8, 0x3F);

    // 13) master configuration (external Vcc)
    oled_write_cmd2(0xAD, 0x8E);

    // 14) disable power saving
    oled_write_cmd2(0xB0, 0x0B);

    // 15) phase length
    oled_write_cmd2(0xB1, 0x31);

    // 16) clock div + osc freq
    oled_write_cmd2(0xB3, 0xF0);

    // 17-19) 2nd precharge speed A/B/C
    // NOTE from your text: must update all 3 sequentially (6 bytes)
    {
        const uint8_t seq[] = { 0x8A, 0x64, 0x8B, 0x78, 0x8C, 0x64 };
        oled_write_cmdN(seq, (int)sizeof(seq));
    }

    // 20) precharge voltage
    oled_write_cmd2(0xBB, 0x3A);

    // 21) VCOMH deselect level
    oled_write_cmd2(0xBE, 0x3E);

    // 22) master current attenuation
    oled_write_cmd2(0x87, 0x06);

    // // 'Set Column Address' - default is 0-95, which is
    // // also what we want.
    uint8_t col_addr[] = {0x15, 0x00, 0x5F};
    oled_write_cmdN(col_addr, (int)sizeof(col_addr));
    // 'Set Row Address' - default is 0-63, which is good.
    uint8_t row_addr[] = {0x75, 0x00, 0x3F};
    oled_write_cmdN(row_addr, (int)sizeof(row_addr));

    // 23-25) contrast A/B/C
    oled_write_cmd2(0x81, 0x91);
    oled_write_cmd2(0x82, 0x50);
    oled_write_cmd2(0x83, 0x7D);

    // 26) disable scrolling
    oled_write_cmd(0x2E);

    // 27) clear window (0,0)-(0x5F,0x3F) for 96x64
    {
        const uint8_t clr[] = { 0x25, 0x00, 0x00, 0x5F, 0x3F };
        oled_write_cmdN(clr, (int)sizeof(clr));
    }

    // 28) VCCEN high, wait 25ms
    oled_vccen_on();
    delay_ms(25);

    // 29) display on
    oled_write_cmd(0xAF);

    // 30) wait 100ms
    delay_ms(100);
}

void oled_copy_obj(uint8_t col_start, uint8_t row_start, uint8_t col_end, uint8_t row_end, uint8_t new_col, uint8_t new_row) {
    uint8_t cmd_buf[7] = {
        0x23, // Copy Window
        col_start,
        row_start,
        col_end,
        row_end,
        new_col,
        new_row
    };
    oled_write_cmdN(cmd_buf, 7);
}

void oled_clear_window(uint8_t col_start, uint8_t row_start, uint8_t col_end, uint8_t row_end) {
    uint8_t cmd_buf[5] = {
        0x25, // Clear Window
        col_start,
        row_start,
        col_end,
        row_end
    };
    oled_write_cmdN(cmd_buf, 5);
}

void oled_draw_object(uint8_t col_start, uint8_t row_start, uint8_t col_end, uint8_t row_end, const uint8_t *data) {
    // Set column and row address window
    uint8_t col_addr[] = {0x15, col_start, col_end};
    oled_write_cmdN(col_addr, (int)sizeof(col_addr));
    uint8_t row_addr[] = {0x75, row_start, row_end};
    oled_write_cmdN(row_addr, (int)sizeof(row_addr));
    // Write pixel data
    int num_pixels = (col_end - col_start + 1) * (row_end - row_start + 1);
    oled_write_dataN(data, num_pixels * 2); // assuming RGB565 (2 bytes per pixel)
}






