package io.github.seuj09.spdhost

/**
 * Per-API-level gates (plan §7): foreground service, notifications,
 * PendingIntent mutability. The engine service is
 * P1-3; this captures the gating now so it is tested before it is used.
 */
object ApiGates {
    /** POST_NOTIFICATIONS is a runtime permission from 33. */
    fun needsNotificationPermission(sdk: Int) = sdk >= 33

    /** Notification channels exist from 26; below that NotificationCompat ignores them. */
    fun needsChannel(sdk: Int) = sdk >= 26

    /** startForegroundService exists from 26; below it is startService + startForeground. */
    fun useStartForegroundService(sdk: Int) = sdk >= 26

    /** foregroundServiceType="connectedDevice" is honoured from 29 (ignored below). */
    fun typeHonoured(sdk: Int) = sdk >= 29

    /** FOREGROUND_SERVICE_CONNECTED_DEVICE is checked from 34. */
    fun needsConnectedDevicePermission(sdk: Int) = sdk >= 34

    /** PendingIntent.FLAG_MUTABLE exists (and is needed for UsbManager extras) from 31. */
    fun pendingIntentNeedsMutable(sdk: Int) = sdk >= 31
}
