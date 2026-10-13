package io.github.seuj09.spdhost.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.github.seuj09.spdhost.ApiGates
import androidx.core.content.IntentCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Owns the app's view of USB (plan P1-2). Lives as long as the process (held
 * by [io.github.seuj09.spdhost.SpdhostApp]), so rotation or Activity
 * recreation never drops an open connection.
 *
 *  - Finds the phone from the attach intent and by enumerating
 *    UsbManager.deviceList (at start, on attach/detach, on resume).
 *  - Asks for permission with an explicit-package PendingIntent;
 *    FLAG_MUTABLE only on API 31+ (UsbManager fills in the extras; below 31
 *    mutable is the default and the constant does not exist).
 *  - Receivers go through ContextCompat.registerReceiver(…,
 *    RECEIVER_NOT_EXPORTED); system USB broadcasts still reach them.
 *  - Opens the device with openDevice() to get the usbfs fd and keeps the
 *    UsbDeviceConnection open until the device leaves or the user closes it
 *    (and, while a core session runs, until the child exits: see
 *    [holdForEngine]). It never calls claimInterface():
 *    the core claims the interface itself through libusb.
 *
 * All state changes run on the main thread through [UsbStateMachine].
 */
class UsbBroker(context: Context) {
    private val app = context.applicationContext
    private val usb = app.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())

    private val _state = MutableStateFlow<UsbState>(UsbState.NoDevice)
    val state: StateFlow<UsbState> = _state.asStateFlow()

    /** Short history for the screen: what happened, newest last. */
    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()

    private var connection: UsbDeviceConnection? = null
    private var started = false

    /**
     * P1-3: while the core child runs, the connection is pinned. A close
     * (user, detach, multiple devices) is deferred until [releaseFromEngine],
     * so the fd the child holds a dup of is never closed under it by us.
     */
    @Volatile var engineHeld = false
        private set
    private var closePending = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val dev = IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val name = dev?.deviceName ?: state.value.device?.name ?: return
                    note("permission ${if (granted) "granted" else "denied"} for $name")
                    dispatch(UsbEvent.PermissionResult(name, granted))
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val name = dev?.deviceName ?: return dispatch(UsbEvent.Scanned(scan(), permitted()))
                    note("detached $name")
                    dispatch(UsbEvent.Detached(name))
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    note("attached ${dev?.let { describe(it) } ?: "a device"}")
                    rescan()
                }
            }
        }
    }

    fun start() {
        if (started) return
        started = true
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        }
        ContextCompat.registerReceiver(app, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        note("broker started (API ${Build.VERSION.SDK_INT})")
        rescan()
    }

    /** From MainActivity.onCreate/onNewIntent: the system's attach intent. */
    fun handleIntent(intent: Intent?) {
        if (intent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
        val dev = IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        note("launched by attach intent: ${dev?.let { describe(it) } ?: "no device extra"}")
        rescan()
    }

    fun rescan() = dispatch(UsbEvent.Scanned(scan(), permitted()))
    fun requestPermission() = dispatch(UsbEvent.UserRequestPermission)
    fun open() = dispatch(UsbEvent.UserOpen)
    fun close() = dispatch(UsbEvent.UserClose)

    private fun dispatch(event: UsbEvent) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { dispatch(event) }
            return
        }
        val t = UsbStateMachine.reduce(_state.value, event)
        _state.value = t.state
        t.effects.forEach(::run)
    }

    private fun run(effect: UsbEffect) {
        when (effect) {
            is UsbEffect.RequestPermission -> {
                val dev = find(effect.device.name) ?: return rescan()
                note("requesting permission for ${effect.device.vidPid}")
                usb.requestPermission(dev, permissionIntent())
            }
            is UsbEffect.Open -> openNow(effect.device)
            UsbEffect.Close -> closeNow()
            UsbEffect.Rescan -> main.post { rescan() }
        }
    }

    private fun permissionIntent(): PendingIntent {
        // Explicit: only this package can receive it.
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(app.packageName)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (ApiGates.pendingIntentNeedsMutable(Build.VERSION.SDK_INT)) flags = flags or PendingIntent.FLAG_MUTABLE
        return PendingIntent.getBroadcast(app, 0, intent, flags)
    }

    /**
     * Pins the open connection for a core session and returns its fd, or
     * null when nothing is open. Any thread; runs on the main thread.
     */
    fun holdForEngine(): Int? = onMain {
        val c = connection
        if (c == null || engineHeld) null else {
            engineHeld = true
            note("connection pinned for the core session")
            c.fileDescriptor
        }
    }

    /** The child exited: unpin, and carry out a close that was deferred. */
    fun releaseFromEngine() {
        onMain {
            engineHeld = false
            note("core session ended; connection unpinned")
            if (closePending) { closePending = false; closeNow() }
        }
    }

    private fun <T> onMain(body: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return body()
        val latch = java.util.concurrent.CountDownLatch(1)
        var out: Result<T>? = null
        main.post { out = runCatching(body); latch.countDown() }
        latch.await()
        return out!!.getOrThrow()
    }

    private fun openNow(info: DeviceInfo) {
        if (engineHeld) {
            dispatch(UsbEvent.OpenFailed(info.name, "a core session is running"))
            return
        }
        val dev = find(info.name)
        if (dev == null) {
            dispatch(UsbEvent.OpenFailed(info.name, "device is gone"))
            return
        }
        closeNow()
        val conn = try {
            usb.openDevice(dev)
        } catch (e: SecurityException) {
            dispatch(UsbEvent.OpenFailed(info.name, "no permission: ${e.message}"))
            return
        }
        if (conn == null) {
            dispatch(UsbEvent.OpenFailed(info.name, "openDevice returned null"))
            return
        }
        connection = conn
        val fd = conn.fileDescriptor
        // Serial is readable now (permission held); prefer the connection's.
        val withSerial = toInfo(dev).let { it.copy(serial = conn.serial ?: it.serial) }
        note("opened ${info.vidPid}: fd $fd")
        dispatch(UsbEvent.OpenSucceeded(info.name, fd, withSerial))
    }

    private fun closeNow() {
        if (engineHeld) {
            closePending = true
            note("close deferred until the core session ends")
            return
        }
        val c = connection ?: return
        connection = null
        c.close()
        note("connection closed")
    }

    private fun find(name: String): UsbDevice? = usb.deviceList[name]

    private fun scan(): List<DeviceInfo> = usb.deviceList.values.map(::toInfo)

    private fun permitted(): Set<String> =
        usb.deviceList.values.filter { it.vendorId == UsbIds.VENDOR_SPRD && usb.hasPermission(it) }
            .map { it.deviceName }.toSet()

    private fun note(msg: String) {
        val stamp = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date())
        _log.value = (_log.value + "$stamp $msg").takeLast(40)
    }

    companion object {
        const val ACTION_USB_PERMISSION = "io.github.seuj09.spdhost.USB_PERMISSION"

        fun describe(d: UsbDevice) = "%04x:%04x %s".format(d.vendorId, d.productId, d.deviceName)

        fun toInfo(d: UsbDevice): DeviceInfo {
            // API 29+: getSerialNumber() throws without the permission.
            val serial = try { d.serialNumber } catch (_: SecurityException) { null }
            val ifaces = (0 until d.interfaceCount).map { i ->
                val f = d.getInterface(i)
                InterfaceInfo(
                    id = f.id,
                    interfaceClass = f.interfaceClass,
                    subclass = f.interfaceSubclass,
                    protocol = f.interfaceProtocol,
                    endpoints = (0 until f.endpointCount).map { e ->
                        val ep = f.getEndpoint(e)
                        EndpointInfo(ep.address, ep.type, ep.maxPacketSize)
                    },
                )
            }
            return DeviceInfo(
                name = d.deviceName,
                vendorId = d.vendorId,
                productId = d.productId,
                manufacturer = d.manufacturerName,
                product = d.productName,
                serial = serial,
                interfaces = ifaces,
            )
        }
    }
}
