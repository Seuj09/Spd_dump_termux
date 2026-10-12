package io.github.seuj09.spdhost.usb

/** What the UI shows. Every state that concerns a device carries it. */
sealed interface UsbState {
    data object NoDevice : UsbState
    data class Multiple(val devices: List<DeviceInfo>) : UsbState
    data class Unsupported(val device: DeviceInfo) : UsbState
    data class Found(val device: DeviceInfo) : UsbState
    data class PermissionRequested(val device: DeviceInfo) : UsbState
    data class Granted(val device: DeviceInfo) : UsbState
    data class Denied(val device: DeviceInfo) : UsbState
    data class Opened(val device: DeviceInfo, val fd: Int) : UsbState
    data class OpenFailed(val device: DeviceInfo, val reason: String) : UsbState
    data class Detached(val device: DeviceInfo) : UsbState
}

val UsbState.device: DeviceInfo?
    get() = when (this) {
        is UsbState.Found -> device
        is UsbState.PermissionRequested -> device
        is UsbState.Granted -> device
        is UsbState.Denied -> device
        is UsbState.Opened -> device
        is UsbState.OpenFailed -> device
        is UsbState.Detached -> device
        is UsbState.Unsupported -> device
        UsbState.NoDevice, is UsbState.Multiple -> null
    }

sealed interface UsbEvent {
    /** A fresh look at UsbManager.deviceList; [permitted] = device names with hasPermission(). */
    data class Scanned(val attached: List<DeviceInfo>, val permitted: Set<String>) : UsbEvent
    data class PermissionResult(val deviceName: String, val granted: Boolean) : UsbEvent
    data class OpenSucceeded(val deviceName: String, val fd: Int, val device: DeviceInfo? = null) : UsbEvent
    data class OpenFailed(val deviceName: String, val reason: String) : UsbEvent
    data class Detached(val deviceName: String) : UsbEvent
    data object UserRequestPermission : UsbEvent
    data object UserOpen : UsbEvent
    data object UserClose : UsbEvent
}

/** Side effects the broker carries out (Android calls), in order. */
sealed interface UsbEffect {
    data class RequestPermission(val device: DeviceInfo) : UsbEffect
    data class Open(val device: DeviceInfo) : UsbEffect
    /** Close the open UsbDeviceConnection (and with it the fd). */
    data object Close : UsbEffect
    /** Something changed that needs a fresh UsbManager.deviceList. */
    data object Rescan : UsbEffect
}

data class Transition(val state: UsbState, val effects: List<UsbEffect> = emptyList())

/**
 * The permission/open state machine of plan P1-2, kept free of android.* so
 * it is unit-tested on the JVM. Rules:
 *  - one 1782:4d00 device only; a second 1782 device refuses (and closes);
 *  - a new device with permission is opened at once; without it the
 *    permission is requested once per attach, then only on user request;
 *  - results for a device that is no longer the current one are ignored;
 *  - detaching the current device closes its connection.
 * No interface is ever claimed from Java: the fd goes to the core later.
 */
object UsbStateMachine {
    fun reduce(state: UsbState, event: UsbEvent): Transition = when (event) {
        is UsbEvent.Scanned -> scanned(state, event)
        is UsbEvent.PermissionResult -> {
            val cur = state.device
            when {
                cur == null || cur.name != event.deviceName -> Transition(state)
                state !is UsbState.PermissionRequested && state !is UsbState.Found &&
                    state !is UsbState.Denied -> Transition(state)
                event.granted -> Transition(UsbState.Granted(cur), listOf(UsbEffect.Open(cur)))
                else -> Transition(UsbState.Denied(cur))
            }
        }
        is UsbEvent.OpenSucceeded -> {
            val cur = state.device
            if (state is UsbState.Granted && cur != null && cur.name == event.deviceName) {
                Transition(UsbState.Opened(event.device ?: cur, event.fd))
            } else {
                // Stale open (device changed meanwhile): close it again.
                Transition(state, listOf(UsbEffect.Close))
            }
        }
        is UsbEvent.OpenFailed -> {
            val cur = state.device
            if (state is UsbState.Granted && cur != null && cur.name == event.deviceName) {
                Transition(UsbState.OpenFailed(cur, event.reason))
            } else Transition(state)
        }
        is UsbEvent.Detached -> {
            val cur = state.device
            if (cur != null && cur.name == event.deviceName && state !is UsbState.Detached) {
                val fx = if (state is UsbState.Opened) listOf(UsbEffect.Close) else emptyList()
                Transition(UsbState.Detached(cur), fx + UsbEffect.Rescan)
            } else Transition(state, listOf(UsbEffect.Rescan))
        }
        UsbEvent.UserRequestPermission -> when (state) {
            is UsbState.Found, is UsbState.Denied ->
                Transition(UsbState.PermissionRequested(state.device!!), listOf(UsbEffect.RequestPermission(state.device!!)))
            else -> Transition(state)
        }
        UsbEvent.UserOpen -> when (state) {
            is UsbState.OpenFailed -> Transition(UsbState.Granted(state.device), listOf(UsbEffect.Open(state.device)))
            is UsbState.Granted -> Transition(state, listOf(UsbEffect.Open(state.device)))
            else -> Transition(state)
        }
        UsbEvent.UserClose -> when (state) {
            is UsbState.Opened -> Transition(UsbState.Granted(state.device), listOf(UsbEffect.Close))
            else -> Transition(state)
        }
    }

    private fun scanned(state: UsbState, ev: UsbEvent.Scanned): Transition {
        val closeIfOpen = if (state is UsbState.Opened) listOf(UsbEffect.Close) else emptyList()
        return when (val sel = DeviceFilter.select(ev.attached)) {
            Selection.None -> {
                val cur = state.device
                when {
                    state is UsbState.Detached -> Transition(state)
                    // A detach we did not hear about: treat it as one.
                    cur != null && state !is UsbState.Unsupported -> Transition(UsbState.Detached(cur), closeIfOpen)
                    else -> Transition(UsbState.NoDevice, closeIfOpen)
                }
            }
            is Selection.Multiple -> Transition(UsbState.Multiple(sel.devices), closeIfOpen)
            is Selection.Unsupported -> Transition(UsbState.Unsupported(sel.device), closeIfOpen)
            is Selection.One -> {
                val dev = sel.device
                val permitted = dev.name in ev.permitted
                val cur = state.device
                val same = cur != null && cur.name == dev.name && state !is UsbState.Detached &&
                    state !is UsbState.Unsupported
                if (same) {
                    when (state) {
                        is UsbState.Found, is UsbState.PermissionRequested, is UsbState.Denied ->
                            if (permitted) Transition(UsbState.Granted(dev), listOf(UsbEffect.Open(dev)))
                            else Transition(state)
                        else -> Transition(state) // Granted/Opened/OpenFailed: keep.
                    }
                } else if (permitted) {
                    Transition(UsbState.Granted(dev), closeIfOpen + UsbEffect.Open(dev))
                } else {
                    Transition(UsbState.PermissionRequested(dev), closeIfOpen + UsbEffect.RequestPermission(dev))
                }
            }
        }
    }
}
