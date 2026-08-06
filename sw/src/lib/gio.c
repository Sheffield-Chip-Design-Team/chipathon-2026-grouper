#include "gio.h"
#include "gstr.h"

#include "uart.h"
#include "debug.h"

//////////////////////////////////////////////////////////////////
// Sinks
//////////////////////////////////////////////////////////////////

static void uart_put(void *ctx, char c) {
    (void) ctx;
    uart_tx((uint8_t) c);
}

static void debug_put(void *ctx, char c) {
    (void) ctx;
    debug_char(c);      // compiles away entirely without -DDEBUG
}

static void buf_put(void *ctx, char c) {
    g_buf_ctx_t *b = (g_buf_ctx_t *) ctx;

    // Keep counting past the end so snprintf can report the length it would
    // have needed, but never write past cap-1 - the last byte is the NUL.
    if (b->cap > 0 && b->len < b->cap - 1) {
        b->buf[b->len] = c;
        b->buf[b->len + 1] = 0;
    }
    b->len++;
}

g_sink_t g_stdout = { uart_put, NULL };

void g_set_stdout(g_sink_t s) {
    g_stdout = s;
}

g_sink_t g_sink_uart(void) {
    g_sink_t s = { uart_put, NULL };
    return s;
}

g_sink_t g_sink_debug(void) {
    g_sink_t s = { debug_put, NULL };
    return s;
}

g_sink_t g_sink_buf(g_buf_ctx_t *ctx, char *buf, size_t cap) {
    g_sink_t s;

    ctx->buf = buf;
    ctx->cap = cap;
    ctx->len = 0;
    if (cap > 0) buf[0] = 0;

    s.put = buf_put;
    s.ctx = ctx;
    return s;
}

//////////////////////////////////////////////////////////////////
// Formatter
//////////////////////////////////////////////////////////////////

#define FLAG_LEFT   0x1     // '-'
#define FLAG_ZERO   0x2     // '0'
#define FLAG_PLUS   0x4     // '+'
#define FLAG_SPACE  0x8     // ' '

// Longest body is a 32-bit binary number: 32 digits, no prefix.
#define DIGITS_MAX  32

typedef struct {
    g_sink_t *sink;
    int       count;
} out_t;

static void emit(out_t *o, char c) {
    o->sink->put(o->sink->ctx, c);
    o->count++;
}

static void emit_run(out_t *o, char c, int n) {
    while (n-- > 0) emit(o, c);
}

// Digits come out least-significant first; the caller walks the buffer
// backwards. Returns how many were written.
static int to_digits(char *buf, unsigned long v, unsigned base, bool upper) {
    const char *set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;

    if (v == 0) {
        buf[n++] = '0';
        return n;
    }
    while (v != 0) {
        buf[n++] = set[v % base];
        v /= base;
    }
    return n;
}

// sign is '\0' when there is none. prefix is "" or "0x". prec is the minimum
// digit count (-1 when unspecified).
static void emit_num(out_t *o, unsigned long v, unsigned base, bool upper,
                     char sign, const char *prefix, int width, int prec,
                     int flags) {
    char digits[DIGITS_MAX];
    int  ndig = to_digits(digits, v, base, upper);
    int  plen = (int) strlen(prefix);
    int  zeros = (prec > ndig) ? prec - ndig : 0;
    int  len, pad;

    // An explicit precision overrides '0' - the field is then space padded.
    if ((flags & FLAG_ZERO) != 0 && (flags & FLAG_LEFT) == 0 && prec < 0) {
        zeros = width - ndig - plen - (sign != 0 ? 1 : 0);
        if (zeros < 0) zeros = 0;
    }

    len = ndig + zeros + plen + (sign != 0 ? 1 : 0);
    pad = (width > len) ? width - len : 0;

    if ((flags & FLAG_LEFT) == 0) emit_run(o, ' ', pad);

    // Sign and prefix precede the zero padding, never follow it.
    if (sign != 0) emit(o, sign);
    while (*prefix != 0) emit(o, *prefix++);
    emit_run(o, '0', zeros);
    while (ndig > 0) emit(o, digits[--ndig]);

    if ((flags & FLAG_LEFT) != 0) emit_run(o, ' ', pad);
}

