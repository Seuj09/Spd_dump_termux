package io.github.seuj09.spdhost.e8

import android.content.Context
import io.github.seuj09.spdhost.usb.DeviceInfo
import io.github.seuj09.spdhost.usb.UsbBroker
import io.github.seuj09.spdhost.usb.UsbState

/**
 * E8 only (src/test: compiled into no APK, #41 note 2). Robolectric has no
 * USB host, so [openForTest] stands in for a real open: the broker reports
 * Opened and [holdForEngine] hands out [fd] with no UsbDeviceConnection.
 */
class FakeUsbBroker(context: Context) : UsbBroker(context) {
    @Volatile private var fd: Int? = null
    override fun openFd(): Int? = fd
    override fun onClosed() { fd = null }
    fun openForTest(info: DeviceInfo, fd: Int) { this.fd = fd; publish(UsbState.Opened(info, fd)) }
}
