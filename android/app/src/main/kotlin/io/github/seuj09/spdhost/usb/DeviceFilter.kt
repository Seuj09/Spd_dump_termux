package io.github.seuj09.spdhost.usb

/** Spreadtrum/Unisoc BROM download mode. Mirrors res/xml/device_filter.xml. */
object UsbIds {
    const val VENDOR_SPRD = 0x1782 // 6018
    const val PRODUCT_BROM = 0x4d00 // 19712
}

/** One endpoint of a USB interface, as UsbEndpoint reports it. */
data class EndpointInfo(
    val address: Int,
    /** UsbConstants.USB_ENDPOINT_XFER_*: 0 control, 1 iso, 2 bulk, 3 interrupt. */
    val type: Int,
    val maxPacketSize: Int,
) {
    val isIn: Boolean get() = (address and 0x80) != 0
    val typeName: String
        get() = when (type) {
            0 -> "control"; 1 -> "iso"; 2 -> "bulk"; 3 -> "interrupt"; else -> "type$type"
        }

    override fun toString(): String =
        "ep 0x%02x %s %s max %d".format(address, if (isIn) "IN" else "OUT", typeName, maxPacketSize)
}

data class InterfaceInfo(
    val id: Int,
    val interfaceClass: Int,
    val subclass: Int,
    val protocol: Int,
    val endpoints: List<EndpointInfo>,
)

/**
 * What the UI needs to know about a UsbDevice, without android.* types so the
 * selection and permission logic run in plain JVM unit tests.
 */
data class DeviceInfo(
    /** UsbDevice.getDeviceName(), e.g. /dev/bus/usb/001/004. Unique while attached. */
    val name: String,
    val vendorId: Int,
    val productId: Int,
    val manufacturer: String? = null,
    val product: String? = null,
    /** Null when not readable yet (API 29+ needs the permission first). */
    val serial: String? = null,
    val interfaces: List<InterfaceInfo> = emptyList(),
) {
    val vidPid: String get() = "%04x:%04x".format(vendorId, productId)
    val isSprd: Boolean get() = vendorId == UsbIds.VENDOR_SPRD
    val isBrom: Boolean get() = isSprd && productId == UsbIds.PRODUCT_BROM
}

/** Result of looking at everything attached. */
sealed interface Selection {
    /** No Spreadtrum (1782) device attached. */
    data object None : Selection

    /** Exactly one 1782 device, and it is the BROM 1782:4d00: the one to use. */
    data class One(val device: DeviceInfo) : Selection

    /** Exactly one 1782 device, but not 4d00: shown, never opened. */
    data class Unsupported(val device: DeviceInfo) : Selection

    /** More than one 1782 device: refused, the user must unplug the extras. */
    data class Multiple(val devices: List<DeviceInfo>) : Selection
}

object DeviceFilter {
    fun matches(vendorId: Int, productId: Int): Boolean =
        vendorId == UsbIds.VENDOR_SPRD && productId == UsbIds.PRODUCT_BROM

    /**
     * Plan P1-2: refuse more than one 1782 device (whatever their PIDs), so the
     * app can never pick the wrong phone. Non-1782 devices (hubs, keyboards)
     * are ignored.
     */
    fun select(attached: Collection<DeviceInfo>): Selection {
        val sprd = attached.filter { it.isSprd }.sortedBy { it.name }
        return when {
            sprd.isEmpty() -> Selection.None
            sprd.size > 1 -> Selection.Multiple(sprd)
            sprd[0].isBrom -> Selection.One(sprd[0])
            else -> Selection.Unsupported(sprd[0])
        }
    }
}
