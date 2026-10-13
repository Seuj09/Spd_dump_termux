package io.github.seuj09.spdhost.dump

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.File
import java.util.concurrent.Executors

data class ExportState(val running: Boolean = false, val lines: List<String> = emptyList())

/**
 * P1-6: export a dump folder through the Storage Access Framework. The user
 * picks a tree (ACTION_OPEN_DOCUMENT_TREE); we create <tree>/<folder name>/,
 * then one document per table-filtered image (from `images list --json`),
 * each opened with mode "rwt" and verified against meta/SHA256SUMS while it
 * is copied. A mismatch deletes that document. meta/SHA256SUMS and
 * meta/partition_list.txt are copied too so the export can be re-verified.
 * No MediaStore, no storage permission, nothing is sent to the device.
 */
class ExportRepo(private val ctx: Context) {
    private val _state = MutableStateFlow(ExportState())
    val state: StateFlow<ExportState> = _state.asStateFlow()
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "export").apply { isDaemon = true } }

    private fun log(s: String) = _state.update { it.copy(lines = it.lines + s) }

    fun export(tree: Uri, dir: File, images: List<ImageFile>) {
        if (_state.value.running) return
        _state.value = ExportState(running = true)
        worker.execute {
            try { run(tree, dir, images) } catch (t: Throwable) { log("export failed: ${t.message}") }
            finally { _state.update { it.copy(running = false) } }
        }
    }

    private fun run(tree: Uri, dir: File, images: List<ImageFile>) {
        val cr = ctx.contentResolver
        val sumsFile = File(dir, "meta/SHA256SUMS").takeIf { it.isFile } ?: File(dir, "SHA256SUMS")
        val sums = if (sumsFile.isFile) Sums.parse(sumsFile.readText()) else emptyMap()
        if (sums.isEmpty()) { log("no meta/SHA256SUMS: nothing can be verified, export refused"); return }
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val out = DocumentsContract.createDocument(cr, root, DocumentsContract.Document.MIME_TYPE_DIR, dir.name)
            ?: run { log("cannot create folder ${dir.name} in the picked location"); return }
        var ok = 0; var bad = 0
        for (img in images) {
            val src = File(dir, img.file)
            if (!src.isFile || !src.canonicalPath.startsWith(dir.canonicalPath + File.separator)) { log("skip ${img.file}: not in the folder"); bad++; continue }
            if (Exporter.needsFat32Warning(src.length())) log("WARNING ${img.file}: ${src.length() shr 20} MiB is over the FAT32 4 GiB limit; a FAT32 card will fail")
            val want = sums[img.file]
            if (want == null) { log("skip ${img.file}: no SHA256SUMS line (unverified)"); bad++; continue }
            val doc = DocumentsContract.createDocument(cr, out, "application/octet-stream", File(img.file).name)
                ?: run { log("cannot create ${img.file}"); bad++; null } ?: continue
            val r = cr.openOutputStream(doc, "rwt")?.use { os ->
                src.inputStream().use { Exporter.copyVerified(img.file, it, os, want, src.length()) }
            }
            when (r) {
                is Exporter.Result.Ok -> { ok++; log("ok   ${img.file} ${r.bytes shr 20} MiB sha256 ${r.sha256.take(12)}") }
                null -> { bad++; log("FAIL ${img.file}: cannot open the target") }
                else -> { bad++; log("FAIL ${img.file}: $r (target deleted)"); runCatching { DocumentsContract.deleteDocument(cr, doc) } }
            }
        }
        val meta = DocumentsContract.createDocument(cr, out, DocumentsContract.Document.MIME_TYPE_DIR, "meta")
        if (meta != null) for (n in listOf("SHA256SUMS", "partition_list.txt")) {
            val f = File(dir, "meta/$n").takeIf { it.isFile } ?: continue
            val d = DocumentsContract.createDocument(cr, meta, "text/plain", n) ?: continue
            cr.openOutputStream(d, "rwt")?.use { os -> f.inputStream().use { it.copyTo(os) } }
        }
        log("export done: $ok verified, $bad failed or skipped")
    }
}
