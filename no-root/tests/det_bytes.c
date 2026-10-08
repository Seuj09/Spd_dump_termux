/* tests/det_bytes.c — N pseudo-random bytes from a fixed seed, for suites that
 * need write data that looks random (0x7e/0x7d escapes in every frame) but is
 * the same on every run. /dev/urandom made the frame lengths, and with them
 * which frames end on a 512-byte packet and get a ZLP, differ per run.
 * Usage: det_bytes N [SEED] > file. xorshift32; SEED 0 is taken as 1. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

int main(int argc, char **argv)
{
	unsigned long long n, i;
	uint32_t x;
	if (argc < 2 || argc > 3) { fprintf(stderr, "usage: det_bytes N [SEED]\n"); return 2; }
	n = strtoull(argv[1], NULL, 0);
	x = argc == 3 ? (uint32_t)strtoul(argv[2], NULL, 0) : 1u;
	if (!x) x = 1;
	for (i = 0; i < n; i++) {
		x ^= x << 13; x ^= x >> 17; x ^= x << 5;
		if (putchar((int)(x >> 24)) == EOF) return 1;
	}
	return fflush(stdout) ? 1 : 0;
}
