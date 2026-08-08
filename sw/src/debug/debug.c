#include "debug.h"

#ifdef DEBUG

void debug_dec(unsigned int val) {
	char buffer[10];
	char *p = buffer;
	while (val || p == buffer) {
		*(p++) = val % 10;
		val = val / 10;
	}
	while (p != buffer) {
        debug_char('0' + *(--p));
	}
}

void debug_hex(unsigned int val, int digits) {
	for (int i = (4*digits)-4; i >= 0; i -= 4)
        debug_char("0123456789ABCDEF"[(val >> i) % 16]);
}

#endif // DEBUG
