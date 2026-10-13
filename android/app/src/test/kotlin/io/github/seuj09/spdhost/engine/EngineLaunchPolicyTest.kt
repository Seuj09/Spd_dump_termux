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

    @Test fun refusalStillGoesForegroundOn26Plus() {
        assertNull(EngineLaunchPolicy.refusalForegroundType(24))
        assertNull(EngineLaunchPolicy.refusalForegroundType(25))
        for (sdk in 26..33) assertEquals(0, EngineLaunchPolicy.refusalForegroundType(sdk))
        for (sdk in 34..36) assertEquals(EngineLaunchPolicy.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE, EngineLaunchPolicy.refusalForegroundType(sdk))
        assertEquals(2048, EngineLaunchPolicy.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
    }

    @Test fun everyRefusalInOnStartCommandGoesThroughRefuseForeground() {
        val src = File("src/main/kotlin/io/github/seuj09/spdhost/engine/EngineService.kt").readText()
        val body = src.substringAfter("override fun onStartCommand").substringBefore("// STOP / null / unknown")
        assertFalse("bare stopSelf() in the START branch", body.contains("stopSelf()"))
        assertEquals(2, Regex("""refuseForeground\(\)""").findAll(body).count())
        val rf = src.substringAfter("private fun refuseForeground()").substringBefore("private fun createChannel")
        assertTrue(rf.contains("refusalForegroundType(Build.VERSION.SDK_INT)"))
        assertTrue(rf.contains("ServiceCompat.startForeground(this, NOTIFICATION_ID, n, type)"))
        assertTrue(rf.indexOf("startForeground") < rf.indexOf("finish()"))
        assertFalse(rf.contains("CONNECTED_DEVICE"))
        assertTrue(src.contains("#36 S2"))
    }

    companion object { val DEV = DeviceInfo("/dev/bus/usb/001/004", 0x1782, 0x4d00) }
}
