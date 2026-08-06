#include "gstr.h"

// See gstr.h for why memcpy/memset/memmove/memcmp must exist here.
//
// These are deliberately plain byte loops. The build passes
// -fno-tree-loop-distribute-patterns precisely so GCC does not recognise the
// loop below as a memcpy and rewrite it into a call to itself.

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *) dst;
    const unsigned char *s = (const unsigned char *) src;

    while (n-- > 0) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    unsigned char *d = (unsigned char *) dst;

    while (n-- > 0) *d++ = (unsigned char) c;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *) dst;
    const unsigned char *s = (const unsigned char *) src;

    if (d == s || n == 0) return dst;

    // Copy backwards only when the regions overlap with dst above src -
    // forwards would clobber the tail of src before reading it.
    if (d < s) {
        while (n-- > 0) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n-- > 0) *(--d) = *(--s);
    }
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *p = (const unsigned char *) a;
    const unsigned char *q = (const unsigned char *) b;

    while (n-- > 0) {
        if (*p != *q) return (int) *p - (int) *q;
        p++;
        q++;
    }
    return 0;
}

size_t strlen(const char *s) {
    const char *p = s;

    while (*p != 0) p++;
    return (size_t) (p - s);
}

size_t strnlen(const char *s, size_t n) {
    size_t i = 0;

    while (i < n && s[i] != 0) i++;
    return i;
}

int strcmp(const char *a, const char *b) {
    while (*a != 0 && *a == *b) {
        a++;
        b++;
    }
    return (int) (unsigned char) *a - (int) (unsigned char) *b;
}

int strncmp(const char *a, const char *b, size_t n) {
    while (n-- > 0) {
        unsigned char u1 = (unsigned char) *a++;
        unsigned char u2 = (unsigned char) *b++;

        if (u1 != u2) return (int) u1 - (int) u2;
        if (u1 == 0) return 0;
    }
    return 0;
}

char *strcpy(char *dst, const char *src) {
    char *d = dst;

    while ((*d++ = *src++) != 0) {}
    return dst;
}

// Matches libc: pads with NULs out to n, and does NOT terminate when src is
// n or more characters long.
char *strncpy(char *dst, const char *src, size_t n) {
    size_t i = 0;

    while (i < n && src[i] != 0) {
        dst[i] = src[i];
        i++;
    }
    while (i < n) dst[i++] = 0;
    return dst;
}

char *strchr(const char *s, int c) {
    char target = (char) c;

    for (;; s++) {
        if (*s == target) return (char *) s;
        if (*s == 0) return NULL;   // strchr(s, 0) finds the terminator above
    }
}

// Returns -1 for a character that isn't a digit in this base.
static int digit_val(char c, int base) {
    int v;

    if (c >= '0' && c <= '9')      v = c - '0';
    else if (c >= 'a' && c <= 'z') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'Z') v = c - 'A' + 10;
    else                           return -1;

    return (v < base) ? v : -1;
}

unsigned long strtoul(const char *s, char **end, int base) {
    const char *p = s;
    unsigned long acc = 0;
    int neg = 0;
    int any = 0;

    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;

    if (*p == '+') {
        p++;
    } else if (*p == '-') {
        neg = 1;
        p++;
    }

    // Accept the 0x/0b prefix when it agrees with the requested base, and let
    // base 0 infer from it (0x -> 16, 0b -> 2, leading 0 -> 8, else 10).
    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')
        && digit_val(p[2], 16) >= 0) {
        p += 2;
        base = 16;
    } else if ((base == 0 || base == 2) && p[0] == '0' && (p[1] == 'b' || p[1] == 'B')
               && digit_val(p[2], 2) >= 0) {
        p += 2;
        base = 2;
    } else if (base == 0) {
        base = (p[0] == '0') ? 8 : 10;
    }

    for (;;) {
        int d = digit_val(*p, base);

        if (d < 0) break;
        acc = acc * (unsigned long) base + (unsigned long) d;
        any = 1;
        p++;
    }

    // Nothing consumed - report the original string so callers can detect it.
    if (end != NULL) *end = (char *) (any ? p : s);

    return neg ? (unsigned long) (-(long) acc) : acc;
}

int atoi(const char *s) {
    return (int) (long) strtoul(s, NULL, 10);
}
