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

    /**
     * #36 S1: a service started with startForegroundService (26+) must call
     * startForeground even when it refuses, or the system kills the app
     * ("did not call startForeground"). Null = no foreground needed (below
     * 26: plain startService). Otherwise the FGS type for that minimal
     * notification: on 34+ shortService (no permission precondition, unlike
     * connectedDevice, which throws without USB permission); below, NONE (0)
     * (types are only enforced from 34; ServiceCompat ignores them below 29).
     */
    fun refusalForegroundType(sdk: Int): Int? = when {
        sdk < 26 -> null
        sdk >= 34 -> FOREGROUND_SERVICE_TYPE_SHORT_SERVICE
        else -> 0
    }

    /** ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE (API 34). */
    const val FOREGROUND_SERVICE_TYPE_SHORT_SERVICE = 2048
}
