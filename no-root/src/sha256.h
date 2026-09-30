#ifndef SPDHOST_SHA256_H
#define SPDHOST_SHA256_H
#include <stddef.h>
#include <stdint.h>
/* Lowercase hex SHA-256 of DATA into OUT (64 chars + NUL). */
void sha256_hex(const uint8_t *data, size_t len, char out[65]);
#endif
