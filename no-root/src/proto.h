#ifndef SPDHOST_PROTO_H
#define SPDHOST_PROTO_H

#include <stddef.h>
#include <stdint.h>

#include "usb.h" /* also declares spd_interrupted, shared with the USB layer */

#define SPD_F_CRC16 1
#define SPD_F_TRANSCODE 2

/* spd_dump's Da_Info.dwStorageType. Three places set it: the fdl2 stage when the
 * loader answers BSL_CMD_READ_FLASH_INFO (spd_dump.c:742 -> NAND), partition_list()
 * when it reads the table (common.c:1007 emmc/ufs by the sector the GPT header was
 * found at, :1116 the same by the SPRD divisor), and check_partition() when a
 * 0xffffffff read is refused (common.c:1582 -> NAND). It decides whether w_force
 * may run at all and whether load_partition_unify() makes a _bak copy, so ours has
 * to keep it rather than treat the flash as opaque. */
#define SPD_STORAGE_NAND 0x101
#define SPD_STORAGE_EMMC 0x102
#define SPD_STORAGE_UFS  0x103

/* spd_dump get_partition_info: id 0 is splloader, 256 KiB, even on a device
 * whose table has no such row. The id spd_list_parts() prints is the id
 * spd_lookup_part() accepts, so both live in one place. */
#define SPLLOADER_BYTES (256u * 1024u)

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
	int exec_v2;        /* exec_addr2 / loadexec2: append the stub to the same
	                     * download instead of starting a second one */
	int dry_drop_ack;   /* dry-run: next recv reports a timeout (test hook) */
	/* Live partition table from the last `parts` in this session, in bytes
	 * (spd_dump partition_list(): units << (20 - divisor)). */
	struct spd_part { char name[37]; uint64_t size; } *ptab;
	int nparts;
	int ptab_shift;
	/* spd_dump's gpt_failed latch (spd_dump.c:144 `int gpt_failed = 1`, cleared
	 * by a successful partition_list at common.c:1143, set to -1 by a refusal at
	 * common.c:1088/1095). Every call site reads `if (gpt_failed == 1)` before
	 * asking the device, so the table is read ONCE per session and a later
	 * `parts` / `partition-list` re-prints the rows already in io->ptab rather
	 * than sending a second READ_PARTITION. 1 = not asked yet, 0 = asked and
	 * answered, -1 = the device refused one (the reference keeps -1 too, so it
	 * does not ask again either). */
	int ptab_state;
	/* spd_dump writes partition_<unixtime>.xml on every session that reads
	 * the table (spd_dump.c:191 + the partition_list call sites), so the file
	 * a repartition edit starts from is always there. When this names a
	 * folder, so does spdhost; the menu points it at the dump folder.
	 * NULL or "" turns the copy off. */
	const char *part_xml_dir;
	/* spd_dump reads the active slot once, at the FDL2 stage (select_ab), and
	 * keeps it in a global it updates only from set_active. Reading
	 * misc+0x800 again before every command that wants the slot costs three
	 * USB round trips each time -- the read_parts loop was doing it once per
	 * row -- and puts frames on the wire the reference never sends. Ours is
	 * kept here instead, and dropped by spd_slot_forget() whenever the answer
	 * can have changed: a misc write, a misc erase, a new table. */
	int slot;
	int slot_known;
	/* spd_dump's `selected_ab` as it stands between select_ab() and the table
	 * walk: -1 until the device has been asked, then what the misc
	 * bootloader_control said, 0/1/2. select_ab() is what puts the misc read
	 * on the wire at the FDL2 stage, so this is also the "already asked"
	 * latch that keeps a second table read in the same session from asking
	 * again (common.c:1072 `if (selected_ab < 0)`). */
	int slot_bcb;
	/* The 32 bytes that read returned, so `dump` can save misc-slotinfo.img
	 * without a second round trip. */
	uint8_t slot_abc[32];
	int slot_abc_valid;
	/* Da_Info.dwStorageType (SPD_STORAGE_*), or 0 while the session has not
	 * learned it. Set by the flash-info exchange in the fdl2 stage, by every
	 * table read, and by a refused 0xffffffff size probe. */
	int storage;
	/* The loader asked for HDLC off (Da_Info.bDisableHDLC). The reference acts
	 * on it right after the flash-info exchange (spd_dump.c:746), so the flag is
	 * carried there rather than acted on where it is parsed. */
	int hdlc_off_wanted;
};

/* Drop the cached active slot; the next spd_active_slot() reads misc again. */
void spd_slot_forget(struct spd *io);
/* set-active wrote the bytes itself, so it knows the answer without asking. */
void spd_slot_set(struct spd *io, int slot);
/* AOSP bootloader_control at misc+0x800 (spd_dump select_ab and ab_compare_slots):
 * 1 = slot a, 2 = slot b, 0 = not A/B. HAVE_UBOOT_A is the reference's own gate --
 * a device with no uboot_a partition is not really A/B whatever the block says. */
int spd_slot_from_bytes(const uint8_t *abc, int have_uboot_a);
/* spd_dump partition_list()'s table walk: when select_ab() came back 0, the
 * first row whose name ends in "_a" means slot A is the one in use. */
int spd_slot_from_table(const struct spd *io);

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
/* BSL_CMD_KEEP_CHARGE after the FDL1 CONNECT (spd_dump's `keep_charge`, on by
 * default). Non-fatal: some loaders do not know it. 0 = the loader took it. */
