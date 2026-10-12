package io.github.seuj09.spdhost.engine

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.ParcelFileDescriptor
import java.io.Closeable
import java.io.File
import java.io.FileDescriptor
import java.io.IOException

/**
 * The app side of `--usb-fd-sock PATH` (README "USB fd socket", plan §7).
 *
 * Bound on a FILESYSTEM path in an app-private dir, never the abstract
 * namespace: `LocalServerSocket(String)` would create an abstract name that
 * `--usb-fd-sock` cannot connect to, and any app can reach an abstract name.
 * So: a LocalSocket bound with Namespace.FILESYSTEM, wrapped in
 * LocalServerSocket(FileDescriptor) (which listens on it). The path is
 * unlinked in [close], after the session.
 *
 * Protocol: core connects, sends "HELLO 1\n"; we answer one byte 'F' with the
 * usbfs fd attached (SCM_RIGHTS via setFileDescriptorsForSend). A later
 * "REACQ ..." line gets 'N' with no fd (P1: REACQ=0). The peer must be our
 * uid; the core checks ours the same way (SO_PEERCRED).
 */
class FdSocketServer(
    val path: File,
    private val myUid: Int,
    /** The child's pid when known; then the peer pid must match it too. */
    private val expectedPid: () -> Int? = { null },
    private val log: (String) -> Unit,
) : Closeable {
    private val bound = LocalSocket(LocalSocket.SOCKET_STREAM)
    private val server: LocalServerSocket
    @Volatile private var closed = false
    @Volatile private var peer: LocalSocket? = null

    init {
        EngineArgv.checkSockPath(path.path)
        path.delete() // a stale socket from a killed session
        bound.bind(LocalSocketAddress(path.path, LocalSocketAddress.Namespace.FILESYSTEM))
        server = LocalServerSocket(bound.fileDescriptor)
    }

    /**
     * Blocks: accept one connection, hand over a dup of [usbFd], then answer
     * REACQ with 'N' until the core closes. Returns when the peer is gone or
     * [close] was called. The caller's UsbDeviceConnection stays open for the
     * whole call (and longer: until the child exits).
     */
    fun serve(usbFd: Int) {
        val s = try { server.accept() } catch (e: IOException) { if (!closed) log("socket accept: ${e.message}"); return }
        if (closed) { runCatching { s.close() }; return }
        peer = s
        try {
            val uid = runCatching { s.peerCredentials.uid }.getOrNull()
            if (uid != myUid) { log("socket: refused peer uid $uid (want $myUid)"); return }
            val want = expectedPid()
            val got = runCatching { s.peerCredentials.pid }.getOrNull()
            if (!peerPidOk(want, got)) { log("socket: refused peer pid $got (want $want)"); return }
            s.soTimeout = 10_000
            val input = s.inputStream
            val hello = readLine(input) ?: run { log("socket: core closed before HELLO"); return }
            if (hello != "HELLO 1") { log("socket: unexpected '$hello'; refused"); return }
            // Send a dup so our own fd (owned by the UsbDeviceConnection) is
            // never touched by the socket layer.
            val dup = ParcelFileDescriptor.fromFd(usbFd)
            try {
                s.setFileDescriptorsForSend(arrayOf<FileDescriptor>(dup.fileDescriptor))
                s.outputStream.write('F'.code)
                s.outputStream.flush()
            } finally {
                s.setFileDescriptorsForSend(null)
                dup.close()
            }
            log("socket: usb fd handed to the core")
            s.soTimeout = 0
            while (!closed) {
                val line = readLine(input) ?: break
                if (line.startsWith("REACQ")) {
                    log("socket: core asked '$line'; answered N (reacquire is off in P1)")
                    s.outputStream.write('N'.code)
                    s.outputStream.flush()
                } else log("socket: ignored '$line'")
            }
        } catch (e: IOException) {
            if (!closed) log("socket: ${e.message}")
        } finally {
            runCatching { s.close() }
            peer = null
        }
    }

    private fun readLine(input: java.io.InputStream): String? {
        val sb = StringBuilder()
        while (sb.length < 256) {
            val b = input.read()
            if (b < 0) return null
            if (b == '\n'.code) return sb.toString()
            sb.append(b.toChar())
        }
        return sb.toString()
    }

    /** Unblocks [serve] and unlinks the path. Idempotent. */
    override fun close() {
        if (closed) return
        closed = true
        runCatching { peer?.shutdownInput() }
        runCatching { peer?.close() }
        // accept() does not return on close() on every release: poke it.
        runCatching { LocalSocket().use { it.connect(LocalSocketAddress(path.path, LocalSocketAddress.Namespace.FILESYSTEM)) } }
        runCatching { server.close() }
        runCatching { bound.close() }
        path.delete()
    }

    companion object {
        /** Unknown child pid: uid check only. Known: the peer must be it. */
        fun peerPidOk(expected: Int?, peer: Int?): Boolean = expected == null || expected == peer
    }
}
