package io.github.seuj09.spdhost.engine

import io.github.seuj09.spdhost.loader.LoaderPack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** P1-5 (E2): session argv == menu.sh run_session traces; read-only grammar. */
class SessionArgsTest {
    private val root = "/data/user/0/x/files/loaders"
    private val dir = "/storage/emulated/0/Android/data/x/files/dumps/20261013-101500"
    private val ix = LoaderPack.parseIndex(File("../../no-root/fdl/index").readText())
    private val pair = ix.pairs.first { it.id == "ums9230/infinix" }
    private val l = SessionArgs.loaders(root, ix, pair)

    @Test fun loadersMatchTheMenuExecAddrPrefix() {
        // menu.sh run_session: exec_addr EA STUB fdl FDL1 A1 fdl FDL2 A2 (README example line).
        assertEquals(listOf(
            "exec_addr", "0x65015f08", "$root/fdl/ums9230/custom_exec_no_verify_65015f08.bin",
            "fdl", "$root/fdl/ums9230/infinix/fdl1-dl.bin", "0x65000800",
            "fdl", "$root/fdl/ums9230/infinix/fdl2-dl.bin", "0x9efffe00"), l)
    }

    @Test fun dumpMatchesOpsDumpSession() {
        // menu.sh ops_dump_session: run_session --keep-going fdl … ops dump "$DUMP_DIR" --preset P "$BOOT_AFTER"
        // -> "+ RUNNER --timeout 3000 --keep-going exec_addr … ops dump DIR --preset all_lite reset" (menu-dump.sh).
        val a = SessionArgs.dump(l, dir, SessionArgs.Preset.AllLite, SessionArgs.Ending.RESET)
        assertEquals(listOf("--timeout", "3000", "--keep-going", "--part-xml", "$dir/meta") + l +
            listOf("ops", "dump", dir, "--preset", "all_lite", "reset"), a)
        val menuTail = listOf("ops", "dump", dir, "--preset", "all_lite", "reset")
        assertEquals(menuTail, a.takeLast(6))
        assertEquals(listOf("--preset", "boot", "power-off"),
            SessionArgs.dump(l, dir, SessionArgs.Preset.One("boot"), SessionArgs.Ending.POWER_OFF).takeLast(3))
        assertEquals(listOf("--preset", "all", "reset"), SessionArgs.dump(l, dir, SessionArgs.Preset.All, SessionArgs.Ending.RESET).takeLast(3))
        val menu = File("../../no-root/scripts/menu.sh").readText()
        assertTrue(menu.contains("ops dump \"\$DUMP_DIR\" \"\${pre[@]}\" \"\$BOOT_AFTER\""))
        assertTrue(menu.contains("run_session --keep-going fdl"))
        assertTrue(menu.contains("prefix=(--timeout \"\${SPDHOST_TIMEOUT:-3000}\")"))
    }

    @Test fun partsReadsIntoMetaAndEnds() {
        val a = SessionArgs.parts(l, dir, SessionArgs.Ending.RESET)
        assertEquals(listOf("--timeout", "3000", "--part-xml", "$dir/meta") + l + listOf("parts", "$dir/meta/partition_list.txt", "reset"), a)
    }

    @Test fun metaDirIsCreatedBeforeTheSession() {
        assertEquals(listOf("$dir/meta"), SessionArgs.dirsToCreate(SessionArgs.dump(l, dir, SessionArgs.Preset.All, SessionArgs.Ending.RESET)))
        assertEquals(emptyList<String>(), SessionArgs.dirsToCreate(SessionArgs.hello()))
        val svc = File("src/main/kotlin/io/github/seuj09/spdhost/engine/EngineService.kt").readText()
        val mk = svc.indexOf("SessionArgs.dirsToCreate(commands)")
        assertTrue(mk > 0 && mk < svc.indexOf("holdForEngine()"))
    }

    @Test fun grammarRefusesWritesAndOddShapes() {
        fun bad(vararg c: String) = assertThrows(c.joinToString(" "), EngineArgv.Refused::class.java) { EngineArgv.validate(c.toList()) }
        val f = l.toTypedArray()
        bad(*f, "write-part", "boot", "/x.img", "reset")
        bad(*f, "ops", "misc-reboot", "recovery")
        bad(*f, "ops", "set-active", "a")
        bad(*f, "ops", "dump", dir)                                   // no preset
        bad(*f, "ops", "dump", dir, "--preset", "all", "--preset", "boot")
        bad(*f, "ops", "dump", dir, "--preset", "userdata")
        bad(*f, "ops", "dump", "rel/dir", "--preset", "all")
        bad(*f, "parts", "/p", "ops", "dump", dir, "--preset", "all")  // one op
        bad(*f, "parts", "/p", "reset", "power-off")
        bad("--dangerous", *f, "parts", "/p")
        bad("--confirm-plan", "0", *f, "parts", "/p")
        bad("--part-xml", "rel", *f, "parts", "/p")
        bad("fdl", "/a", "0x1", "parts", "/p")                        // one fdl
        bad("parts", "/p")
        bad(*f, "erase-part", "misc")
        bad(*f, "reacquire")
        EngineArgv.validate(listOf("ping"))
    }
}