int spd_keep_charge(struct spd *io);

int spd_send_loader(struct spd *io, const char *path, uint32_t addr);
/* exec_addr path: send FILE at addr via START/MIDST, NO END_DATA, NO EXEC_DATA.
 * Mirrors spd_dump.c's non-v2 exec_addr branch; tolerates a missing ack on the
 * final MIDST because the no-verify stub may seize execution before acking. */
int spd_send_exec_file(struct spd *io, const char *path, uint32_t addr);
/* spd_dump's exec_addr2 / loadexec2 branch (spd_dump.c:607): the FDL1 download
 * is left open (no END_DATA), zero MIDST frames fill the gap from the end of
 * FDL1 up to STUB_ADDR, and the stub is appended to the very same stream. Used
 * by a BootROM that accepts only one download per session. Tolerates a missing
 * ack on the final chunk, as spd_send_exec_file does. */
int spd_send_loader_appended(struct spd *io, const char *path, uint32_t addr,
	const char *stub, uint32_t stub_addr);
int spd_exec(struct spd *io, int timeout_ms, int allow_incompatible);
/* spd_dump's fdl2-stage flash-info exchange: learns NAND from a
 * BSL_REP_READ_FLASH_INFO reply and turns HDLC off if the loader's Da_Info asked
 * for it. Non-fatal: -1 when the exchange could not be made at all. */
int spd_flash_info(struct spd *io);

int spd_read_part(struct spd *io, const char *name, uint64_t offset, uint64_t size, const char *out_path);
int spd_write_part(struct spd *io, const char *name, const char *path);
int spd_write_part_buf(struct spd *io, const char *name, const uint8_t *buf, size_t len);
/* fixnv1 image: same NV framing spd_dump load_nv_partition uses (not a raw copy). */
int spd_write_nv(struct spd *io, const char *name, const char *path);
/* 0 when PATH frames as an NV image. -1 when it is unreadable or broken.
 * Sends nothing. A restore skips a broken file; a single write-part still fails. */
int spd_nv_image_ok(const char *path);
/* Write the live table as the XML repartition FILE.xml accepts. */
int spd_part_xml(struct spd *io, const char *out_path);
/* Make sure io->ptab holds the device's table: reads it if this session has not
 * yet. spd_dump reads it once, in the FDL2 stage of `fdl` (spd_dump.c:755 ->
 * common.c partition_list), so every later command has it whether or not the
 * user asked; ours reads it at the same point in the run. 0 = there is a table,
 * -1 = the device refused one (not fatal -- the caller decides). */
int spd_parts_ensure(struct spd *io);
/* One <Partition id=".." size=".."/> record. Size is the XML integer as
 * written: MiB for every row but the last, which spd_dump writes as
 * 0xffffffff ("take the rest"). */
struct spd_xml_part {
	char name[36];
	uint32_t size;
};

/* Every record in FILE, in order, from the one <Partitions> list. *OUT is
 * malloc'd and free()d by the caller; the return value is the count, or -1
 * with a message on stderr. WHAT names the caller in those messages. Shared
 * by the XML repartition send and by read_parts, so the two cannot drift
 * apart on what the file means. */
int spd_xml_partitions(const char *path, const char *what, struct spd_xml_part **out);

/* <Partitions><Partition id=".." size=".."/> XML. Size is the XML integer (MiB, or ~0). */
int spd_repartition_xml(struct spd *io, const char *path);
/* Send the live table with row IDX renamed to NEWNAME (IDX < 0 = unchanged).
 * spd_dump's load_partition_force() pair for a force write. 0 = accepted. */
int spd_repartition_echo(struct spd *io, int idx, const char *newname);
int spd_erase_part(struct spd *io, const char *name);
int spd_list_parts(struct spd *io, const char *out_path);
/* Read [offset, offset+size) of NAME into MEM (exactly size bytes or error). */
int spd_read_part_mem(struct spd *io, const char *name, uint64_t offset, uint64_t size, uint8_t *mem);
/* spd_dump check_partition(): ask the DEVICE about NAME. Without NEED_SIZE the
 * answer is 1 (it read) or 0 (it did not); with it, the size in bytes, found by
 * reading 0xffffffff and halving down the loader's refusals. AB is the active
 * slot, >0 on A/B: it sends fixnv/runtimenv to the other copy and sizes an A/B
 * row from its `<name>_size` partition. Also sets io->storage (NAND, when the
 * loader refuses 0xffffffff outright). Unlike spd_check_part() this consults no
 * table, so it is what a 0xffffffff row in an XML list has to be sized with. */
uint64_t spd_check_partition(struct spd *io, const char *name, int need_size, int ab);
/* Raw flash / memory access (spd_dump read_flash, read_mem, erase_flash).
 * No partition table is consulted: ADDR is the address the loader is told to
 * read from or erase. All fields are 32-bit on the wire and a larger value is
 * refused before anything is sent. */
int spd_dump_flash(struct spd *io, uint64_t addr, uint64_t offset, uint64_t size, const char *out_path);
int spd_dump_mem(struct spd *io, uint64_t addr, uint64_t size, const char *out_path);
int spd_erase_flash(struct spd *io, uint64_t addr, uint64_t size);
int spd_chip_uid(struct spd *io);
int spd_simple(struct spd *io, unsigned type);

#endif
