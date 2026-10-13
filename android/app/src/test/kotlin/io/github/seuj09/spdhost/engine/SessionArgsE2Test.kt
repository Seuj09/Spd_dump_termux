package io.github.seuj09.spdhost.engine

import io.github.seuj09.spdhost.loader.LoaderPack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * E2 (plan §4.1): the Kotlin argv builder == menu.sh's run_session traces.
 * The goldens are recorded from menu.sh by no-root/tests/menu-traces.sh
 * (which also proves the APK argv and the menu argv give a byte-identical
 * `--dry-run` packet trace). Paths: /R = loader root, /D = dump folder.
 *
 * `.trace` is what menu.sh ran; `.apk` is that trace with the two documented
 * differences applied (SPDHOST_PART_XML_DIR -> --part-xml, no misc slot
 * read-part). This test checks both: SessionArgs == .apk, and .apk ==
 * normalise(.trace) re-derived here.
 */
class SessionArgsE2Test {
    private val gold = File("src/test/resources/e2")
    private val ix = LoaderPack.parseIndex(File("../../no-root/fdl/index").readText())
    private val l = SessionArgs.loaders("/R", ix, ix.pairs.first { it.id == "ums9230/infinix" })
    private val d = "/D"

    private fun apk(name: String) = File(gold, "$name.apk").readLines().filter { it.isNotEmpty() }

    private fun normalise(name: String): List<String> {
        val t = File(gold, "$name.trace").readLines()
        val x = t.first { it.startsWith("env SPDHOST_PART_XML_DIR=") }.substringAfter('=')
        val a = t.filter { it.startsWith("arg ") }.map { it.removePrefix("arg ") }
        var i = 0
        val out = ArrayList<String>()
        while (i < a.size && a[i].startsWith("--")) { out += a[i]; if (a[i] == "--timeout") out += a[++i]; i++ }
        if (a[i] != "ping") out += listOf("--part-xml", x)
        while (i < a.size) { if (a[i] == "read-part") { i += 5; continue }; out += a[i++] }
        return out
    }

    private val cases: Map<String, List<String>> = mapOf(
        "hello" to SessionArgs.hello(),
        "parts-reset" to SessionArgs.parts(l, d, SessionArgs.Ending.RESET),
        "parts-power-off" to SessionArgs.parts(l, d, SessionArgs.Ending.POWER_OFF),
        "dump-one-reset" to SessionArgs.dump(l, d, SessionArgs.Preset.One("boot_a"), SessionArgs.Ending.RESET),
        "dump-one-power-off" to SessionArgs.dump(l, d, SessionArgs.Preset.One("boot_a"), SessionArgs.Ending.POWER_OFF),
        "dump-all_lite-reset" to SessionArgs.dump(l, d, SessionArgs.Preset.AllLite, SessionArgs.Ending.RESET),
        "dump-all-power-off" to SessionArgs.dump(l, d, SessionArgs.Preset.All, SessionArgs.Ending.POWER_OFF),
    )

    @Test fun everyP1OpHasAGolden() {
        val names = gold.listFiles()!!.map { it.name.substringBeforeLast('.') }.toSet()
        assertEquals(cases.keys, names)
    }

    @Test fun builderEqualsMenuTraces() {
        for ((name, argv) in cases) {
            assertEquals("$name: SessionArgs vs .apk golden", apk(name), argv)
            assertEquals("$name: .apk golden vs normalised menu trace", normalise(name), apk(name))
        }
    }

    @Test fun onlyTheDocumentedDifferences() {
        for (name in cases.keys) {
            val t = File(gold, "$name.trace").readLines().filter { it.startsWith("arg ") }.map { it.removePrefix("arg ") }
            val a = apk(name)
            val extra = a - t.toSet()
            val missing = t - a.toSet()
            assertTrue("$name: APK adds only --part-xml DIR: $extra", extra.all { it == "--part-xml" || it == "/D/meta" })
            assertTrue("$name: APK drops only the misc slot read: $missing",
                missing.all { it in setOf("read-part", "misc", "0x800", "32", "/D/meta/misc-slotinfo.img") })
            assertTrue("$name: no --yes", a.none { it.startsWith("--yes") })
        }
    }
}
