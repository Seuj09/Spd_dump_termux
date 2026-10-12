package io.github.seuj09.spdhost

import org.junit.Assert.assertEquals
import org.junit.Test

class ApiGatesTest {
    private fun row(sdk: Int) = listOf(
        ApiGates.needsNotificationPermission(sdk),
        ApiGates.needsChannel(sdk),
        ApiGates.useStartForegroundService(sdk),
        ApiGates.typeHonoured(sdk),
        ApiGates.needsConnectedDevicePermission(sdk),
        ApiGates.pendingIntentNeedsMutable(sdk),
    )

    @Test fun perApiTable() {
        assertEquals(listOf(false, false, false, false, false, false), row(24)) // Android 7.0 (minSdk)
        assertEquals(listOf(false, false, false, false, false, false), row(25))
        assertEquals(listOf(false, true, true, false, false, false), row(26))
        assertEquals(listOf(false, true, true, true, false, false), row(29))
        assertEquals(listOf(false, true, true, true, false, true), row(31))
        assertEquals(listOf(true, true, true, true, false, true), row(33))
        assertEquals(listOf(true, true, true, true, true, true), row(34))
        assertEquals(listOf(true, true, true, true, true, true), row(35)) // targetSdk
    }
}
