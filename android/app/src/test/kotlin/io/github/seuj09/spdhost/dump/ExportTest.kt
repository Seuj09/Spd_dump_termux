package io.github.seuj09.spdhost.dump

import io.github.seuj09.spdhost.engine.EngineArgv
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

/** P1-6 export verification + the P1-5 review soft notes. */
class ExportTest {
    private fun sha(b: ByteArray) = Exporter.hex(MessageDigest.getInstance("SHA-256").digest(b))
    private val data = ByteArray(3 shl 20) { (it * 31).toByte() }

    @Test fun sumsParse() {
        val h = sha(data)
        val m = Sums.parse("$h  boot_a.img\n${h.uppercase()} *vbmeta.img\r\nbad line\n$h  ../evil.img\n$h  /abs.img\n")
        assertEquals(mapOf("boot_a.img" to h, "vbmeta.img" to h), m)
    }

    @Test fun copyOkAndExactBytes() {
        val out = ByteArrayOutputStream()
        val r = Exporter.copyVerified("boot_a.img", ByteArrayInputStream(data), out, sha(data), data.size.toLong())
        assertEquals(Exporter.Result.Ok(data.size.toLong(), sha(data)), r)
        assertTrue(out.toByteArray().contentEquals(data))
    }

    @Test fun copyMismatchSizeAndNoSum() {
        val wrong = "0".repeat(64)
        assertTrue(Exporter.copyVerified("x", ByteArrayInputStream(data), ByteArrayOutputStream(), wrong, data.size.toLong()) is Exporter.Result.Mismatch)
        assertTrue(Exporter.copyVerified("x", ByteArrayInputStream(data), ByteArrayOutputStream(), sha(data), 1) is Exporter.Result.SizeMismatch)
        val out = ByteArrayOutputStream()
        assertTrue(Exporter.copyVerified("x", ByteArrayInputStream(data), out, null, data.size.toLong()) is Exporter.Result.NoSum)
        assertEquals(0, out.size()) // nothing copied without a SUMS line
    }

    @Test fun fat32Warning() {
        assertFalse(Exporter.needsFat32Warning((1L shl 32) - 1))
        assertTrue(Exporter.needsFat32Warning(1L shl 32))
    }

    @Test fun exportUsesRwtAndNoMediaStore() {
        val src = File("src/main/kotlin/io/github/seuj09/spdhost/dump/ExportRepo.kt").readText()
        assertTrue(src.contains("openOutputStream(doc, \"rwt\")"))
        assertTrue(src.contains("OPEN_DOCUMENT_TREE") || src.contains("DocumentsContract"))
    }

    @Test fun cleanAbsPath() {
        assertTrue(EngineArgv.isCleanAbsPath("/data/x/dumps/1/meta"))
        for (p in listOf("/a/..", "/a/../b", "/a/./b", "/a/.", "rel/x", "/.."))
            assertFalse(p, EngineArgv.isCleanAbsPath(p))
    }

    @Test fun partNameRule() {
        assertTrue(EngineArgv.partNameOk("boot_a"))
        assertFalse(EngineArgv.partNameOk("l_modem-x"))
        assertFalse(EngineArgv.partNameOk("odm.img"))
        assertFalse(EngineArgv.partNameOk("userdata"))
    }

    @Test fun leftoversListed() {
        val d = Files.createTempDirectory("dump").toFile()
        listOf("boot_a.img", "boot_b.img.partial", "vbmeta.img.unverified").forEach { File(d, it).writeText("x") }
        assertEquals(listOf("boot_b.img.partial", "vbmeta.img.unverified"), DumpRepo.leftovers(d))
        d.deleteRecursively()
    }

    @Test fun cancelledCopyReturnsCancelled() {
        var calls = 0
        val out = ByteArrayOutputStream()
        val r = Exporter.copyVerified("x", ByteArrayInputStream(data), out, sha(data), data.size.toLong()) { ++calls > 1 }
        assertTrue(r is Exporter.Result.Cancelled)
        assertEquals((1 shl 20).toLong(), (r as Exporter.Result.Cancelled).bytes) // stopped after one buffer
        assertTrue(Exporter.copyVerified("x", ByteArrayInputStream(data), ByteArrayOutputStream(), sha(data), data.size.toLong()) { true }
            is Exporter.Result.Cancelled)
    }

    @Test fun filteredSumsAndFlatNames() {
        val h = sha(data)
        val text = Exporter.sumsFor(listOf("boot_a.img" to h))
        assertEquals("$h  boot_a.img\n", text)
        assertEquals(mapOf("boot_a.img" to h), Sums.parse(text)) // round-trips through the core format
        assertTrue(Exporter.flatNameOk("boot_a.img"))
        assertFalse(Exporter.flatNameOk("sub/boot_a.img"))
        assertFalse(Exporter.flatNameOk(".."))
    }

    @Test fun exportRepoFailurePaths() {
        val src = File("src/main/kotlin/io/github/seuj09/spdhost/dump/ExportRepo.kt").readText()
        assertFalse("no 'w' fallback", Regex("openOutputStream\\([^)]*\"w\"\\)").containsMatchIn(src))
        assertTrue(src.contains("target could NOT be deleted"))
        assertTrue(src.contains("fun cancel()"))
    }
}
