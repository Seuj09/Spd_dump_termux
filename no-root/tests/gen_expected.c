/* gen_expected NAME OFF SIZE : bytes the mock returns for NAME[OFF, OFF+SIZE). */
#include <stdio.h>
#include "mock_pattern.h"
int main(int c, char **v)
{
	uint64_t off, n, i;
	if (c != 4) return 2;
	off = strtoull(v[2], 0, 0); n = strtoull(v[3], 0, 0);
	for (i = 0; i < n; i++) putchar(part_byte(v[1], off + i));
	return 0;
}
