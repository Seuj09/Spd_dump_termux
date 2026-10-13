package io.github.seuj09.spdhost.loader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** P1-4: pinned pack import, loaders check verdicts, absolute --index. */
class LoaderTest {
    @get:Rule val tmp = TemporaryFolder()

    private val repoFdl = File("../../no-root/fdl")
    private fun sha(b: ByteArray) = LoaderPack.sha256Hex(MessageDigest.getInstance("SHA-256").digest(b))

    @Test fun indexPinMatchesTheRepo() {
        assertEquals("bump LoaderPin.INDEX_SHA256", sha(File(repoFdl, "index").readBytes()), LoaderPin.INDEX_SHA256)
    }

    @Test fun packPinMatchesFdlPackSh() {
        val script = File("../../no-root/scripts/fdl-pack.sh")
        val ok = runCatching { ProcessBuilder("python3", "--version").start().waitFor() == 0 }.getOrDefault(false)
        assumeTrue("python3 needed to run fdl-pack.sh", ok)
        val out = tmp.newFolder("pack")
        val p = ProcessBuilder("bash", script.path, out.path, "test").redirectErrorStream(true).start()
        val log = p.inputStream.bufferedReader().readText()
        assertEquals(log, 0, p.waitFor())
        val zip = File(out, "fdl-pack-test.zip")
        assertEquals("bump LoaderPin.PACK_SHA256", sha(zip.readBytes()), LoaderPin.PACK_SHA256)
        // The real pack imports with the real pins.
        val ix = zip.inputStream().use { LoaderPack.import(it, tmp.newFolder("root")) }
        assertEquals(20, ix.pairs.size)
        assertTrue(ix.pairs.any { it.id == "ums9230/infinix/hot12pro" })
    }

    private val good = mapOf("a/fdl1.bin" to "one".toByteArray(), "a/fdl2.bin" to "two".toByteArray())
    private fun index(files: Map<String, ByteArray>) = buildString {
        append("spdhost-fdl-index 1\nsoc ums9230 fdl1=0x65000800 fdl2=0x9efffe00 stub=0x65015f08 stub_alt=0x65015f48\n")
        files.forEach { (k, v) -> append("file ${sha(v)} fdl1 ums9230 0x65000800 $k\n") }
        append("pair ums9230 m a/fdl1.bin a/fdl2.bin\nend\n")
    }.toByteArray()
    private fun zip(entries: Map<String, ByteArray>): ByteArray = ByteArrayOutputStream().also { bo ->
        ZipOutputStream(bo).use { z -> entries.forEach { (k, v) -> z.putNextEntry(ZipEntry(k)); z.write(v); z.closeEntry() } }
    }.toByteArray()
    private fun pack(files: Map<String, ByteArray> = good, idx: ByteArray = index(files), extra: Map<String, ByteArray> = emptyMap()) =
        zip(mapOf("fdl/index" to idx) + files.mapKeys { "fdl/${it.key}" } + extra)
    private fun imp(z: ByteArray, root: File, packPin: String = sha(z), indexPin: String = sha(index(good))) =
        LoaderPack.import(ByteArrayInputStream(z), root, packPin, indexPin)
    private fun refused(f: () -> Unit): String = try { f(); "" } catch (e: LoaderPack.Refused) { e.message!! }

    @Test fun goodPackInstalls() {
        val root = tmp.newFolder()
        val ix = imp(pack(), root)
        assertEquals(listOf(LoaderPair("ums9230", "m", "a/fdl1.bin", "a/fdl2.bin")), ix.pairs)
        assertTrue(File(root, "fdl/a/fdl1.bin").isFile)
        assertFalse(File(root, ".staging").exists())
        assertEquals(ix, LoaderPack.installed(root, sha(index(good))))
        assertNull(LoaderPack.installed(root, "0".repeat(64)))
    }

    @Test fun refusalsKeepTheInstalledPack() {
        val root = tmp.newFolder()
        imp(pack(), root)
        val z = pack()
        assertTrue(refused { imp(z, root, packPin = "0".repeat(64)) }.contains("pack sha256"))
        assertTrue(refused { imp(z, root, indexPin = "0".repeat(64)) }.contains("fdl/index sha256"))
        val tampered = good + ("a/fdl2.bin" to "evil".toByteArray())
        assertTrue(refused { imp(pack(tampered, index(good)), root) }.contains("does not match"))
        assertTrue(refused { imp(pack(extra = mapOf("fdl/a/x.bin" to byteArrayOf(1))), root) }.contains("not in fdl/index"))
        assertTrue(refused { imp(pack(extra = mapOf("evil.sh" to byteArrayOf(1))), root) }.contains("outside fdl/"))
        assertTrue(refused { imp(pack(extra = mapOf("fdl/../x" to byteArrayOf(1))), root) }.contains("unsafe"))
        assertTrue(refused { imp(zip(mapOf("fdl/index" to index(good), "fdl/a/fdl1.bin" to good.getValue("a/fdl1.bin"))), root) }.contains("missing"))
        assertTrue(refused { imp(zip(mapOf("fdl/x" to byteArrayOf(1))), root) }.contains("no fdl/index"))
        assertEquals("one", File(root, "fdl/a/fdl1.bin").readText())
        assertFalse(File(root, ".staging").exists())
        assertFalse(File(root.parentFile, "x").exists())
    }

