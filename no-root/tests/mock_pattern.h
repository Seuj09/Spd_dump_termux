/* Deterministic partition contents shared by mock_fdl2.c and gen_expected.c. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static uint8_t pattern_byte(uint64_t o) { uint64_t x = o * 0x9E3779B97F4A7C15ull; return (uint8_t)(x >> 56) ^ (uint8_t)(o >> 32); }
static uint8_t name_seed(const char *n) { uint32_t h = 2166136261u; while (*n) { h ^= (uint8_t)*n++; h *= 16777619u; } return (uint8_t)h; }
/* AOSP bootloader_control at misc+0x800 (spd_dump common.h layout, 32 bytes):
 * suffix[4] magic[4] version nb_slot:3.. [3 bytes] slot_info[4] (2 bytes each). */
static int misc_slot_byte(uint64_t o, uint8_t *b)
{
	const char *s = getenv("MOCK_SLOT"); int bsl;
	if (!s || (strcmp(s, "a") && strcmp(s, "b")) || o < 0x800 || o >= 0x820) return 0;
	bsl = s[0] == 'b'; o -= 0x800;
	switch (o) {
	case 0: *b = '_'; return 1;
	case 1: *b = (uint8_t)s[0]; return 1;
	case 4: *b = 0x42; return 1; case 5: *b = 0x43; return 1; case 6: *b = 0x42; return 1; case 7: *b = 0x00; return 1; /* 0x00424342 */
	case 8: *b = 1; return 1;
	case 9: *b = 2; return 1;               /* nb_slot = 2 */
	case 12: *b = bsl ? 0x3e : 0xff; return 1; /* slot a: prio 14|tries 3 or prio 15|tries 7|ok */
	case 14: *b = bsl ? 0xff : 0x3e; return 1; /* slot b */
	default: *b = 0; return 1;
	}
}
static uint8_t part_byte(const char *name, uint64_t o)
{
	uint8_t b;
	if (!strcmp(name, "misc") && misc_slot_byte(o, &b)) return b;
	return pattern_byte(o) ^ name_seed(name);
}
