package io.github.seuj09.spdhost.dump

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class ExportState(val running: Boolean = false, val lines: List<String> = emptyList())

/**
 * P1-6: export a dump folder through the Storage Access Framework. The user
 * picks a tree (ACTION_OPEN_DOCUMENT_TREE); we create <tree>/<folder name>/,
 * then one document per table-filtered image (from `images list --json`),
 * each opened with mode "rwt" only (never a "w" fallback) and verified
 * against SHA256SUMS while it is copied.
 *
 * Per file: any throw (I/O, disk full, FAT32 4 GiB, provider rejecting "rwt"),
 * a null stream, a mismatch, a renamed document or a cancel deletes that
 * document; a failed delete is logged with its URI. A lost grant
 * (SecurityException) or a cancel stops the remaining files; other failures
 * move on to the next file. The grant is one-shot: it is not persisted, and
 * every export asks for the folder again.
 *
 * meta/ gets a SHA256SUMS listing only the files that were exported and
 * verified (also for flat-layout dumps), plus partition_list.txt, both
 * hash-checked. No MediaStore, no storage permission, nothing goes to the device.
 */
class ExportRepo(private val ctx: Context) {
    private val _state = MutableStateFlow(ExportState())
    val state: StateFlow<ExportState> = _state.asStateFlow()
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "export").apply { isDaemon = true } }
    private val cancel = AtomicBoolean(false)

    private fun log(s: String) = _state.update { it.copy(lines = (it.lines + s).takeLast(MAX_LINES)) }

    fun cancel() { cancel.set(true) }

    fun export(tree: Uri, dir: File, images: List<ImageFile>) {
        if (_state.value.running) return
        cancel.set(false)
        _state.value = ExportState(running = true)
        worker.execute {
            try { run(tree, dir, images) }
            catch (e: SecurityException) { log("export stopped: access to the picked folder was lost; pick it again (${e.message})") }
            catch (t: Throwable) { log("export failed: ${t.message}") }
            finally { _state.update { it.copy(running = false) } }
        }
    }

    private class Abort(msg: String) : Exception(msg)

    private fun displayName(cr: ContentResolver, doc: Uri): String? = runCatching {
        cr.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull()

    private fun drop(cr: ContentResolver, doc: Uri, what: String, why: String) {
        val gone = runCatching { DocumentsContract.deleteDocument(cr, doc) }.getOrDefault(false)
        log(if (gone) "FAIL $what: $why (target deleted)" else "FAIL $what: $why; target could NOT be deleted: $doc")
    }

    /**
     * Creates [name] in [parent], checks the provider kept the name, opens it
     * "rwt" and copies [src] verified against [want]. Returns true only on Ok.
     */
    private fun put(cr: ContentResolver, parent: Uri, name: String, mime: String, size: Long, want: String, src: () -> InputStream): Boolean {
        val doc = DocumentsContract.createDocument(cr, parent, mime, name)
            ?: run { log("FAIL $name: the provider did not create it"); return false }
        try {
            val real = displayName(cr, doc)
            if (real != null && real != name) { drop(cr, doc, name, "provider named it '$real', which would not match SHA256SUMS"); return false }
            val r = cr.openOutputStream(doc, "rwt")?.use { os -> src().use { Exporter.copyVerified(name, it, os, want, size) { cancel.get() } } }
            when (r) {
                is Exporter.Result.Ok -> { log("ok   $name ${r.bytes shr 20} MiB sha256 ${r.sha256.take(12)}"); return true }
                null -> drop(cr, doc, name, "cannot open the target with 'rwt'")
                is Exporter.Result.Cancelled -> { drop(cr, doc, name, "cancelled after ${r.bytes shr 20} MiB"); throw Abort("cancelled") }
                else -> drop(cr, doc, name, r.toString())
            }
        } catch (e: SecurityException) {
            drop(cr, doc, name, "access lost"); throw e
        } catch (e: Abort) {
            throw e
        } catch (e: Exception) {
            val big = if (Exporter.needsFat32Warning(size)) " (file is over 4 GiB: FAT32?)" else ""
            drop(cr, doc, name, "${e.javaClass.simpleName}: ${e.message}$big")
        }
        return false
    }

    private fun run(tree: Uri, dir: File, images: List<ImageFile>) {
        val cr = ctx.contentResolver
        val sumsFile = File(dir, "meta/SHA256SUMS").takeIf { it.isFile } ?: File(dir, "SHA256SUMS")
        val sums = if (sumsFile.isFile) Sums.parse(sumsFile.readText()) else emptyMap()
        if (sums.isEmpty()) { log("no SHA256SUMS: nothing can be verified, export refused"); return }
        log("verifying against ${sumsFile.relativeTo(dir)}")
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val out = DocumentsContract.createDocument(cr, root, DocumentsContract.Document.MIME_TYPE_DIR, dir.name)
            ?: run { log("cannot create folder ${dir.name} in the picked location"); return }
        val outName = displayName(cr, out) ?: dir.name
        log("exporting into '$outName'" + if (outName != dir.name) " (the provider renamed ${dir.name})" else "")
        val done = ArrayList<Pair<String, String>>()
        var bad = 0
        try {
            for (img in images) {
                if (cancel.get()) throw Abort("cancelled")
                if (!Exporter.flatNameOk(img.file)) { log("skip ${img.file}: nested or bad name"); bad++; continue }
                val src = File(dir, img.file)
                if (!src.isFile || !src.canonicalPath.startsWith(dir.canonicalPath + File.separator)) { log("skip ${img.file}: not in the folder"); bad++; continue }
                if (Exporter.needsFat32Warning(src.length())) log("WARNING ${img.file}: ${src.length() shr 20} MiB is over the FAT32 4 GiB limit; a FAT32 target will fail")
                val want = sums[img.file] ?: run { log("skip ${img.file}: no SHA256SUMS line (unverified)"); bad++; null } ?: continue
                if (put(cr, out, img.file, "application/octet-stream", src.length(), want) { src.inputStream() }) done += img.file to want else bad++
            }
        } catch (e: Abort) {
            log("export cancelled: remaining files skipped")
        }
        if (!cancel.get() && done.isNotEmpty()) {
            val meta = DocumentsContract.createDocument(cr, out, DocumentsContract.Document.MIME_TYPE_DIR, "meta")
            if (meta == null) log("FAIL meta/: cannot create; the export has no SHA256SUMS")
            else try {
                val text = Exporter.sumsFor(done).toByteArray()
                put(cr, meta, "SHA256SUMS", "text/plain", text.size.toLong(),
                    Exporter.hex(java.security.MessageDigest.getInstance("SHA-256").digest(text))) { ByteArrayInputStream(text) }
                File(dir, "meta/partition_list.txt").takeIf { it.isFile }?.let { pl ->
                    put(cr, meta, "partition_list.txt", "text/plain", pl.length(), Exporter.sha256(pl)) { pl.inputStream() }
                }
            } catch (e: Abort) { log("export cancelled during meta/") }
        }
        log("export done: ${done.size} verified, $bad failed or skipped; meta/SHA256SUMS lists only the verified files")
    }

    companion object { const val MAX_LINES = 200 }
}
