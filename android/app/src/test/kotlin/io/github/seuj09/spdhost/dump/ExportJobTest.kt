package io.github.seuj09.spdhost.dump

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest

/** #39 S4: ExportJob against a fake document provider; failures delete the destination. */
class ExportJobTest {
    /** In-memory provider. Handles are paths like "/root/dump/boot_a.img". */
    class FakeSink : DocSink<String> {
        val files = LinkedHashMap<String, ByteArrayOutputStream>()
        val dirs = linkedSetOf("/root")
        val modes = ArrayList<String>()
        var failWriteOn: String? = null       // throw IOException mid-copy
        var failCreateOn: String? = null      // createDocument throws
        var nullStreamOn: String? = null
        var renameOn: String? = null
        var refuseDelete = false
        var lostGrantOn: String? = null
        override fun root() = "/root"
        override fun createDir(parent: String, name: String) = "$parent/$name".also { dirs += it }
        override fun createFile(parent: String, mime: String, name: String): String? {
            if (name == failCreateOn) throw IllegalStateException("provider said no")
            if (name == lostGrantOn) throw SecurityException("grant revoked")
            return "$parent/$name".also { files[it] = ByteArrayOutputStream() }
        }
        override fun displayName(doc: String) = doc.substringAfterLast('/').let { if (it == renameOn) "$it (1)" else it }
        override fun openRwt(doc: String): OutputStream? {
            modes += "rwt"
            val n = doc.substringAfterLast('/')
            if (n == nullStreamOn) return null
            val buf = files[doc]!!
            return object : OutputStream() {
                var count = 0
                override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
                override fun write(b: ByteArray, off: Int, len: Int) {
                    if (n == failWriteOn && count + len > 1000) throw IOException("ENOSPC")
                    count += len; buf.write(b, off, len)
                }
            }
        }
        override fun delete(doc: String) = if (refuseDelete) false else files.remove(doc) != null
    }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private fun dump(vararg names: String): Pair<File, List<ImageFile>> {
        val d = Files.createTempDirectory("dump").toFile()
        File(d, "meta").mkdirs()
        val sums = StringBuilder()
        val imgs = names.map { n ->
            val b = ByteArray(5000) { (it + n.length).toByte() }
            File(d, "$n.img").writeBytes(b)
            sums.append("${sha(b)}  $n.img\n")
            ImageFile(n, "$n.img", b.size.toLong(), null, sha(b))
        }
        File(d, "meta/SHA256SUMS").writeText(sums.toString())
        File(d, "meta/partition_list.txt").writeText("boot_a 5\n")
        return d to imgs
    }

    private fun run(s: FakeSink, d: File, imgs: List<ImageFile>, cancelAt: Int = Int.MAX_VALUE): List<String> {
        val log = ArrayList<String>()
        var checks = 0
        ExportJob(s, { log += it }) { ++checks > cancelAt }.run(d, imgs)
        return log
    }

    @Test fun allOkAndFilteredSums() {
        val (d, imgs) = dump("boot_a", "vbmeta_a")
        val s = FakeSink()
        run(s, d, imgs)
        val root = "/root/${d.name}"
        assertEquals(setOf("$root/boot_a.img", "$root/vbmeta_a.img", "$root/meta/SHA256SUMS", "$root/meta/partition_list.txt"), s.files.keys)
        assertTrue(s.modes.all { it == "rwt" })
        assertEquals(Sums.parse(File(d, "meta/SHA256SUMS").readText()), Sums.parse(s.files["$root/meta/SHA256SUMS"]!!.toString()))
    }

    @Test fun failedCopyDeletesDestinationAndContinues() {
        val (d, imgs) = dump("boot_a", "vbmeta_a")
        val s = FakeSink().apply { failWriteOn = "boot_a.img" }
        val log = run(s, d, imgs)
        val root = "/root/${d.name}"
        assertFalse("partial boot_a.img must be deleted", "$root/boot_a.img" in s.files)
        assertTrue("$root/vbmeta_a.img" in s.files)
        assertTrue(log.any { it.startsWith("FAIL boot_a.img: IOException: ENOSPC") && it.endsWith("(target deleted)") })
        val exported = Sums.parse(s.files["$root/meta/SHA256SUMS"]!!.toString())
        assertEquals(setOf("vbmeta_a.img"), exported.keys) // only verified files listed
    }

    @Test fun nullStreamRenameAndCreateThrowFailOnlyThatFile() {
        val (d, imgs) = dump("a", "b", "c", "e")
        val s = FakeSink().apply { nullStreamOn = "a.img"; renameOn = "b.img"; failCreateOn = "c.img" }
        val log = run(s, d, imgs)
        val root = "/root/${d.name}"
        assertFalse("$root/a.img" in s.files); assertFalse("$root/b.img" in s.files); assertFalse("$root/c.img" in s.files)
        assertTrue("$root/e.img" in s.files) // S1: create throwing did not stop the export
        assertTrue(log.any { it.contains("FAIL c.img: the provider could not create it") })
        assertTrue(log.any { it.contains("export done: 1 verified, 3 failed") })
    }

    @Test fun failedDeleteIsLoggedHonestly() {
        val (d, imgs) = dump("boot_a")
        val s = FakeSink().apply { failWriteOn = "boot_a.img"; refuseDelete = true }
        val log = run(s, d, imgs)
        assertTrue(log.any { it.contains("target could NOT be deleted: /root/${d.name}/boot_a.img") })
        assertFalse(log.any { it.contains("(target deleted)") })
    }

    @Test fun cancelDeletesCurrentAndSkipsRest() {
        val (d, imgs) = dump("a", "b")
        val s = FakeSink()
        // check 1: loop guard for a; check 2: first copy buffer -> cancelled
        val log = run(s, d, imgs, cancelAt = 1)
        assertTrue(s.files.isEmpty())
        assertTrue(log.any { it.startsWith("FAIL a.img: cancelled") })
        assertTrue(log.any { it == "export cancelled: remaining files skipped" })
        assertFalse(log.any { it.contains("b.img") })
    }

    @Test fun lostGrantStopsTheExport() {
        val (d, imgs) = dump("a", "b")
        val s = FakeSink().apply { lostGrantOn = "a.img" }
        try { run(s, d, imgs); throw AssertionError("expected SecurityException") } catch (_: SecurityException) {}
        assertTrue(s.files.isEmpty())
        assertTrue(ExportRepo.LOST_GRANT.contains("tap Export again"))
    }
}
