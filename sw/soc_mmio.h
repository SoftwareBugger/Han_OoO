#pragma once
#include <stdint.h>

/* ================= MMIO helpers ================= */
static inline void mmio_write32(uint32_t addr, uint32_t v) {
    *(volatile uint32_t *)addr = v;
}
static inline uint32_t mmio_read32(uint32_t addr) {
    return *(volatile uint32_t *)addr;
}

/* ================= Base addresses ================= */
#define SPI_BASE   0x80000000u
#define UART_BASE  0x80001000u

/* ================= SPI offsets ================= */
#define SPI_TXRX     0x00u
#define SPI_STATUS   0x04u
#define SPI_CTRL     0x08u
#define SPI_CLKDIV   0x0Cu
#define SPI_GPIO     0x10u

/* ================= UART offsets ================= */
#define UART_DATA      0x00u
#define UART_STATUS    0x04u
#define UART_CTRL      0x08u
#define UART_BAUD_DIV  0x0Cu

/* ================= UART STATUS bits ================= */
#define UART_RX_VALID       (1u << 0)
#define UART_TX_READY       (1u << 1)
#define UART_TX_PENDING     (1u << 3)
#define UART_RX_OVERRUN     (1u << 4)
#define UART_TX_CAN_ACCEPT  (1u << 5)

/* ================= SPI STATUS bits ================= */
#define SPI_READY        (1u << 0)
#define SPI_BUSY         (1u << 1)
#define SPI_CS_ASSERTED  (1u << 8)

/* ================= UART API ================= */
static inline void uart_set_baud(uint32_t div) {
    mmio_write32(UART_BASE + UART_BAUD_DIV, div);
}

static inline uint32_t uart_status(void) {
    return mmio_read32(UART_BASE + UART_STATUS);
}

static inline void uart_putc(char c) {
    while (!(uart_status() & UART_TX_CAN_ACCEPT)) {}
    mmio_write32(UART_BASE + UART_DATA, (uint32_t)c);
}

static inline uint8_t uart_getc_blocking(void) {
    while (!(uart_status() & UART_RX_VALID)) {}
    return (uint8_t)mmio_read32(UART_BASE + UART_DATA);
}

static inline int uart_getc_nonblocking(uint8_t *out) {
    if (!(uart_status() & UART_RX_VALID)) return 0;
    *out = (uint8_t)mmio_read32(UART_BASE + UART_DATA);
    return 1;
}

static inline void uart_puts_ram(char *s) {
    while (*s) {
        uart_putc(*s++);
    }
}


/* ================= SPI API ================= */
static inline uint32_t spi_status(void) {
    return mmio_read32(SPI_BASE + SPI_STATUS);
}

static inline void spi_set_clkdiv(uint32_t div) {
    mmio_write32(SPI_BASE + SPI_CLKDIV, div);
}

static inline void spi_gpio_write(uint32_t v) {
    mmio_write32(SPI_BASE + SPI_GPIO, v);
}

static inline void spi_cs_assert(void) {
    uint32_t g = mmio_read32(SPI_BASE + SPI_GPIO);
    mmio_write32(SPI_BASE + SPI_GPIO, g & ~1u);
}

static inline void spi_cs_deassert(void) {
    uint32_t g = mmio_read32(SPI_BASE + SPI_GPIO);
    mmio_write32(SPI_BASE + SPI_GPIO, g | 1u);
}

static inline uint8_t spi_xfer(uint8_t b) {
    while (!(spi_status() & SPI_READY)) {}
    mmio_write32(SPI_BASE + SPI_TXRX, b);
    while (!(spi_status() & SPI_READY)) {}
    return (uint8_t)mmio_read32(SPI_BASE + SPI_TXRX);
}