static void emit_str(out_t *o, const char *s, int width, int prec, int flags) {
    int len, pad;

    if (s == NULL) s = "(null)";

    len = (prec >= 0) ? (int) strnlen(s, (size_t) prec) : (int) strlen(s);
    pad = (width > len) ? width - len : 0;

    if ((flags & FLAG_LEFT) == 0) emit_run(o, ' ', pad);
    for (int i = 0; i < len; i++) emit(o, s[i]);
    if ((flags & FLAG_LEFT) != 0) emit_run(o, ' ', pad);
}

int g_vfprintf(g_sink_t *sink, const char *fmt, va_list ap) {
    out_t o = { sink, 0 };

    for (; *fmt != 0; fmt++) {
        int  flags = 0;
        int  width = 0;
        int  prec = -1;
        bool is_long = false;

        if (*fmt != '%') {
            emit(&o, *fmt);
            continue;
        }
        fmt++;

        for (;; fmt++) {
            if      (*fmt == '-') flags |= FLAG_LEFT;
            else if (*fmt == '0') flags |= FLAG_ZERO;
            else if (*fmt == '+') flags |= FLAG_PLUS;
            else if (*fmt == ' ') flags |= FLAG_SPACE;
            else break;
        }

        if (*fmt == '*') {
            width = va_arg(ap, int);
            // A negative '*' width means left aligned, per C.
            if (width < 0) {
                flags |= FLAG_LEFT;
                width = -width;
            }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        }

        if (*fmt == '.') {
            fmt++;
            prec = 0;
            if (*fmt == '*') {
                prec = va_arg(ap, int);
                fmt++;
            } else {
                while (*fmt >= '0' && *fmt <= '9') prec = prec * 10 + (*fmt++ - '0');
            }
            if (prec < 0) prec = -1;
        }

        // long is 32 bits on ilp32, so l/ll/z/h all reduce to the same read.
        while (*fmt == 'l' || *fmt == 'z' || *fmt == 'h') {
            if (*fmt == 'l' || *fmt == 'z') is_long = true;
            fmt++;
        }

        switch (*fmt) {
            case 'd':
            case 'i': {
                long  v = is_long ? va_arg(ap, long) : (long) va_arg(ap, int);
                char  sign = 0;
                unsigned long mag;

                if (v < 0) {
                    sign = '-';
                    // Negate as unsigned so LONG_MIN survives the trip.
                    mag = -(unsigned long) v;
                } else {
                    mag = (unsigned long) v;
                    if ((flags & FLAG_PLUS) != 0)       sign = '+';
                    else if ((flags & FLAG_SPACE) != 0) sign = ' ';
                }
                emit_num(&o, mag, 10, false, sign, "", width, prec, flags);
                break;
            }
            case 'u':
                emit_num(&o, is_long ? va_arg(ap, unsigned long)
                                     : (unsigned long) va_arg(ap, unsigned int),
                         10, false, 0, "", width, prec, flags);
                break;
            case 'x':
            case 'X':
                emit_num(&o, is_long ? va_arg(ap, unsigned long)
                                     : (unsigned long) va_arg(ap, unsigned int),
                         16, *fmt == 'X', 0, "", width, prec, flags);
                break;
            case 'o':
                emit_num(&o, is_long ? va_arg(ap, unsigned long)
                                     : (unsigned long) va_arg(ap, unsigned int),
                         8, false, 0, "", width, prec, flags);
                break;
            case 'b':
                emit_num(&o, is_long ? va_arg(ap, unsigned long)
                                     : (unsigned long) va_arg(ap, unsigned int),
                         2, false, 0, "", width, prec, flags);
                break;
            case 'p':
                // Always 0x + 8 digits, so pointers line up in a column.
                // Carried by the precision rather than the width so the "0x"
                // does not eat into the digit count.
                emit_num(&o, (unsigned long) (uintptr_t) va_arg(ap, void *),
                         16, false, 0, "0x", width, 8, flags);
                break;
            case 'c':
                emit(&o, (char) va_arg(ap, int));
                break;
            case 's':
                emit_str(&o, va_arg(ap, const char *), width, prec, flags);
                break;
            case '%':
                emit(&o, '%');
                break;
            case 0:
                fmt--;              // trailing '%' - stop without running off the end
                break;
            default:                // unknown specifier - echo it back verbatim
                emit(&o, '%');
                emit(&o, *fmt);
                break;
        }
    }

    return o.count;
}

