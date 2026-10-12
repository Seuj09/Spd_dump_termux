package io.github.seuj09.spdhost.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EngineEventsTest {
    @Test fun parsesReadmeSample() {
        val e = EngineEvent.parse("""{"v":1,"seq":1,"t":0,"ev":"start","build_sha":"0123456789abcdef0123456789abcdef01234567","build_dirty":"0","protocol":1,"pid":4242}""")!!
        assertEquals("start", e.ev)
        assertEquals("4242", e["pid"])
        assertEquals("1", e["protocol"])
        val h = EngineEvent.parse("""{"v":1,"seq":7,"t":0,"ev":"hello","stage":"brom","try":1,"of":15,"result":"ver","ms":0}""")!!
        assertEquals("hello brom try 1/15: ver (0 ms)", h.summary())
    }

    @Test fun escapesAndBooleans() {
        val e = EngineEvent.parse("""{"ev":"progress","op":"loader","name":"/sdcard/a \"b\"\\c\u0041","table_verified":false}""")!!
        assertEquals("/sdcard/a \"b\"\\cA", e["name"])
        assertEquals("false", e["table_verified"])
    }

    @Test fun opBranchesOnOp() {
        assertEquals("op dump: refused (space)", EngineEvent.parse("""{"ev":"op","op":"dump","state":"refused","why":"space"}""")!!.summary())
    }

    @Test fun rejectsGarbage() {
        assertNull(EngineEvent.parse(""))
        assertNull(EngineEvent.parse("spdhost: hello"))
        assertNull(EngineEvent.parse("""{"v":1}"""))
        assertNull(EngineEvent.parse("""{"ev":"x""""))
        assertNull(EngineEvent.parse("""{"ev":"x"} trailing"""))
    }
}
