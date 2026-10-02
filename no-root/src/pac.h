#ifndef SPD_PAC_H
#define SPD_PAC_H

/* Spreadtrum PAC (firmware bundle) reader.
 *
 * Native implementation of the release's `unpac` CLI, so it runs on the phone
 * where the shipped x86-64 binary cannot. The format was read off the vendor
 * binary directly: header 2124 bytes, entries 2580 bytes each from 2124,
 * UTF-16LE fixed-width strings, and payload offsets absolute from the start of
 * the PAC (the entry table is followed by an embedded XML blob, so the payloads
 * are NOT at 2124 + N*2580).
 *
 * `argv[0]` is the subcommand name ("unpac"). Returns 0 on success, 1 on
 * every failure (bad usage, a header guard, a refused output name). */
int spd_pac_main(int argc, char **argv);

/* In-memory checks of the CRC-16/ARC implementation (whose result decides
 * whether a PAC is reported as intact) and of the wildcard matcher. Returns 0
 * on success, 1 with a message on stderr at the first mismatch. */
int spd_pac_selftest(void);

#endif /* SPD_PAC_H */
