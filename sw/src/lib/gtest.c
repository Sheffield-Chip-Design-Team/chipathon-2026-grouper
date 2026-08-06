#include "gtest.h"
#include "gio.h"
#include "gstr.h"
#include "gtime.h"

#include "uart.h"
#include "debug.h"

static const char *test_name = "(unnamed)";
static unsigned    checks_run;
static unsigned    checks_passed;

void g_test_begin(const char *name) {
    test_name = name;
    checks_run = 0;
    checks_passed = 0;
    printf("TEST_BEGIN: %s\n", name);
}

bool g_check(bool cond, const char *expr, int line) {
    checks_run++;
    if (cond) {
        checks_passed++;
    } else {
        printf("  FAIL line %d: %s\n", line, expr);
    }
    return cond;
}

bool g_check_eq_u(uint32_t got, uint32_t expect, const char *expr, int line) {
    checks_run++;
    if (got == expect) {
        checks_passed++;
        return true;
    }
    printf("  FAIL line %d: %s -- expected %u (0x%x), got %u (0x%x)\n",
           line, expr,
           (unsigned) expect, (unsigned) expect,
           (unsigned) got, (unsigned) got);
    return false;
}

bool g_check_eq_str(const char *got, const char *expect, const char *expr,
                    int line) {
    checks_run++;
    if (got != NULL && expect != NULL && strcmp(got, expect) == 0) {
        checks_passed++;
        return true;
    }
    printf("  FAIL line %d: %s -- expected \"%s\", got \"%s\"\n",
           line, expr,
           expect != NULL ? expect : "(null)",
           got != NULL ? got : "(null)");
    return false;
}

int g_test_end(void) {
    printf("TEST_RESULT: %s (%u/%u) [%s]\n",
           (checks_passed == checks_run) ? "PASS" : "FAIL",
           checks_passed, checks_run, test_name);
    g_sim_exit();
}

void g_sim_exit(void) {
    // Let the last bytes clear the transmit shift register before stopping,
    // or the tail of the summary line never reaches the testbench.
    //
    // Bounded, unlike the open-ended spin this replaces: this is the stop
    // path, and it is reached from the fault handler, where the UART may be
    // exactly what is broken. A character costs ~SYS_CLK_HZ/baud * 10 cycles,
    // so this is several characters' worth of grace and no more.
    uint32_t start = g_cycles();

    while (uart_status().s.status_tx_active != 0) {
        if ((g_cycles() - start) > (SYS_CLK_HZ / 100)) break;   // 10 ms
    }

    debug(0xff, 0xDEAD600D);

    while (1) {}
}
