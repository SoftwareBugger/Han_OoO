#pragma once
#include <stdint.h>

/* ============================================================
 * Compiler + MMIO barriers
 * ============================================================ */
static void mmio_barrier(void) {
    __asm__ volatile ("" ::: "memory");
}

/* ============================================================
 * MMIO helpers (volatile at the access point)
 * ============================================================ */
static void mmio_write32(uint32_t addr, uint32_t v) {
    *(volatile uint32_t *)addr = v;
    mmio_barrier();
}

static uint32_t mmio_read32(uint32_t addr) {
    uint32_t v = *(volatile uint32_t *)addr;
    mmio_barrier();
    return v;
}

/* ============================================================
 * Base addresses
 * ============================================================ */
#define SPI_BASE    0x80000000u
#define UART_BASE   0x80001000u

/* ============================================================
 * SPI register offsets
 * ============================================================ */
#define SPI_TXRX    0x00u
#define SPI_STATUS  0x04u
#define SPI_CTRL    0x08u
#define SPI_CLKDIV  0x0Cu
#define SPI_GPIO    0x10u

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
#define SPI_CTRL_EN        (1u << 8)

/* ============================================================
 * SPI GPIO bits (OLED style)
 * ============================================================ */
#define SPI_GPIO_CS_N   (1u << 0)   /* active low */
#define SPI_GPIO_DC    (1u << 1)
#define SPI_GPIO_RES_N (1u << 2)

/* ============================================================
 * UART API (safe + blocking)
 * ============================================================ */
static void uart_set_baud(uint32_t div) {
    mmio_write32(UART_BASE + UART_BAUDDIV, div);
}

static uint32_t uart_status(void) {
    return mmio_read32(UART_BASE + UART_STATUS);
}

static void uart_putc(char c) {
    while (!(uart_status() & UART_TX_CAN_ACCEPT)) {}
    mmio_write32(UART_BASE + UART_DATA, (uint32_t)(uint8_t)c);
}

static void uart_puts_ram(const char *s) {
    while (*s) uart_putc(*s++);
}

static uint8_t uart_getc_blocking(void) {
    while (!(uart_status() & UART_RX_VALID)) {}
    return (uint8_t)mmio_read32(UART_BASE + UART_DATA);
}

/* ============================================================
 * SPI GPIO helpers (atomic RMW)
 * ============================================================ */
static void spi_gpio_update(uint32_t set, uint32_t clr) {
    uint32_t g = mmio_read32(SPI_BASE + SPI_GPIO);
    g |= set;
    g &= ~clr;
    mmio_write32(SPI_BASE + SPI_GPIO, g);
}

static void spi_cs_assert(void) {
    spi_gpio_update(0, SPI_GPIO_CS_N);
}

static void spi_cs_deassert(void) {
    /* wait until transaction finishes */
    while (mmio_read32(SPI_BASE + SPI_STATUS) & SPI_BUSY) {}
    spi_gpio_update(SPI_GPIO_CS_N, 0);
}

static void spi_dc_cmd(void) {
    spi_gpio_update(0, SPI_GPIO_DC);
}

static void spi_dc_data(void) {
    spi_gpio_update(SPI_GPIO_DC, 0);
}

static void spi_res_assert(void) {
    spi_gpio_update(0, SPI_GPIO_RES_N);
}

static void spi_res_deassert(void) {
    spi_gpio_update(SPI_GPIO_RES_N, 0);
}

/* ============================================================
 * SPI init
 * ============================================================ */
static void spi_init(uint32_t clkdiv, uint32_t ctrl_bits) {
    mmio_write32(SPI_BASE + SPI_CLKDIV, clkdiv);
    mmio_write32(SPI_BASE + SPI_CTRL, ctrl_bits);
    spi_cs_deassert();
}

/* ============================================================
 * SPI transfer (HARDENED, RX CANNOT DISAPPEAR)
 * ============================================================ */
uint8_t spi_xfer(uint8_t tx)
{
    __asm__ volatile ("" ::: "memory");
    /* wait until SPI can start */
    while (!(mmio_read32(SPI_BASE + SPI_STATUS) & SPI_READY)) {}

    mmio_write32(SPI_BASE + SPI_TXRX, (uint32_t)tx);

    /* wait until transaction finishes */
    while (mmio_read32(SPI_BASE + SPI_STATUS) & SPI_BUSY) {}

    volatile uint8_t rx = (uint8_t)mmio_read32(SPI_BASE + SPI_TXRX);

    return rx;
    __asm__ volatile ("" ::: "memory");
}

/* ============================================================
 * SPI burst helpers (UART-safe)
 * ============================================================ */
static void spi_write_bytes(const uint8_t *buf, int len) {
    for (int i = 0; i < len; i++) {
        (void)spi_xfer(buf[i]);
    }
}

static void spi_txn_write_bytes(const uint8_t *buf, int len) {
    spi_cs_assert();
    mmio_barrier();
    spi_write_bytes(buf, len);
    mmio_barrier();
    spi_cs_deassert();
}
