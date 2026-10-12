package io.github.seuj09.spdhost.engine

import org.junit.Assert.assertEquals
import org.junit.Test

class CoreEnvTest {
    @Test fun stripsEveryCoreKnob() {
        val env = mutableMapOf(
            "PATH" to "/system/bin", "HOME" to "/data/user/0/x", "ANDROID_DATA" to "/data",
            "SPDHOST_BROM_REACQ" to "1", "SPDHOST_STATUS_FILE" to "/x", "SPD_DUMP_TRACE" to "1",
            "TERMUX_USB_FD" to "5", "XSPDHOST_KEEP" to "1",
        )
        CoreEnv.sanitize(env)
        assertEquals(setOf("PATH", "HOME", "ANDROID_DATA", "XSPDHOST_KEEP"), env.keys)
    }
}
