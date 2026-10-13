package io.github.seuj09.spdhost.e8

import android.content.Intent
import android.hardware.usb.UsbManager
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import io.github.seuj09.spdhost.MainActivity
import io.github.seuj09.spdhost.SpdhostApp
import io.github.seuj09.spdhost.engine.EngineService
import io.github.seuj09.spdhost.usb.UsbState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * E8 (plan §4.2), P1 part: service and Activity lifecycle with no phone and
 * no core (Robolectric has neither): attach intents, rotation, detach, and
 * STOP / null / refused START never going foreground for connectedDevice.
 * Runs on the minSdk (24) and on 34 (the FGS-type rules).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 34])
class LifecycleE8Test {
    private val app get() = ApplicationProvider.getApplicationContext<SpdhostApp>()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun stopWithoutSessionStopsAndNeverGoesForeground() {
        val svc = Robolectric.buildService(EngineService::class.java, Intent().setAction(EngineService.ACTION_STOP))
            .create().startCommand(0, 1).get()
        assertTrue(shadowOf(svc).isStoppedBySelf)
        assertNull(shadowOf(svc).lastForegroundNotification)
    }

    @Test fun nullIntentStopsAndNeverGoesForeground() {
        val svc = Robolectric.buildService(EngineService::class.java, null).create().startCommand(0, 1).get()
        assertTrue(shadowOf(svc).isStoppedBySelf)
        assertNull(shadowOf(svc).lastForegroundNotification)
    }

    @Test fun startWithoutAnOpenDeviceIsRefusedAndStops() {
        val i = Intent().setAction(EngineService.ACTION_START)
            .putStringArrayListExtra(EngineService.EXTRA_COMMANDS, arrayListOf("--timeout", "3000", "ping"))
        val svc = Robolectric.buildService(EngineService::class.java, i).create().startCommand(0, 1).get()
        idle()
        assertTrue(shadowOf(svc).isStoppedBySelf)
        assertTrue(app.engine.state.value.refusal.orEmpty().contains("not open"))
        assertNull(app.engine.session)
        // Only the minimal "refused" notification may have been shown (#36 S1), never the session one.
        shadowOf(svc).lastForegroundNotification?.let {
            assertEquals("spdhost session refused", it.extras.getCharSequence("android.title")?.toString())
        }
    }

    @Test fun activityAttachIntentRotationAndNewIntent() {
        val attach = Intent(app, MainActivity::class.java).setAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        val c = Robolectric.buildActivity(MainActivity::class.java, attach).setup()
        idle()
        val broker = app.broker
        assertTrue(broker.log.value.any { it.contains("launched by attach intent") })
        val before = broker.log.value.count { it.contains("launched by attach intent") }
        c.recreate(); idle()
        // Rotation: same process-wide broker, the old attach intent is not replayed.
        assertSame(broker, app.broker)
        assertEquals(before, broker.log.value.count { it.contains("launched by attach intent") })
        c.newIntent(Intent(attach)); idle()
        assertEquals(before + 1, broker.log.value.count { it.contains("launched by attach intent") })
        c.pause().stop().destroy()
    }

    @Test fun startEngineWithoutDeviceStartsNoService() {
        val a = Robolectric.buildActivity(MainActivity::class.java).setup().get()
        idle()
        a.startEngine(listOf("--timeout", "3000", "ping"))
        assertTrue(app.engine.state.value.refusal.orEmpty().contains("not open"))
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun detachBroadcastWithNoDeviceLeavesNoDevice() {
        Robolectric.buildActivity(MainActivity::class.java).setup()
        idle()
        app.sendBroadcast(Intent(UsbManager.ACTION_USB_DEVICE_DETACHED).setPackage(app.packageName))
        idle()
        assertEquals(UsbState.NoDevice, app.broker.state.value)
        assertTrue(!app.broker.engineHeld)
    }
}
