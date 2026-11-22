/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef DVBT_TX_PROFILE_H
#define DVBT_TX_PROFILE_H
#include <errno.h>
#include <arpa/inet.h>
#include <math.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifdef LIBRESDR_V1
#define MAXMUX 1
#define DEFAULT_INPUT "udp:1001"
#define DEFAULT_FREQUENCY 474000000LL
static int valid_nmux(int n) { return n == 1; }
#else
#define MAXMUX 4
#define DEFAULT_INPUT NULL
#define DEFAULT_FREQUENCY 0LL
static int valid_nmux(int n) { return n == 1 || n == 2 || n == 4; }
#endif

static int parse_mute(const char *s, int n, uint32_t *mask)
{
    char *end;
    errno = 0;
    unsigned long v = strtoul(s, &end, 0);
    if (!s[0] || s[0] == '-' || *end || errno || v >= (1u << n))
        return -1;
    *mask = (uint32_t)v;
    return 0;
}

static int input_port(const char *spec)
{
    if (strncmp(spec, "udp:", 4))
        return 0;
    const char *colon = strrchr(spec, ':');
    const char *s = colon + 1;
    if (colon != spec + 3) {
        char group[64];
        size_t length = (size_t)(colon - (spec + 4));
        struct in_addr address;
        if (!length || length >= sizeof group)
            return -1;
        memcpy(group, spec + 4, length);
        group[length] = 0;
        if (inet_pton(AF_INET, group, &address) != 1 ||
            (ntohl(address.s_addr) >> 28) != 0xE)
            return -1;
    }
    char *end;
    errno = 0;
    long port = strtol(s, &end, 10);
    return !*s || *end || errno || port < 1 || port > 65535 ? -1 : (int)port;
}

static int parse_integer(const char *s, long long low, long long high, long long *value)
{
    char *end;
    errno = 0;
    long long v = strtoll(s, &end, 10);
    if (!*s || *end || errno || v < low || v > high)
        return -1;
    *value = v;
    return 0;
}

static int parse_attenuation(const char *s, double *value)
{
    char *end;
    errno = 0;
    double v = strtod(s, &end);
    if (!*s || *end || errno || !isfinite(v) || v < 0 || v > 89.75)
        return -1;
    *value = v;
    return 0;
}
#endif
