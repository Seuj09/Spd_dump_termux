package io.github.seuj09.spdhost.usb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class DeviceFilterTest {
    private fun dev(name: String, vid: Int, pid: Int) = DeviceInfo(name, vid, pid)
    private val brom = dev("/dev/bus/usb/001/004", 0x1782, 0x4d00)

    @Test fun matchesOnlyBrom() {
        assertTrue(DeviceFilter.matches(6018, 19712))
        assertFalse(DeviceFilter.matches(0x1782, 0x4d01))
        assertFalse(DeviceFilter.matches(0x18d1, 0x4d00))
        assertEquals("1782:4d00", brom.vidPid)
    }

    @Test fun noneWhenNothingOrOnlyOtherVendors() {
        assertEquals(Selection.None, DeviceFilter.select(emptyList()))
        assertEquals(Selection.None, DeviceFilter.select(listOf(dev("/a", 0x05ac, 0x1234), dev("/b", 0x0bda, 0x8153))))
    }

    @Test fun oneBromAmongOtherDevices() {
        val sel = DeviceFilter.select(listOf(dev("/hub", 0x05e3, 0x0610), brom, dev("/kbd", 0x046d, 0xc31c)))
        assertEquals(Selection.One(brom), sel)
    }

    @Test fun singleNonBromSprdIsUnsupported() {
        val other = dev("/x", 0x1782, 0x4d01)
        assertEquals(Selection.Unsupported(other), DeviceFilter.select(listOf(other)))
    }

    @Test fun twoSprdDevicesAreRefusedWhateverThePid() {
        val second = dev("/dev/bus/usb/001/005", 0x1782, 0x4d00)
        val sel = DeviceFilter.select(listOf(second, brom))
        assertTrue(sel is Selection.Multiple)
        assertEquals(listOf(brom, second), (sel as Selection.Multiple).devices)
        val mixed = DeviceFilter.select(listOf(brom, dev("/y", 0x1782, 0x5000)))
        assertTrue(mixed is Selection.Multiple)
    }

    @Test fun endpointDescription() {
        assertEquals("ep 0x81 IN bulk max 512", EndpointInfo(0x81, 2, 512).toString())
        assertEquals("ep 0x01 OUT bulk max 64", EndpointInfo(0x01, 2, 64).toString())
    }

    /** res/xml/device_filter.xml must list exactly the ids the code selects. */
    @Test fun deviceFilterXmlMatchesCode() {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/xml/device_filter.xml"))
        val nodes = doc.getElementsByTagName("usb-device")
        assertEquals(1, nodes.length)
        val e = nodes.item(0) as org.w3c.dom.Element
        assertEquals(UsbIds.VENDOR_SPRD, e.getAttribute("vendor-id").toInt())
        assertEquals(UsbIds.PRODUCT_BROM, e.getAttribute("product-id").toInt())
    }
}
