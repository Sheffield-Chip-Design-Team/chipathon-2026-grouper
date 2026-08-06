#ifndef __GIO_H__
#define __GIO_H__

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Formatted output and console input.
//
// Output goes through a sink rather than straight to uart_tx, so one
// formatter serves printf, snprintf and debug output. Retargeting stdout to
// the debug sink is worth knowing about: it writes to ahb_debug with no baud
// rate to wait for, where the UART holds the CPU for ~10 bit times per
// character at SYS_CLK_HZ/UART_BAUD_RATE cycles each.

typedef struct {
    void (*put)(void *ctx, char c);
    void  *ctx;
} g_sink_t;

// Where printf/puts/putchar write. Defaults to the UART.
extern g_sink_t g_stdout;

void g_set_stdout(g_sink_t s);

g_sink_t g_sink_uart(void);

// Writes via debug_char(). In a build without -DDEBUG that is a no-op, so
// this sink silently discards - which is also a usable "null sink".
g_sink_t g_sink_debug(void);

// Bounded buffer sink, as used by snprintf. Always leaves room for the NUL
// and terminates on every write; keeps counting past the end so the caller
// can see the length that would have been needed.
typedef struct {
    char   *buf;
    size_t  cap;   // total buffer size including the NUL
    size_t  len;   // characters written so far, NOT counting the NUL
} g_buf_ctx_t;

g_sink_t g_sink_buf(g_buf_ctx_t *ctx, char *buf, size_t cap);

// The one core formatter. Supports:
//   %d %i %u %x %X %o %b %c %s %p %%
//   flags: '-' (left align), '0' (zero pad), '+' (force sign), ' ' (space)
//   width: a decimal literal, or '*' to take it from an int argument
//   length: 'l' / 'll' (all widen to unsigned long - long is 32-bit on ilp32)
// Deliberately no floating point and no %n. Returns the number of characters
// written to the sink.
int g_vfprintf(g_sink_t *sink, const char *fmt, va_list ap);
int g_fprintf(g_sink_t *sink, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

int printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int vprintf(const char *fmt, va_list ap);

// Both always NUL-terminate (when cap > 0) and return the length the output
// would have had if the buffer were unbounded, like C99 snprintf.
int snprintf(char *buf, size_t cap, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
int vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap);

int puts(const char *s);        // appends '\n', like libc
int putchar(int c);

// puts without the trailing newline - what the old uart_tx_str helpers did.
int g_write_str(const char *s);

// Blocks until the UART RX FIFO has a character.
int getchar(void);
// -1 when the RX FIFO is empty.
int getchar_nb(void);

// Reads a '\n'-terminated line into buf, honouring backspace/delete.
// NUL-terminates and returns the length, excluding the newline. Stops
// accepting characters at cap-1 but keeps waiting for the newline, so an
// over-long line cannot desynchronise the next read.
//
// echo is worth thinking about rather than defaulting to true: the RX FIFO is
// only 4 deep (FIFO_DEPTH in hw/rtl/uart/uart.sv), and echoing blocks on the
// transmitter, so a sender that streams a line faster than it is echoed will
// overrun. Echo for a human at a terminal; don't for a machine feeding lines
// back to back.
int g_getline(char *buf, size_t cap, bool echo);

// g_getline with echo on.
int getline_echo(char *buf, size_t cap);

// 16 bytes per line: "<addr>: xx xx ... |ascii|". base is the address shown
// against the first line, so a dump of a peripheral's registers can be
// labelled with where it actually lives.
void hexdump(const void *buf, size_t len, uint32_t base);

#endif // __GIO_H__
