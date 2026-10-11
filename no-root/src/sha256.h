#ifndef SPDHOST_SHA256_H
#define SPDHOST_SHA256_H
#include <stddef.h>
#include <stdint.h>
/* Lowercase hex SHA-256 of DATA into OUT (64 chars + NUL). */
void sha256_hex(const uint8_t *data, size_t len, char out[65]);
/* Streaming form (P0-4: whole images of any size, and the running hash a
 * confirm-plan write keeps over the bytes it actually sends). */
struct sha256_ctx {
	uint32_t h[8];
	uint8_t buf[64];
	size_t nbuf;
	uint64_t len;
};
void sha256_init(struct sha256_ctx *c);
void sha256_update(struct sha256_ctx *c, const void *data, size_t len);
void sha256_final_hex(struct sha256_ctx *c, char out[65]);
#endif
