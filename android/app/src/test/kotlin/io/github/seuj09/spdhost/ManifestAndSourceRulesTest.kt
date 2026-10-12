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

    private fun code(f: File): String =
        // Code only: comments may explain why these are absent.
        f.readLines().filterNot { it.trimStart().let { l -> l.startsWith("*") || l.startsWith("//") || l.startsWith("/*") } }
            .joinToString("\n")

    @Test fun noJavaClaimInterfaceAndNoYes() {
        assertTrue(sources.size >= 5)
        // Any spelling of --yes in code: a string literal, a list element,
        // a concatenation ("--" + "yes" is caught by the second pattern).
        val yes = Regex("""--yes\b""")
        val yesSplit = Regex(""""--"\s*\+\s*"yes"""")
        for (f in sources) {
            val code = code(f)
            assertFalse("${f.name} calls claimInterface", code.contains("claimInterface("))
            assertFalse("${f.name} passes --yes", yes.containsMatchIn(code) || yesSplit.containsMatchIn(code))
            assertFalse("${f.name} uses bulkTransfer", code.contains("bulkTransfer("))
            // Storage is app dir + SAF (decision 5): no MediaStore in P1.
            assertFalse("${f.name} uses MediaStore", code.contains("MediaStore"))
            // No SPDHOST_* knob is ever set for the core. CoreEnv strips them
            // and is the only file allowed to name the prefix.
            if (f.name != "CoreEnv.kt") assertFalse("${f.name} names SPDHOST_", code.contains("SPDHOST_"))
            // Never the abstract namespace for the fd socket.
            assertFalse("${f.name} uses LocalServerSocket(String)", Regex("""LocalServerSocket\(\s*"""").containsMatchIn(code))
            assertFalse("${f.name} uses Namespace.ABSTRACT", code.contains("Namespace.ABSTRACT"))
        }
    }

    @Test fun usbFdReachesTheCoreOnlyThroughThePathSocket() {
        val all = sources.associate { it.name to code(it) }
        // No --usb-fd N (an fd number in argv) anywhere; --usb-fd-sock only in EngineArgv.
        for ((name, code) in all) {
            assertFalse("$name passes --usb-fd N", code.contains("\"--usb-fd\""))
            if (name != "EngineArgv.kt") assertFalse("$name builds --usb-fd-sock argv", code.contains("--usb-fd-sock"))
        }
        val srv = all.getValue("FdSocketServer.kt")
        assertTrue(srv.contains("Namespace.FILESYSTEM"))
        assertTrue(srv.contains("LocalServerSocket(bound.fileDescriptor)"))
        assertTrue(srv.contains("setFileDescriptorsForSend"))
        assertTrue(srv.contains("path.delete()"))
        // caps stays caps-only.
        assertTrue(all.getValue("CoreRunner.kt").contains("ProcessBuilder(bin.path, \"caps\")"))
        // The session exec goes through the sanitized env.
        assertTrue(all.getValue("EngineSession.kt").contains("CoreEnv.sanitize(pb.environment())"))
    }

    @Test fun engineServiceIsPrivateConnectedDevice() {
        val svc = elements("service").single { it.getAttributeNS(ns, "name") == ".engine.EngineService" }
        assertEquals("false", svc.getAttributeNS(ns, "exported"))
        assertEquals("connectedDevice", svc.getAttributeNS(ns, "foregroundServiceType"))
    }
}
