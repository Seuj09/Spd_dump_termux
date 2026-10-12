package io.github.seuj09.spdhost.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class EngineArgvTest {
    private val sock = "/data/user/0/io.github.seuj09.spdhost.debug/no_backup/run/s1a2b3c"
    private val ev = "/data/user/0/io.github.seuj09.spdhost.debug/no_backup/run/e1a2b3c.jsonl"

    @Test fun pingArgvMatchesTheMenuShape() {
        // menu.sh: spdhost-usb ... ping; the app swaps the fd source for the socket.
        assertEquals(
            listOf("/lib/libspdhost.so", "--usb-fd-sock", sock, "--events", ev, "ping"),
            EngineArgv.session("/lib/libspdhost.so", sock, ev, listOf("ping")),
        )
    }

    @Test fun onlyReadOnlyCommands() {
        for (bad in listOf("--yes", "write-part", "erase-part", "reboot-recovery", "set-active", "ops", "--dangerous", "--confirm-plan"))
            assertThrows(EngineArgv.Refused::class.java) { EngineArgv.session("/c", sock, ev, listOf("ping", bad)) }
        assertThrows(EngineArgv.Refused::class.java) { EngineArgv.session("/c", sock, ev, emptyList()) }
    }

    @Test fun socketPathIsFilesystemAndShort() {
        assertThrows(EngineArgv.Refused::class.java) { EngineArgv.checkSockPath("relative/s") }
        assertThrows(EngineArgv.Refused::class.java) { EngineArgv.checkSockPath("@abstract") }
        EngineArgv.checkSockPath("/" + "a".repeat(106)) // 107 bytes: ok
        assertThrows(EngineArgv.Refused::class.java) { EngineArgv.checkSockPath("/" + "a".repeat(107)) }
        EngineArgv.checkSockPath(sock)
    }
}
