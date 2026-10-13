package io.github.seuj09.spdhost.e8

import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import io.github.seuj09.spdhost.SpdhostApp
import io.github.seuj09.spdhost.engine.EngineChild
import io.github.seuj09.spdhost.engine.EngineEvent
import io.github.seuj09.spdhost.engine.EngineLauncher
import io.github.seuj09.spdhost.engine.EngineService
import io.github.seuj09.spdhost.usb.DeviceInfo
import io.github.seuj09.spdhost.usb.UsbIds
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * E8 with a fake core child (#40 soft note 2): EngineService.launcher is
 * swapped for one whose child is a recorder, so the real service path runs
 * with no native core: START with an open device goes foreground with the
 * session notification and pins the USB fd; the child's exit releases the
 * pin, clears the session and stops the service; STOP reaches the child.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 34], application = E8App::class)
class FakeChildE8Test {
    private val app get() = ApplicationProvider.getApplicationContext<SpdhostApp>()

    private class FakeChild(val fd: Int, val commands: List<String>, val onExit: (Int?) -> Unit) : EngineChild {
        @Volatile var started = false
        @Volatile var stops = 0
        override fun start() { started = true }
        override fun stop() { stops++ }
    }

    private class FakeLauncher(val refusal: String? = null) : EngineLauncher {
        @Volatile var child: FakeChild? = null
        override fun gateRefusal(ctx: Context) = refusal
        override fun create(
            ctx: Context, usbFd: Int, commands: List<String>,
            onLog: (String) -> Unit, onEvent: (EngineEvent) -> Unit, onExit: (Int?) -> Unit,
        ): EngineChild = FakeChild(usbFd, commands, onExit).also { child = it }
    }

    private lateinit var fake: FakeLauncher

    @Before fun inject() { fake = FakeLauncher(); EngineService.launcher = fake }
    @After fun restore() { EngineService.launcher = EngineLauncher.Default }

    /** The service works on a thread that posts to main: idle main until [cond]. */
    private fun until(what: String, cond: () -> Boolean) {
        val t0 = System.currentTimeMillis()
        while (!cond()) {
            shadowOf(Looper.getMainLooper()).idle()
            if (System.currentTimeMillis() - t0 > 5_000) throw AssertionError("timed out waiting for $what")
            Thread.sleep(10)
        }
    }

    private val cmds = arrayListOf("--timeout", "3000", "ping")
    private fun startIntent() = Intent().setAction(EngineService.ACTION_START)
        .putStringArrayListExtra(EngineService.EXTRA_COMMANDS, cmds)
    private fun open(fd: Int = 42) =
        app.broker.openForTest(DeviceInfo("/dev/bus/usb/001/004", UsbIds.VENDOR_SPRD, UsbIds.PRODUCT_BROM), fd)

    @Test fun startGoesForegroundPinsUsbAndChildExitReleasesIt() {
        open(42)
        val svc = Robolectric.buildService(EngineService::class.java, startIntent()).create().startCommand(0, 1).get()
        // START with an open device: the session notification, synchronously in onStartCommand.
        val n = shadowOf(svc).lastForegroundNotification
        assertNotNull("START did not go foreground", n)
        assertEquals("spdhost session", n!!.extras.getCharSequence("android.title")?.toString())
        until("child started") { fake.child?.started == true }
        val child = fake.child!!
        assertEquals(42, child.fd)
        assertEquals(cmds, child.commands)
        assertTrue(app.broker.engineHeld)
        assertTrue(app.engine.state.value.running)
        assertFalse(shadowOf(svc).isStoppedBySelf)

        // The child exits on its own wait thread, as EngineSession's core-wait does.
        Thread { child.onExit(0) }.apply { isDaemon = true; start() }
        until("USB released") { !app.broker.engineHeld && app.engine.session == null }
        assertEquals(0, app.engine.state.value.lastRc)
        assertFalse(app.engine.state.value.running)
        assertTrue(app.broker.log.value.any { it.contains("connection unpinned") })
        until("service stopped") { shadowOf(svc).isStoppedBySelf }
        // A new session can pin the same connection again.
        assertEquals(42, app.broker.holdForEngine()); app.broker.releaseFromEngine()
    }

    @Test fun stopReachesTheChildAndExitAfterStopStillReleases() {
        open(7)
        Robolectric.buildService(EngineService::class.java, startIntent()).create().startCommand(0, 1).get()
        until("child started") { fake.child?.started == true }
        EngineService.stop(app)
        assertEquals(1, fake.child!!.stops)
        assertTrue(app.engine.state.value.stopping)
        assertTrue("stop must not unpin before the child exits", app.broker.engineHeld)
        Thread { fake.child!!.onExit(130) }.apply { isDaemon = true; start() }
        until("USB released") { !app.broker.engineHeld }
        assertEquals(130, app.engine.state.value.lastRc)
        assertFalse(app.engine.state.value.stopping)
    }

    @Test fun gateRefusalNeverPinsUsbOrSpawns() {
        fake = FakeLauncher(refusal = "core lacks cap events"); EngineService.launcher = fake
        open(9)
        val svc = Robolectric.buildService(EngineService::class.java, startIntent()).create().startCommand(0, 1).get()
        until("refused") { app.engine.state.value.refusal != null }
        assertEquals("core lacks cap events", app.engine.state.value.refusal)
        assertNull(fake.child)
        assertFalse(app.broker.engineHeld)
        until("service stopped") { shadowOf(svc).isStoppedBySelf }
    }
}
