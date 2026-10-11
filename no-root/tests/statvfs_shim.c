/* ops-dump.sh: statvfs() with a chosen free-byte count, so the free-space
 * preflight can be tested without filling a disk. Linked with
 * -Wl,--wrap=statvfs,--wrap=statvfs64. MOCK_FREE_BYTES=N reports N bytes available;
 * MOCK_FREE_BYTES=fail makes the call fail (EIO); unset = the real answer. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statvfs.h>
/* glibc links the _FILE_OFFSET_BITS=64 call as statvfs64 on some targets and
 * as statvfs on others; both are wrapped (-Wl,--wrap=statvfs,--wrap=statvfs64). */
int __real_statvfs(const char *path, struct statvfs *buf);
int __real_statvfs64(const char *path, struct statvfs64 *buf);
int __wrap_statvfs64(const char *path, struct statvfs64 *buf)
{
	const char *e = getenv("MOCK_FREE_BYTES");
	int rc = __real_statvfs64(path, buf);
	if (rc || !e)
		return rc;
	if (!strcmp(e, "fail")) {
		errno = EIO;
		return -1;
	}
	buf->f_bsize = buf->f_frsize = 1;
	buf->f_bavail = (fsblkcnt64_t)strtoull(e, NULL, 10);
	return 0;
}
int __wrap_statvfs(const char *path, struct statvfs *buf)
{
	const char *e = getenv("MOCK_FREE_BYTES");
	int rc = __real_statvfs(path, buf);
	if (rc || !e)
		return rc;
	if (!strcmp(e, "fail")) {
		errno = EIO;
		return -1;
	}
	buf->f_bsize = buf->f_frsize = 1;
	buf->f_bavail = (fsblkcnt_t)strtoull(e, NULL, 10);
	return 0;
}
