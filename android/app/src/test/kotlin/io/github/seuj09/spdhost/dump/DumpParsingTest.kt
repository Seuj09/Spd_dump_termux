package io.github.seuj09.spdhost.dump

import io.github.seuj09.spdhost.engine.EngineEvent
import io.github.seuj09.spdhost.engine.SessionView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** P1-5: parts table, images list --json + table filter, event folding. */
class DumpParsingTest {
    private val parts = """
        # spdhost-parts shift 10 verified 0
        1 boot_a 65536
        2 boot_b 65536
        3 vbmeta_a 64
        4 userdata 0
    """.trimIndent()

    @Test fun partsTableAndJson() {
        val t = PartsTable.parse(parts)
        assertEquals(10, t.shift); assertFalse(t.verified)
        assertEquals(PartRow(1, "boot_a", 65536, 64L shl 20), t.rows[0])
        val j = Json.parse(t.toJson()) as Map<*, *>
        assertEquals(false, j["verified"])
        assertEquals(4, (j["rows"] as List<*>).size)
        assertEquals("boot_a", ((j["rows"] as List<*>)[0] as Map<*, *>)["name"])
    }

    @Test fun imagesListJsonFilteredByTable() {
        val json = """{"v":1,"dir":"/d","layout":"meta","images":[""" +
            """{"name":"boot_a","file":"boot_a.img","bytes":67108864,"slot":"a","sha256":"ab"},""" +
            """{"name":"recovery","file":"recovery.img","bytes":1,"slot":null,"sha256":null}]}"""
        val l = ImagesList.parse(json)
        assertEquals("meta", l.layout)
        assertEquals(2, l.images.size)
        assertNull(l.images[1].sha256)
        assertEquals(listOf("boot_a"), l.filterBy(PartsTable.parse(parts)).map { it.name })
        assertEquals(emptyList<ImageFile>(), l.filterBy(null))
    }

    private fun ev(s: String) = EngineEvent.parse(s)!!

    @Test fun preflightIsAnEstimateOnlyWhenTheTableIsUnverified() {
        val un = SessionView().reduce(ev("""{"v":1,"seq":5,"t":1,"ev":"preflight","op":"dump","files":6,"need":1048576000,"headroom":67108864,"avail":4294967296,"slot":"a","table_verified":false,"ok":true}"""))
        assertTrue(un.preflight!!.text().contains("ESTIMATE"))
        assertTrue(un.preflight!!.text().startsWith("Preflight OK"))
        val ver = SessionView().reduce(ev("""{"v":1,"seq":5,"t":1,"ev":"preflight","op":"dump","files":6,"need":1,"headroom":2,"avail":-1,"slot":"none","table_verified":true,"ok":true}"""))
        assertFalse(ver.preflight!!.text().contains("ESTIMATE"))
        assertTrue(ver.preflight!!.text().contains("free unknown"))
    }

    @Test fun opEventsBranchOnTheOpField() {
        var v = SessionView()
        v = v.reduce(ev("""{"v":1,"seq":6,"t":1,"ev":"dump-file","name":"boot_a","file":"boot_a.img","bytes":67108864,"state":"ok","sha256":"ab"}"""))
        v = v.reduce(ev("""{"v":1,"seq":7,"t":1,"ev":"op","op":"set-active","target":"b","state":"refused","why":"x"}"""))
        assertNull(v.dumpResult)
        assertTrue(v.otherOp!!.startsWith("set-active refused"))
        v = v.reduce(ev("""{"v":1,"seq":8,"t":1,"ev":"op","op":"dump","state":"failed","files":6,"failed":1}"""))
        assertEquals("dump failed: 6 files, 1 failed", v.dumpResult)
        assertEquals(1, v.files.size)
        v = v.reduce(ev("""{"v":1,"seq":9,"t":1,"ev":"end","rc":1,"dropped":0}"""))
        assertEquals(1, v.rc)
    }

    @Test fun jsonRejectsGarbage() {
        for (s in listOf("{", "[1,", "{\"a\":}", "{} x", "tru"))
            assertTrue(s, runCatching { Json.parse(s) }.isFailure)
    }
}
