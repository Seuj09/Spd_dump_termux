package io.github.seuj09.spdhost.usb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbStateMachineTest {
    private val a = DeviceInfo("/dev/bus/usb/001/004", 0x1782, 0x4d00)
    private val b = DeviceInfo("/dev/bus/usb/001/007", 0x1782, 0x4d00)
    private val hub = DeviceInfo("/dev/bus/usb/001/002", 0x05e3, 0x0610)

    private fun step(s: UsbState, e: UsbEvent) = UsbStateMachine.reduce(s, e)
    private fun scan(vararg d: DeviceInfo, permitted: Set<String> = emptySet()) =
        UsbEvent.Scanned(d.toList(), permitted)

    @Test fun noDeviceStaysNoDevice() {
        assertEquals(Transition(UsbState.NoDevice), step(UsbState.NoDevice, scan(hub)))
    }

    @Test fun newDeviceWithoutPermissionRequestsItOnce() {
        val t = step(UsbState.NoDevice, scan(a, hub))
        assertEquals(UsbState.PermissionRequested(a), t.state)
        assertEquals(listOf(UsbEffect.RequestPermission(a)), t.effects)
        // A rescan (onResume, attach broadcast) must not ask again.
        assertEquals(Transition(t.state), step(t.state, scan(a)))
    }

    @Test fun newDeviceWithPermissionOpensAtOnce() {
        val t = step(UsbState.NoDevice, scan(a, permitted = setOf(a.name)))
        assertEquals(UsbState.Granted(a), t.state)
        assertEquals(listOf(UsbEffect.Open(a)), t.effects)
    }

    @Test fun grantThenOpen() {
        var s: UsbState = UsbState.PermissionRequested(a)
        val t = step(s, UsbEvent.PermissionResult(a.name, true))
        assertEquals(UsbState.Granted(a), t.state)
        assertEquals(listOf(UsbEffect.Open(a)), t.effects)
        s = t.state
        val withSerial = a.copy(serial = "0123456789")
        val o = step(s, UsbEvent.OpenSucceeded(a.name, 42, withSerial))
        assertEquals(UsbState.Opened(withSerial, 42), o.state)
        assertTrue(o.effects.isEmpty())
    }

    @Test fun denyThenUserRetry() {
        val d = step(UsbState.PermissionRequested(a), UsbEvent.PermissionResult(a.name, false))
        assertEquals(UsbState.Denied(a), d.state)
        assertTrue(d.effects.isEmpty())
        // No automatic re-ask on rescan.
        assertEquals(Transition(d.state), step(d.state, scan(a)))
        val r = step(d.state, UsbEvent.UserRequestPermission)
        assertEquals(UsbState.PermissionRequested(a), r.state)
        assertEquals(listOf(UsbEffect.RequestPermission(a)), r.effects)
    }

    @Test fun deniedButGrantedViaSettingsOnRescanOpens() {
        val t = step(UsbState.Denied(a), scan(a, permitted = setOf(a.name)))
        assertEquals(UsbState.Granted(a), t.state)
        assertEquals(listOf(UsbEffect.Open(a)), t.effects)
    }

    @Test fun staleResultsAreIgnored() {
        val s = UsbState.PermissionRequested(b)
        assertEquals(Transition(s), step(s, UsbEvent.PermissionResult(a.name, true)))
        // A late grant after open does not re-open.
        val o = UsbState.Opened(a, 7)
        assertEquals(Transition(o), step(o, UsbEvent.PermissionResult(a.name, true)))
        // An open for a device that is no longer current is closed again.
        val stale = step(UsbState.Detached(a), UsbEvent.OpenSucceeded(a.name, 9))
        assertEquals(UsbState.Detached(a), stale.state)
        assertEquals(listOf(UsbEffect.Close), stale.effects)
    }

    @Test fun openFailureAndUserRetry() {
        val f = step(UsbState.Granted(a), UsbEvent.OpenFailed(a.name, "openDevice returned null"))
        assertEquals(UsbState.OpenFailed(a, "openDevice returned null"), f.state)
        val r = step(f.state, UsbEvent.UserOpen)
        assertEquals(UsbState.Granted(a), r.state)
        assertEquals(listOf(UsbEffect.Open(a)), r.effects)
    }

    @Test fun detachClosesTheConnection() {
        val t = step(UsbState.Opened(a, 42), UsbEvent.Detached(a.name))
        assertEquals(UsbState.Detached(a), t.state)
        assertEquals(listOf(UsbEffect.Close, UsbEffect.Rescan), t.effects)
        // The rescan that follows finds nothing and keeps "Detached" on screen.
        assertEquals(Transition(t.state), step(t.state, scan(hub)))
    }

    @Test fun detachOfAnotherDeviceOnlyRescans() {
        val s = UsbState.Opened(a, 42)
        assertEquals(Transition(s, listOf(UsbEffect.Rescan)), step(s, UsbEvent.Detached(hub.name)))
    }

    @Test fun missedDetachIsCaughtByScan() {
        val t = step(UsbState.Opened(a, 42), scan(hub))
        assertEquals(UsbState.Detached(a), t.state)
        assertEquals(listOf(UsbEffect.Close), t.effects)
    }

    @Test fun replugAfterDetachAsksAgain() {
        val replugged = a.copy(name = "/dev/bus/usb/001/009")
        val t = step(UsbState.Detached(a), scan(replugged))
        assertEquals(UsbState.PermissionRequested(replugged), t.state)
        assertEquals(listOf(UsbEffect.RequestPermission(replugged)), t.effects)
    }

    @Test fun secondSprdDeviceRefusesAndClosesTheOpenOne() {
        val t = step(UsbState.Opened(a, 42), scan(a, b, permitted = setOf(a.name, b.name)))
        assertEquals(UsbState.Multiple(listOf(a, b)), t.state)
        assertEquals(listOf(UsbEffect.Close), t.effects)
        // Nothing is requested or opened while two are attached.
        assertEquals(Transition(t.state), step(t.state, UsbEvent.UserRequestPermission))
        assertEquals(Transition(t.state), step(t.state, UsbEvent.UserOpen))
        // Unplug one: the remaining device is picked up normally.
        val after = step(t.state, scan(b))
        assertEquals(UsbState.PermissionRequested(b), after.state)
    }

    @Test fun nonBromSprdIsShownButNeverOpened() {
        val odd = DeviceInfo("/x", 0x1782, 0x5000)
        val t = step(UsbState.NoDevice, scan(odd, permitted = setOf(odd.name)))
        assertEquals(UsbState.Unsupported(odd), t.state)
        assertTrue(t.effects.isEmpty())
        assertEquals(UsbState.NoDevice, step(t.state, scan()).state)
    }

    @Test fun userCloseKeepsPermissionAndAllowsReopen() {
        val c = step(UsbState.Opened(a, 42), UsbEvent.UserClose)
        assertEquals(UsbState.Granted(a), c.state)
        assertEquals(listOf(UsbEffect.Close), c.effects)
        // Rescans do not re-open behind the user's back.
        assertEquals(Transition(c.state), step(c.state, scan(a, permitted = setOf(a.name))))
        assertEquals(listOf(UsbEffect.Open(a)), step(c.state, UsbEvent.UserOpen).effects)
    }

    @Test fun openedStateIsStableAcrossRescans() {
        val s = UsbState.Opened(a, 42)
        assertEquals(Transition(s), step(s, scan(a, hub, permitted = setOf(a.name))))
    }
}