int g_fprintf(g_sink_t *sink, const char *fmt, ...) {
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = g_vfprintf(sink, fmt, ap);
    va_end(ap);
    return n;
}

int vprintf(const char *fmt, va_list ap) {
    return g_vfprintf(&g_stdout, fmt, ap);
}

int printf(const char *fmt, ...) {
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = g_vfprintf(&g_stdout, fmt, ap);
    va_end(ap);
    return n;
}

int vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap) {
    g_buf_ctx_t ctx;
    g_sink_t    sink = g_sink_buf(&ctx, buf, cap);

    g_vfprintf(&sink, fmt, ap);
    return (int) ctx.len;       // the length it would have needed, C99 style
}

int snprintf(char *buf, size_t cap, const char *fmt, ...) {
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    return n;
}

int g_write_str(const char *s) {
    int n = 0;

    while (*s != 0) {
        g_stdout.put(g_stdout.ctx, *s++);
        n++;
    }
    return n;
}

int puts(const char *s) {
    int n = g_write_str(s);

    g_stdout.put(g_stdout.ctx, '\n');
    return n + 1;
}

int putchar(int c) {
    g_stdout.put(g_stdout.ctx, (char) c);
    return c;
}

//////////////////////////////////////////////////////////////////
// Console input
//////////////////////////////////////////////////////////////////

int getchar(void) {
    // Reading RXDATA while the FIFO is empty is flagged as an invalid access
    // by ahb_uart and raises IRQ_BUS_ERR, so the check is not optional.
    while (uart_status().s.status_rx_empty != 0) {}
    return (int) uart_rx();
}

int getchar_nb(void) {
    if (uart_status().s.status_rx_empty != 0) return -1;
    return (int) uart_rx();
}

int g_getline(char *buf, size_t cap, bool echo) {
    size_t len = 0;

    if (cap == 0) return 0;

    for (;;) {
        int c = getchar();

        if (c == '\n' || c == '\r') {
            if (echo) putchar('\n');
            break;
        }

        if (c == '\b' || c == 0x7f) {
            if (len > 0) {
                len--;
                if (echo) g_write_str("\b \b");
            }
            continue;
        }

        // Keep consuming to the newline once full, so an over-long line
        // cannot leave its tail behind for the next read to pick up.
        if (c != 0 && len < cap - 1) {
            buf[len++] = (char) c;
            if (echo) putchar(c);
        }
    }

    buf[len] = 0;
    return (int) len;
}

int getline_echo(char *buf, size_t cap) {
    return g_getline(buf, cap, true);
}

//////////////////////////////////////////////////////////////////
// hexdump
//////////////////////////////////////////////////////////////////

void hexdump(const void *buf, size_t len, uint32_t base) {
    const uint8_t *p = (const uint8_t *) buf;

    for (size_t off = 0; off < len; off += 16) {
        size_t n = (len - off < 16) ? len - off : 16;

        printf("%08x: ", (unsigned) (base + off));

        for (size_t i = 0; i < 16; i++) {
            if (i < n) printf("%02x ", p[off + i]);
            else       g_write_str("   ");
        }

        putchar('|');
        for (size_t i = 0; i < n; i++) {
            uint8_t c = p[off + i];
            putchar((c >= 0x20 && c < 0x7f) ? c : '.');
        }
        puts("|");
    }
}
