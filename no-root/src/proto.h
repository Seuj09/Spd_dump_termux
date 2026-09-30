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
	int last_type;      /* last spd_encode() type; used by dry-run recv */
	int dry;            /* dry-run: no USB; log the packet sequence */
	uint32_t exec_addr; /* nonzero: BootROM exec_addr path (no END/EXEC) */
	const char *exec_file; /* stub sent at exec_addr (custom_exec_no_verify) */
	int dry_drop_ack;   /* dry-run: next recv reports a timeout (test hook) */
	/* Live partition table from the last `parts` in this session, in bytes
	 * (spd_dump partition_list(): units << (20 - divisor)). */
	struct spd_part { char name[37]; uint64_t size; } *ptab;
	int nparts;
	int ptab_shift;
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
/* exec_addr path: send FILE at addr via START/MIDST, NO END_DATA, NO EXEC_DATA.
 * Mirrors spd_dump.c's non-v2 exec_addr branch; tolerates a missing ack on the
 * final MIDST because the no-verify stub may seize execution before acking. */
int spd_send_exec_file(struct spd *io, const char *path, uint32_t addr);
int spd_exec(struct spd *io, int timeout_ms, int allow_incompatible);

int spd_read_part(struct spd *io, const char *name, uint64_t offset, uint64_t size, const char *out_path);
int spd_write_part(struct spd *io, const char *name, const char *path);
int spd_write_part_buf(struct spd *io, const char *name, const uint8_t *buf, size_t len);
int spd_erase_part(struct spd *io, const char *name);
int spd_list_parts(struct spd *io, const char *out_path);
/* Read [offset, offset+size) of NAME into MEM (exactly size bytes or error). */
int spd_read_part_mem(struct spd *io, const char *name, uint64_t offset, uint64_t size, uint8_t *mem);
int spd_chip_uid(struct spd *io);
int spd_simple(struct spd *io, unsigned type);

#endif
