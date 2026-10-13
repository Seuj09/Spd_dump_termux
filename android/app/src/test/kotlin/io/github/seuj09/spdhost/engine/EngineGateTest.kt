package io.github.seuj09.spdhost.engine

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class EngineGateTest {
    private val sha = "0123456789abcdef0123456789abcdef01234567"
    private fun caps(sha: String? = this.sha, protocol: Int? = 1, vararg c: String = arrayOf("usb-fd-sock", "events")) =
        Caps(sha, protocol, c.toSet())

    @Test fun allowsMatchingCore() = assertNull(EngineGate.refusal(caps(), sha))
    @Test fun refusesNoCaps() = assertNotNull(EngineGate.refusal(null, sha))
    @Test fun refusesOtherProtocol() = assertNotNull(EngineGate.refusal(caps(protocol = 2), sha))
    @Test fun refusesMissingSockCap() = assertNotNull(EngineGate.refusal(caps(c = arrayOf("events")), sha))
    @Test fun refusesMissingEventsCap() = assertNotNull(EngineGate.refusal(caps(c = arrayOf("usb-fd-sock")), sha))
    @Test fun refusesOtherCommit() = assertNotNull(EngineGate.refusal(caps(sha = "f".repeat(40)), sha))
    @Test fun refusesUnknownCommit() {
        assertNotNull(EngineGate.refusal(caps(sha = null), sha))
        assertNotNull(EngineGate.refusal(caps(), "unknown"))
    }
}
