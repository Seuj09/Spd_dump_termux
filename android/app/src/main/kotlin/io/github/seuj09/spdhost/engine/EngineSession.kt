package io.github.seuj09.spdhost.engine

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.RandomAccessFile

/**
 * One run of the core with the USB fd (plan P1-3): ProcessBuilder exec of
 * nativeLibraryDir/libspdhost.so (never filesDir), sanitized env, the fd over
 * [FdSocketServer], events tailed from an app-private file. [stop] sends
 * SIGINT (the core stops at its next checkpoint, like Ctrl-C in Termux); only
 * if it is still running [KILL_AFTER_MS] later is the process destroyed.
 *
 * Callbacks run on worker threads.
 */
class EngineSession(
    private val core: File,
    private val runDir: File,
    private val myUid: Int,
    private val usbFd: Int,
    private val commands: List<String>,
    private val onLog: (String) -> Unit,
    private val onEvent: (EngineEvent) -> Unit,
    private val onExit: (Int?) -> Unit,
) {
    @Volatile private var process: Process? = null
    @Volatile private var pid: Int? = null
    @Volatile private var finished = false
    @Volatile var stopRequested = false
        private set

    fun start() {
        val n = Integer.toHexString((System.nanoTime() and 0xffffff).toInt())
        runDir.mkdirs()
        val sock = File(runDir, "s$n")
        val events = File(runDir, "e$n.jsonl")
        events.delete()
        val argv = EngineArgv.session(core.path, sock.path, events.path, commands)
        val server = FdSocketServer(sock, myUid, onLog)
        val p = try {
            val pb = ProcessBuilder(argv).directory(runDir)
            CoreEnv.sanitize(pb.environment())
            pb.start()
        } catch (e: Exception) {
            server.close()
            onLog("exec failed: ${e.message}")
            onExit(null)
            return
        }
        process = p
        pid = pidOf(p)
        p.outputStream.close()
        onLog("started: ${argv.drop(1).joinToString(" ")} (pid ${pid ?: "?"})")
        val socketThread = thread("core-sock") { server.serve(usbFd) }
        val readers = listOf(p.inputStream to "out", p.errorStream to "err").map { (st, tag) ->
            thread("core-$tag") { runCatching { st.bufferedReader().forEachLine { onLog("$tag: $it") } } }
        }
        val tail = thread("core-events") { tailEvents(events) }
        thread("core-wait") {
            val rc = runCatching { p.waitFor() }.getOrNull()
            finished = true
            readers.forEach { it.join(2_000) }
            tail.join(2_000)
            server.close() // unlinks the socket path
            socketThread.join(2_000)
            events.delete()
            onLog("core exited rc=${rc ?: "?"}")
            onExit(rc)
        }
    }

    /** SIGINT, then destroy if it does not end. */
    fun stop() {
        val p = process ?: return
        if (finished || stopRequested) return
        stopRequested = true
        val id = pid
        if (id != null) {
            onLog("stop: SIGINT to pid $id")
            runCatching { Os.kill(id, OsConstants.SIGINT) }.onFailure { onLog("SIGINT failed: ${it.message}") }
        }
        thread("core-kill") {
            val t0 = System.currentTimeMillis()
            while (!finished && System.currentTimeMillis() - t0 < KILL_AFTER_MS) Thread.sleep(100)
            if (!finished) { onLog("stop: still running after ${KILL_AFTER_MS} ms; destroying"); p.destroy() }
        }
    }

    private fun tailEvents(f: File) {
        var pos = 0L
        val buf = StringBuilder()
        var lastRound = false
        while (true) {
            if (finished) lastRound = true
            if (f.isFile) runCatching {
                RandomAccessFile(f, "r").use { raf ->
                    if (raf.length() > pos) {
                        raf.seek(pos)
                        val bytes = ByteArray((raf.length() - pos).toInt())
                        raf.readFully(bytes)
                        pos += bytes.size
                        buf.append(String(bytes, Charsets.UTF_8))
                        while (true) {
                            val nl = buf.indexOf("\n")
                            if (nl < 0) break
                            val line = buf.substring(0, nl)
                            buf.delete(0, nl + 1)
                            EngineEvent.parse(line)?.let { ev ->
                                if (ev.ev == "start" && pid == null) pid = ev["pid"]?.toIntOrNull()
                                onEvent(ev)
                            }
                        }
                    }
                }
            }
            if (lastRound) return
            Thread.sleep(100)
        }
    }

    companion object {
        const val KILL_AFTER_MS = 15_000L

        /** Process.pid() is Java 9+; Android's Process prints "Process[pid=N, ...]". */
        fun pidOf(p: Process): Int? = Regex("pid=(\\d+)").find(p.toString())?.groupValues?.get(1)?.toIntOrNull()

        private fun thread(name: String, body: () -> Unit) =
            Thread(body).apply { this.name = name; isDaemon = true; start() }
    }
}
