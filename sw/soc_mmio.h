/* soc_mmio.h */
#pragma once
#include <stdint.h>
#include <stddef.h>

/* ---------- Basic MMIO helpers (32-bit accesses) ---------- */
static inline void mmio_write32(uint32_t addr, uint32_t val) {
    *(volatile uint32_t *)(uintptr_t)addr = val;
}

static inline uint32_t mmio_read32(uint32_t addr) {
    return *(volatile uint32_t *)(uintptr_t)addr;
}

/* ---------- Peripheral Bases ---------- */
#define SPI_BASE   0x80000000u
#define UART_BASE  0x80001000u

/* ---------- SPI register offsets (byte) ---------- */
#define SPI_REG_TXRX    0x00u
#define SPI_REG_STATUS  0x04u
#define SPI_REG_CTRL    0x08u
#define SPI_REG_CLKDIV  0x0Cu
#define SPI_REG_GPIO    0x10u

/* SPI absolute addresses */
#define SPI_TXRX_ADDR    (SPI_BASE + SPI_REG_TXRX)
#define SPI_STATUS_ADDR  (SPI_BASE + SPI_REG_STATUS)
#define SPI_CTRL_ADDR    (SPI_BASE + SPI_REG_CTRL)
#define SPI_CLKDIV_ADDR  (SPI_BASE + SPI_REG_CLKDIV)
#define SPI_GPIO_ADDR    (SPI_BASE + SPI_REG_GPIO)

/* ---------- UART register offsets (byte) ---------- */
#define UART_REG_DATA      0x00u
#define UART_REG_STATUS    0x04u
#define UART_REG_CTRL      0x08u
#define UART_REG_BAUD_DIV  0x0Cu

/* UART absolute addresses */
#define UART_DATA_ADDR      (UART_BASE + UART_REG_DATA)
#define UART_STATUS_ADDR    (UART_BASE + UART_REG_STATUS)
#define UART_CTRL_ADDR      (UART_BASE + UART_REG_CTRL)
#define UART_BAUD_DIV_ADDR  (UART_BASE + UART_REG_BAUD_DIV)

/* ---------- UART STATUS bits (matches UART_contrl.sv) ----------
 * [0] RX_VALID
 * [1] TX_READY/IDLE
 * [3] TX_PENDING (holding reg full)
 * [4] RX_OVERRUN (sticky)
 * [5] TX_CAN_ACCEPT (holding reg empty)
 */
#define UART_ST_RX_VALID        (1u << 0)
#define UART_ST_TX_READY_IDLE   (1u << 1)
#define UART_ST_TX_PENDING      (1u << 3)
#define UART_ST_RX_OVERRUN      (1u << 4)
#define UART_ST_TX_CAN_ACCEPT   (1u << 5)

/* ---------- UART helpers ---------- */
static inline void uart_set_baud_div(uint32_t div) {
    mmio_write32(UART_BAUD_DIV_ADDR, div);
}

static inline uint32_t uart_status(void) {
    return mmio_read32(UART_STATUS_ADDR);
}

static inline int uart_tx_can_accept(void) {
    return (uart_status() & UART_ST_TX_CAN_ACCEPT) != 0;
}

/* Blocking putc: REQUIRED for your current UART MMIO front-end
 * because writes to DATA are dropped if TX_CAN_ACCEPT=0.
 */
static inline void uart_putc_blocking(char c) {
    while (!uart_tx_can_accept()) { /* spin */ }
    mmio_write32(UART_DATA_ADDR, (uint32_t)(uint8_t)c);
}

/* RAM-safe puts (works even if .rodata is unreadable) */
static inline void uart_puts_ram(char *s) {
    while (*s) uart_putc_blocking(*s++);
}

/* Optional: if/when you fix .rodata placement/DMEM init, you can use this */
static inline void uart_puts_const(const char *s) {
    while (*s) uart_putc_blocking(*s++);
}

/* ---------- SPI helpers (optional) ---------- */
static inline uint8_t spi_xfer(uint8_t b) {
    mmio_write32(SPI_TXRX_ADDR, (uint32_t)b);
    return (uint8_t)(mmio_read32(SPI_TXRX_ADDR) & 0xFFu);
}

static inline void spi_set_clkdiv(uint32_t div) {
    mmio_write32(SPI_CLKDIV_ADDR, div);
}

static inline uint32_t spi_status(void) {
    return mmio_read32(SPI_STATUS_ADDR);
}

static inline void spi_ctrl_write(uint32_t v) {
    mmio_write32(SPI_CTRL_ADDR, v);
}
