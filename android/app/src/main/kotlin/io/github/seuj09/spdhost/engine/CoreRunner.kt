package io.github.seuj09.spdhost.engine

import android.content.Context
import java.io.File
import java.security.MessageDigest

/** Outcome of `libspdhost.so caps` on this phone. */
data class CoreProbe(
    val path: String,
    val present: Boolean,
    val sizeBytes: Long = 0,
    val sha256: String? = null,
    val exitCode: Int? = null,
    val output: String = "",
    val error: String? = null,
    val caps: Caps? = null,
    val elapsedMs: Long = 0,
)

/**
 * Runs the native core. For now only `caps`, which is offline (no USB, no
 * device, no files), to prove the static binary executes from
 * nativeLibraryDir on this phone. The USB fd hand-off (path socket, P0-5) and
 * every device command arrive with P0-5/P1-3; nothing here talks to a phone.
 */
object CoreRunner {
    const val LIB_NAME = "libspdhost.so"
    private const val TIMEOUT_MS = 5_000L

    fun corePath(context: Context): File = File(context.applicationInfo.nativeLibraryDir, LIB_NAME)

    /** Blocking; call off the main thread. */
    fun probeCaps(context: Context): CoreProbe {
        val bin = corePath(context)
        if (!bin.isFile) return CoreProbe(bin.path, present = false, error = "not packaged in this APK for this ABI")
        val sha = runCatching { sha256(bin) }.getOrNull()
        val t0 = System.nanoTime()
        return try {
            val pb = ProcessBuilder(bin.path, "caps").redirectErrorStream(false)
            CoreEnv.sanitize(pb.environment())
            val p = pb.start()
            p.outputStream.close()
            val out = StringBuffer()
            val err = StringBuffer()
            val readers = listOf(p.inputStream to out, p.errorStream to err).map { (stream, sink) ->
                Thread { runCatching { stream.bufferedReader().use { sink.append(it.readText()) } } }
                    .apply { isDaemon = true; start() }
            }
            // Process.waitFor(timeout, unit) is API 26+; minSdk is 24.
            var exit: Int? = null
            val waiter = Thread { exit = runCatching { p.waitFor() }.getOrNull() }
                .apply { isDaemon = true; start() }
            waiter.join(TIMEOUT_MS)
            val done = !waiter.isAlive
            if (!done) p.destroy()
            readers.forEach { it.join(1_000) }
            val ms = (System.nanoTime() - t0) / 1_000_000
            val code = if (done) exit else null
            val text = out.toString()
            CoreProbe(
                path = bin.path, present = true, sizeBytes = bin.length(), sha256 = sha,
                exitCode = code, output = text,
                error = when {
                    !done -> "timed out after ${TIMEOUT_MS} ms"
                    err.isNotBlank() -> err.toString().trim()
                    else -> null
                },
                // Non-zero exit = no caps, like menu.sh.
                caps = if (code == 0) Caps.parse(text) else null,
                elapsedMs = ms,
            )
        } catch (e: Exception) {
            CoreProbe(bin.path, present = true, sizeBytes = bin.length(), sha256 = sha,
                error = "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { s ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = s.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
