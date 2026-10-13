package io.github.seuj09.spdhost.dump

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/**
 * Where an export writes: the SAF tree in the app ([SafSink]), a fake in tests.
 * [D] is the provider's document handle (a Uri for SAF).
 */
interface DocSink<D> {
    /** The picked tree's root folder. Throws SecurityException when the grant is gone. */
    fun root(): D
    fun createDir(parent: D, name: String): D?
    fun createFile(parent: D, mime: String, name: String): D?
    fun displayName(doc: D): String?
    /** Opened with mode "rwt" only; null when the provider gives no stream. */
    fun openRwt(doc: D): OutputStream?
    fun delete(doc: D): Boolean
}

/**
 * P1-6 export of one dump folder (pure JVM, so the failure paths are unit
 * tested against a fake provider). Rules:
 *  - each file is created, name-checked, opened "rwt" (never a "w" fallback)
 *    and verified against SHA256SUMS while copied, inside its own try/catch;
 *  - any throw (I/O, disk full, FAT32 4 GiB, provider rejecting "rwt"),
 *    a null stream, a mismatch, a rename or a cancel deletes that document;
 *    a failed delete is logged with the handle, never "(target deleted)";
 *  - a lost grant (SecurityException) or a cancel stops the remaining files;
 *    any other failure, including createDocument throwing, moves on;
 *  - meta/SHA256SUMS lists only the files exported and verified.
 */
class ExportJob<D>(
    private val sink: DocSink<D>,
    private val log: (String) -> Unit,
    private val cancelled: () -> Boolean,
) {
    class Abort(msg: String) : Exception(msg)

    private fun drop(doc: D, what: String, why: String) {
        val gone = runCatching { sink.delete(doc) }.getOrDefault(false)
        log(if (gone) "FAIL $what: $why (target deleted)" else "FAIL $what: $why; target could NOT be deleted: $doc")
    }

    /** One file; true only when copied and verified. Throws SecurityException / Abort to stop the export. */
    fun put(parent: D, name: String, mime: String, size: Long, want: String, src: () -> InputStream): Boolean {
        val doc = try {
            sink.createFile(parent, mime, name)
        } catch (e: SecurityException) {
            throw e
        } catch (e: Exception) { // #39 S1: a provider throwing on create only fails this file
            log("FAIL $name: the provider could not create it (${e.javaClass.simpleName}: ${e.message})"); return false
        } ?: run { log("FAIL $name: the provider did not create it"); return false }
        try {
            val real = sink.displayName(doc)
            if (real != null && real != name) { drop(doc, name, "provider named it '$real', which would not match SHA256SUMS"); return false }
            val r = sink.openRwt(doc)?.use { os -> src().use { Exporter.copyVerified(name, it, os, want, size, cancelled) } }
            when (r) {
                is Exporter.Result.Ok -> { log("ok   $name ${r.bytes shr 20} MiB sha256 ${r.sha256.take(12)}"); return true }
                null -> drop(doc, name, "cannot open the target with 'rwt'")
                is Exporter.Result.Cancelled -> { drop(doc, name, "cancelled after ${r.bytes shr 20} MiB"); throw Abort("cancelled") }
                else -> drop(doc, name, r.toString())
            }
        } catch (e: SecurityException) {
            drop(doc, name, "access lost"); throw e
        } catch (e: Abort) {
            throw e
        } catch (e: Exception) {
            val big = if (Exporter.needsFat32Warning(size)) " (file is over 4 GiB: FAT32?)" else ""
            drop(doc, name, "${e.javaClass.simpleName}: ${e.message}$big")
        }
        return false
    }

    fun run(dir: File, images: List<ImageFile>) {
        val sumsFile = File(dir, "meta/SHA256SUMS").takeIf { it.isFile } ?: File(dir, "SHA256SUMS")
        val sums = if (sumsFile.isFile) Sums.parse(sumsFile.readText()) else emptyMap()
        if (sums.isEmpty()) { log("no SHA256SUMS: nothing can be verified, export refused"); return }
        log("verifying against ${sumsFile.relativeTo(dir)}")
        val out = sink.createDir(sink.root(), dir.name)
            ?: run { log("cannot create folder ${dir.name} in the picked location"); return }
        val outName = sink.displayName(out) ?: dir.name
        log("exporting into '$outName'" + if (outName != dir.name) " (the provider renamed ${dir.name})" else "")
        val done = ArrayList<Pair<String, String>>()
        var bad = 0
        try {
            for (img in images) {
                if (cancelled()) throw Abort("cancelled")
                if (!Exporter.flatNameOk(img.file)) { log("skip ${img.file}: nested or bad name"); bad++; continue }
                val src = File(dir, img.file)
                if (!src.isFile || !src.canonicalPath.startsWith(dir.canonicalPath + File.separator)) { log("skip ${img.file}: not in the folder"); bad++; continue }
                if (Exporter.needsFat32Warning(src.length())) log("WARNING ${img.file}: ${src.length() shr 20} MiB is over the FAT32 4 GiB limit; a FAT32 target will fail")
                val want = sums[img.file] ?: run { log("skip ${img.file}: no SHA256SUMS line (unverified)"); bad++; null } ?: continue
                if (put(out, img.file, "application/octet-stream", src.length(), want) { src.inputStream() }) done += img.file to want else bad++
            }
        } catch (e: Abort) {
            log("export cancelled: remaining files skipped")
        }
        if (!cancelled() && done.isNotEmpty()) {
            val meta = runCatching { sink.createDir(out, "meta") }.getOrElse { if (it is SecurityException) throw it; null }
            if (meta == null) log("FAIL meta/: cannot create; the export has no SHA256SUMS")
            else try {
                val text = Exporter.sumsFor(done).toByteArray()
                put(meta, "SHA256SUMS", "text/plain", text.size.toLong(),
                    Exporter.hex(MessageDigest.getInstance("SHA-256").digest(text))) { ByteArrayInputStream(text) }
                File(dir, "meta/partition_list.txt").takeIf { it.isFile }?.let { pl ->
                    put(meta, "partition_list.txt", "text/plain", pl.length(), Exporter.sha256(pl)) { pl.inputStream() }
                }
            } catch (e: Abort) { log("export cancelled during meta/") }
        }
        log("export done: ${done.size} verified, $bad failed or skipped; meta/SHA256SUMS lists only the verified files")
    }
}
