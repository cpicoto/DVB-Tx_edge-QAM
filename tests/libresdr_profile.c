/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include "../src/sw/dvbt_tx_profile.h"

int main(void)
{
    uint32_t mask = 42;
#ifdef LIBRESDR_V1
    assert(MAXMUX == 1);
    assert(DEFAULT_FREQUENCY == 474000000LL);
    assert(!strcmp(DEFAULT_INPUT, "udp:1001"));
    assert(!valid_nmux(2) && !valid_nmux(4));
#else
    assert(valid_nmux(2) && valid_nmux(4));
    assert(parse_mute("15", 4, &mask) == 0 && mask == 15);
#endif
    assert(valid_nmux(1));
    assert(!valid_nmux(0) && !valid_nmux(3));
    assert(parse_mute("0", 1, &mask) == 0 && mask == 0);
    assert(parse_mute("1", 1, &mask) == 0 && mask == 1);
    assert(parse_mute("0x1", 1, &mask) == 0 && mask == 1);
    assert(parse_mute("2", 1, &mask) < 0);
    assert(parse_mute("-1", 1, &mask) < 0);
    assert(parse_mute("1junk", 1, &mask) < 0);
    assert(parse_mute("", 1, &mask) < 0);
    assert(parse_mute("18446744073709551616", 1, &mask) < 0);
    assert(input_port("udp:1001") == 1001);
    assert(input_port("udp:239.1.2.3:1001") == 1001);
    assert(input_port("udp:65535") == 65535);
    assert(input_port("udp:0") < 0 && input_port("udp:65536") < 0);
    assert(input_port("udp:-1") < 0 && input_port("udp:") < 0);
    assert(input_port("udp:1001junk") < 0);
    assert(input_port("udp::1001") < 0);
    assert(input_port("udp:not-a-group:1001") < 0);
    assert(input_port("udp:127.0.0.1:1001") < 0);
    assert(input_port("file:/in.ts") == 0);
    long long frequency;
    double attenuation;
    assert(parse_integer("474000000", 70000000, 6000000000LL, &frequency) == 0);
    assert(frequency == 474000000);
    assert(parse_integer("474000000junk", 70000000, 6000000000LL, &frequency) < 0);
    assert(parse_attenuation("89.75", &attenuation) == 0 && attenuation == 89.75);
    assert(parse_attenuation("nan", &attenuation) < 0);
    assert(parse_attenuation("inf", &attenuation) < 0);
    assert(parse_attenuation("30garbage", &attenuation) < 0);
    assert(parse_attenuation("-1", &attenuation) < 0);
    return 0;
}
