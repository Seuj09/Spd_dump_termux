package io.github.seuj09.spdhost.engine

import io.github.seuj09.spdhost.usb.DeviceInfo
import io.github.seuj09.spdhost.usb.UsbState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** #36 D1: no startForeground(connectedDevice) without an open device. */
class EngineLaunchPolicyTest {
    private val dev = DEV

    @Test fun onlyOpenedMayStart() {
        assertNull(EngineLaunchPolicy.startRefusal(UsbState.Opened(dev, 7)))
        for (s in listOf(UsbState.NoDevice, UsbState.Found(dev), UsbState.PermissionRequested(dev),
            UsbState.Granted(dev), UsbState.Denied(dev), UsbState.Detached(dev), UsbState.OpenFailed(dev, "x")))
            assertNotNull("$s", EngineLaunchPolicy.startRefusal(s))
    }

    @Test fun onlyStartGoesForeground() {
        assertTrue(EngineLaunchPolicy.goesForeground(EngineService.ACTION_START))
        assertFalse(EngineLaunchPolicy.goesForeground(EngineService.ACTION_STOP))
        assertFalse(EngineLaunchPolicy.goesForeground(null))
        assertFalse(EngineLaunchPolicy.goesForeground("other"))
    }

    @Test fun peerPid() {
        assertTrue(FdSocketServer.peerPidOk(null, 42))
        assertTrue(FdSocketServer.peerPidOk(42, 42))
        assertFalse(FdSocketServer.peerPidOk(42, 43))
        assertFalse(FdSocketServer.peerPidOk(42, null))
    }

    @Test fun startForegroundIsGuarded() {
        val src = File("src/main/kotlin/io/github/seuj09/spdhost/engine/EngineService.kt").readText()
        assertTrue(src.contains("catch (e: SecurityException)"))
        // goForeground() is called only from the START branch, after startRefusal.
        val calls = Regex("""goForeground\(\)""").findAll(src).count()
        assertEquals(2, calls) // definition + one call
        assertTrue(src.indexOf("startRefusal(") < src.indexOf("goForeground()"))
        assertFalse(src.contains("setAction(ACTION_STOP)"))
    }

    companion object { val DEV = DeviceInfo("/dev/bus/usb/001/004", 0x1782, 0x4d00) }
}
