package io.github.seuj09.spdhost.engine

import io.github.seuj09.spdhost.usb.UsbState

/**
 * When EngineService may call startForeground(connectedDevice) (#36 D1).
 * On 34+ that call throws SecurityException unless USB permission is held
 * (and the device is in use), so:
 *  - the UI starts the service only when the broker has the device open;
 *  - only START goes foreground; STOP and a null/unknown intent never do.
 */
object EngineLaunchPolicy {
    /** Null = may start a session; otherwise the reason it is refused. */
    fun startRefusal(usb: UsbState): String? = when (usb) {
        is UsbState.Opened -> null
        else -> "the USB device is not open (${usb.javaClass.simpleName})"
    }

    /** Whether onStartCommand for [action] goes foreground (connectedDevice). */
    fun goesForeground(action: String?): Boolean = action == EngineService.ACTION_START
}
