package io.github.seuj09.spdhost.dump

import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/**
 * P1-6 export: copy one dump file to a SAF document opened with "rwt"
 * (truncate, so a re-export never leaves stale tail bytes), hashing while
 * copying and comparing with meta/SHA256SUMS. Pure JVM so it is unit-tested;
 * the SAF plumbing lives in ExportRepo.
 */
object Exporter {
    /** FAT32 cannot hold a file of 4 GiB or more (max 4 GiB - 1). */
    const val FAT32_MAX: Long = (1L shl 32) - 1

    sealed class Result {
        data class Ok(val bytes: Long, val sha256: String) : Result()
        data class Mismatch(val bytes: Long, val got: String, val want: String) : Result()
        data class SizeMismatch(val got: Long, val want: Long) : Result()
        data class NoSum(val name: String) : Result()
    }

    fun needsFat32Warning(bytes: Long) = bytes > FAT32_MAX

    fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    /**
     * Copies [input] to [output]. [want] null means the file has no SUMS line:
     * nothing is copied (refused). [wantBytes] is the source size, checked too.
     */
    fun copyVerified(name: String, input: InputStream, output: OutputStream, want: String?, wantBytes: Long): Result {
        if (want == null) return Result.NoSum(name)
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(1 shl 20)
        var n = 0L
        while (true) {
            val r = input.read(buf)
            if (r < 0) break
            md.update(buf, 0, r)
            output.write(buf, 0, r)
            n += r
        }
        output.flush()
        val got = hex(md.digest())
        return when {
            n != wantBytes -> Result.SizeMismatch(n, wantBytes)
            got != want.lowercase() -> Result.Mismatch(n, got, want.lowercase())
            else -> Result.Ok(n, got)
        }
    }
}
