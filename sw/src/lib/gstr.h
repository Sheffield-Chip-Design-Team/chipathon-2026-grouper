#ifndef __GSTR_H__
#define __GSTR_H__

#include <stddef.h>
#include <stdint.h>

// The string and memory half of the standard library. There is no libc here
// (-ffreestanding -nostdlib), so these are the only definitions of these
// names in the image.
//
// memcpy/memset/memmove/memcmp are NOT optional even if no source calls them
// by name: GCC emits calls to all four for struct assignment and aggregate
// initialisation regardless of -ffreestanding. Without them a large enough
// struct copy anywhere in the firmware fails to link.

void   *memcpy(void *dst, const void *src, size_t n);
void   *memset(void *dst, int c, size_t n);
void   *memmove(void *dst, const void *src, size_t n);
int     memcmp(const void *a, const void *b, size_t n);

size_t  strlen(const char *s);
size_t  strnlen(const char *s, size_t n);
int     strcmp(const char *a, const char *b);
int     strncmp(const char *a, const char *b, size_t n);
char   *strcpy(char *dst, const char *src);
char   *strncpy(char *dst, const char *src, size_t n);
char   *strchr(const char *s, int c);

// Parses a leading optional sign, an optional 0x/0b prefix when base is 0 or
// matches, then digits. On return *end (when non-NULL) points at the first
// character not consumed - so end == s means nothing was parsed.
unsigned long strtoul(const char *s, char **end, int base);
int           atoi(const char *s);

#endif // __GSTR_H__
