#ifndef SPDHOST_PROTO_H
#define SPDHOST_PROTO_H

#include <stddef.h>
#include <stdint.h>

#include "usb.h" /* also declares spd_interrupted, shared with the USB layer */

#define SPD_F_CRC16 1
#define SPD_F_TRANSCODE 2

struct spd {
	struct spd_usb usb;
	int flags;
	int verbose;
	int step;
	int fdl_stage; /* 0 brom, 1 after first loader, 2 after second */
	int linked;    /* handshake for the current stage already done */
	uint8_t *raw;
	uint8_t *enc;
	uint8_t *recv;
	uint8_t *temp;
	int raw_len;
	int enc_len;
	int recv_len;
	int recv_pos;
};

struct spd *spd_new(int verbose, int step);
void spd_free(struct spd *io);

int spd_selftest(void);

/* Framing. check-baud is not a normal frame: len is the number of 0x7e bytes. */
void spd_encode(struct spd *io, unsigned type, const void *data, size_t len);
int spd_send(struct spd *io);
int spd_recv(struct spd *io, int timeout_ms);
unsigned spd_type(struct spd *io);
const uint8_t *spd_payload(struct spd *io, unsigned *len);

int spd_check_ok(struct spd *io);
int spd_check_baud(struct spd *io, int nbytes, int tries);
/* After BootROM line-state: settle + optional IN drain (SPDHOST_BROM_*). */
void spd_brom_after_line_state(struct spd *io);
/* After FDL1 starts: 0x7e once (phones), then four 0x7e (older loaders). */
int spd_check_baud_loader(struct spd *io);
int spd_connect(struct spd *io);

int spd_send_loader(struct spd *io, const char *path, uint32_t addr);
int spd_exec(struct spd *io, int timeout_ms, int allow_incompatible);

int spd_read_part(struct spd *io, const char *name, uint64_t offset, uint64_t size, const char *out_path);
int spd_write_part(struct spd *io, const char *name, const char *path);
int spd_write_part_buf(struct spd *io, const char *name, const uint8_t *buf, size_t len);
int spd_erase_part(struct spd *io, const char *name);
int spd_list_parts(struct spd *io, const char *out_path);
int spd_chip_uid(struct spd *io);
int spd_simple(struct spd *io, unsigned type);

#endif
