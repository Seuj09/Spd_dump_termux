package io.github.seuj09.spdhost.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CapsTest {
    private val sha = "992c32581433616a665e02823d6b1ed9cf1201b5"

    // Verbatim shape of no-root/src/main.c print_caps at P0-2.
    private val real = """
        caps_format=1
        build_sha=$sha
        protocol=1
        cap=confirm-token
        cap=dry-run
        cap=frp-part
        cap=image-tools
        cap=misc-bytes
        cap=pack-slot
        cap=parts-header
        cap=status-file
        cap=unpac
        cap=usb-fd
        end
    """.trimIndent() + "\n"

    @Test fun parsesRealOutput() {
        val c = Caps.parse(real)!!
        assertEquals(sha, c.buildSha)
        assertEquals(1, c.protocol)
        assertEquals(10, c.caps.size)
        assertTrue(c.has("usb-fd"))
        assertTrue(c.has("dry-run"))
        assertFalse(c.has("events"))
    }

    @Test fun unknownKeysAndCapsAreIgnored() {
        val c = Caps.parse("caps_format=1\nbuild_sha=$sha\nbuild_dirty=1\nprotocol=2\nfuture_key=x=y\ncap=events\ncap=usb-fd-sock\nnot a key\nend\n")!!
        assertEquals(2, c.protocol)
        assertEquals(setOf("events", "usb-fd-sock"), c.caps)
    }

    @Test fun truncatedOutputIsNoCaps() {
        assertNull(Caps.parse(real.substringBefore("end")))
        assertNull(Caps.parse(real.lines().take(5).joinToString("\n")))
        assertNull(Caps.parse(""))
        assertNull(Caps.parse("caps_format=1\n"))
    }

    @Test fun wrongFirstLineIsNoCaps() {
        assertNull(Caps.parse("caps_format=2\nprotocol=1\nend\n"))
        assertNull(Caps.parse("\ncaps_format=1\nend\n"))
        // An old core answers a usage text, not caps.
        assertNull(Caps.parse("usage: spdhost [options] <command>\nend\n"))
    }

    @Test fun endMustBeTheLastLine() {
        assertNull(Caps.parse("caps_format=1\nend\ncap=x\n"))
        assertNull(Caps.parse("caps_format=1\ncap=x\nend\nend\n"))
        assertNull(Caps.parse("caps_format=1\ncap=x\nend \n"))
        // Trailing newlines do not count (menu.sh reads it through $(...)).
        assertEquals(setOf("x"), Caps.parse("caps_format=1\ncap=x\nend\n\n")!!.caps)
    }

    @Test fun minimalAndCrlf() {
        val c = Caps.parse("caps_format=1\nend")!!
        assertNull(c.buildSha)
        assertNull(c.protocol)
        assertTrue(c.caps.isEmpty())
        assertEquals(setOf("dry-run"), Caps.parse("caps_format=1\r\ncap=dry-run\r\nend\r\n")!!.caps)
    }

    @Test fun badShaOrProtocolBecomeNull() {
        val c = Caps.parse("caps_format=1\nbuild_sha=unknown\nprotocol=one\nend\n")!!
        assertNull(c.buildSha)
        assertNull(c.protocol)
        assertNull(Caps.parse("caps_format=1\nbuild_sha=${sha.uppercase()}\nend\n")!!.buildSha)
    }
}