    @Test fun wrongPinNeverParsesOrStages() {
        val root = tmp.newFolder()
        // Not even a zip: a wrong pin must refuse on the hash alone.
        assertTrue(refused { LoaderPack.import(ByteArrayInputStream(byteArrayOf(1, 2, 3)), root, "0".repeat(64), "0".repeat(64)) }.contains("pack sha256"))
        assertTrue(refused { imp(pack(), root, packPin = "0".repeat(64)) }.contains("pack sha256"))
        assertFalse(File(root, ".staging").exists())
        assertFalse(File(root, ".incoming.zip.tmp").exists())
        assertFalse(File(root, "fdl").exists())
    }

    @Test fun oversizePackRefused() {
        val root = tmp.newFolder()
        val big = object : java.io.InputStream() {
            var n = 0L
            override fun read() = if (n++ > LoaderPack.MAX_PACK_BYTES) -1 else 0
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (n > LoaderPack.MAX_PACK_BYTES) return -1
                n += len; return len
            }
        }
        assertTrue(refused { LoaderPack.import(big, root, "0".repeat(64), "0".repeat(64)) }.contains("larger than"))
        assertFalse(File(root, ".staging").exists())
        assertFalse(File(root, ".incoming.zip.tmp").exists())
    }

    @Test fun directoryEntriesCountTowardTheLimit() {
        val dirs = ByteArrayOutputStream().also { bo ->
            ZipOutputStream(bo).use { z -> repeat(LoaderPack.MAX_ENTRIES + 1) { z.putNextEntry(ZipEntry("fdl/d$it/")); z.closeEntry() } }
        }.toByteArray()
        assertTrue(refused { imp(dirs, tmp.newFolder()) }.contains("more than"))
    }

    @Test fun leftoverOldIsRestored() {
        val root = tmp.newFolder()
        imp(pack(), root)
        assertTrue(File(root, "fdl").renameTo(File(root, ".old")))
        assertEquals(sha(index(good)).let { LoaderPack.installed(root, it) }?.pairs?.size, 1)
        assertTrue(File(root, "fdl/a/fdl1.bin").isFile)
    }

    private val pair = LoaderPair("ums9230", "infinix", "ums9230/infinix/fdl1-dl.bin", "ums9230/infinix/fdl2-dl.bin")
    private val okOut = listOf(
        "loaders_format=1", "index=/data/user/0/x/files/loaders/fdl/index", "fdl1_id=index", "fdl2_id=index",
        "soc=ums9230", "exec=0x65015f08", "stub_id=index", "pair=ums9230/infinix", "verdict=ok", "end",
    ).joinToString("\n")

    @Test fun checkOk() = assertTrue(LoadersCheck.judge(0, okOut, pair).ok)

    @Test fun checkRefusals() {
        fun bad(out: String, rc: Int? = 0) = assertFalse(out, LoadersCheck.judge(rc, out, pair).ok)
        bad(okOut.replace("verdict=ok", "warning=only one of FDL1/FDL2 is a shipped loader\nverdict=ok"))
        bad(okOut.replace("stub_id=index", "stub_id=unindexed"))
        bad(okOut.replace("stub_id=index\n", ""))
        bad(okOut.replace("fdl2_id=index", "fdl2_id=unknown"))
        bad(okOut.replace("pair=ums9230/infinix", "pair=mixed"))
        bad(okOut.replace("verdict=ok", "verdict=refuse"))
        bad(okOut.replace("\nend", ""))
        bad(okOut, rc = 1)
        bad(okOut, rc = null)
    }

    @Test fun argvAlwaysHasAbsoluteIndex() {
        val ix = LoaderIndex(mapOf("ums9230" to SocAddrs("ums9230", "0x65000800", "0x9efffe00")), emptyMap(), listOf(pair))
        val a = LoadersCheck.argvFor("/lib/libspdhost.so", "/data/x/files/loaders", ix, pair)
        assertEquals(listOf("/lib/libspdhost.so", "loaders", "check", "--index", "/data/x/files/loaders/fdl/index",
            "--soc", "ums9230", "/data/x/files/loaders/fdl/ums9230/infinix/fdl1-dl.bin", "0x65000800",
            "/data/x/files/loaders/fdl/ums9230/infinix/fdl2-dl.bin", "0x9efffe00"), a)
        assertTrue(runCatching { LoadersCheck.argvFor("/c", "rel/root", ix, pair) }.isFailure)
    }

    @Test fun noLoaderIsBundledInTheApk() {
        val bins = File("src/main").walkTopDown()
            .filter { it.isFile && (it.extension == "bin" || it.name.startsWith("fdl") || it.name == "index") }.toList()
        assertEquals(emptyList<File>(), bins)
    }
}
