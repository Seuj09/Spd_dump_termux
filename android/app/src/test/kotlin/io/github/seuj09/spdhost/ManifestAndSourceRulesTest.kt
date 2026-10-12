package io.github.seuj09.spdhost

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** Static checks on the shipped manifest and sources (plan P1-1/P1-2 rules). */
class ManifestAndSourceRulesTest {
    private val ns = "http://schemas.android.com/apk/res/android"
    private val manifest = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml")).documentElement

    private fun elements(tag: String): List<Element> =
        manifest.getElementsByTagName(tag).let { l -> (0 until l.length).map { l.item(it) as Element } }

    @Test fun usbHostIsRequired() {
        val f = elements("uses-feature").single { it.getAttributeNS(ns, "name") == "android.hardware.usb.host" }
        assertEquals("true", f.getAttributeNS(ns, "required"))
    }

    @Test fun activityIsSingleTopWithAttachFilter() {
        val act = elements("activity").single()
        assertEquals("singleTop", act.getAttributeNS(ns, "launchMode"))
        val actions = act.getElementsByTagName("action").let { l -> (0 until l.length).map { (l.item(it) as Element).getAttributeNS(ns, "name") } }
        assertTrue("android.hardware.usb.action.USB_DEVICE_ATTACHED" in actions)
        val meta = act.getElementsByTagName("meta-data").item(0) as Element
        assertEquals("@xml/device_filter", meta.getAttributeNS(ns, "resource"))
    }

    @Test fun fgsPermissionsDeclared() {
        val perms = elements("uses-permission").map { it.getAttributeNS(ns, "name") }.toSet()
        for (p in listOf("FOREGROUND_SERVICE", "FOREGROUND_SERVICE_CONNECTED_DEVICE", "POST_NOTIFICATIONS", "WAKE_LOCK"))
            assertTrue(p, "android.permission.$p" in perms)
        // Storage is app-dir + SAF only (decision 5): no broad storage permission.
        assertFalse(perms.any { it.contains("EXTERNAL_STORAGE") })
    }

    private val sources = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.toList()

    @Test fun noJavaClaimInterfaceAndNoYes() {
        assertTrue(sources.size >= 5)
        for (f in sources) {
            // Code only: comments may explain why these are absent.
            val code = f.readLines().filterNot { it.trimStart().let { l -> l.startsWith("*") || l.startsWith("//") || l.startsWith("/*") } }
                .joinToString("\n")
            assertFalse("${f.name} calls claimInterface", code.contains("claimInterface("))
            assertFalse("${f.name} passes --yes", code.contains("\"--yes\""))
            assertFalse("${f.name} uses bulkTransfer", code.contains("bulkTransfer("))
        }
    }

    @Test fun deviceFdNeverReachesTheCoreYet() {
        // P1-2 detects only; the fd hand-off is P0-5/P1-3. The runner's only argv is "caps".
        val runner = File("src/main/kotlin/io/github/seuj09/spdhost/engine/CoreRunner.kt").readText()
        assertTrue(runner.contains("ProcessBuilder(bin.path, \"caps\")"))
        assertFalse(runner.contains("--usb-fd"))
    }
}
