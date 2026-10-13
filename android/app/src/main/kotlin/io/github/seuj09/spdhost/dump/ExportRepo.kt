package io.github.seuj09.spdhost.dump

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.File
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class ExportState(val running: Boolean = false, val cancelling: Boolean = false, val lines: List<String> = emptyList())

/**
 * P1-6: export a dump folder through the Storage Access Framework (rules in
 * [ExportJob]). The user picks a tree (ACTION_OPEN_DOCUMENT_TREE); we create
 * <tree>/<folder name>/ and one document per table-filtered image. The grant
 * is one-shot: it is not persisted, and every export asks for the folder
 * again. No MediaStore, no storage permission, nothing goes to the device.
 */
class ExportRepo(private val ctx: Context) {
    private val _state = MutableStateFlow(ExportState())
    val state: StateFlow<ExportState> = _state.asStateFlow()
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "export").apply { isDaemon = true } }
    private val cancel = AtomicBoolean(false)

    private fun log(s: String) = _state.update { it.copy(lines = (it.lines + s).takeLast(MAX_LINES)) }

    fun cancel() { cancel.set(true); _state.update { if (it.running) it.copy(cancelling = true) else it } }

    fun export(tree: Uri, dir: File, images: List<ImageFile>) {
        if (_state.value.running) return
        cancel.set(false)
        _state.value = ExportState(running = true)
        worker.execute {
            try { ExportJob(SafSink(ctx.contentResolver, tree), ::log) { cancel.get() }.run(dir, images) }
            catch (e: SecurityException) { log(LOST_GRANT + " (${e.message})") }
            catch (t: Throwable) { log("export failed: ${t.message}") }
            finally { _state.update { it.copy(running = false, cancelling = false) } }
        }
    }

    companion object {
        const val MAX_LINES = 200
        /** #39 S2: the grant is one-shot, so the fix is to pick the folder again. */
        const val LOST_GRANT = "export stopped: access to the picked folder was lost; tap Export again and pick the folder"
    }
}

/** The SAF tree the user picked; every stream is opened "rwt". */
class SafSink(private val cr: ContentResolver, private val tree: Uri) : DocSink<Uri> {
    override fun root(): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
    override fun createDir(parent: Uri, name: String): Uri? =
        DocumentsContract.createDocument(cr, parent, DocumentsContract.Document.MIME_TYPE_DIR, name)
    override fun createFile(parent: Uri, mime: String, name: String): Uri? = DocumentsContract.createDocument(cr, parent, mime, name)
    override fun displayName(doc: Uri): String? = runCatching {
        cr.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull()
    override fun openRwt(doc: Uri): OutputStream? = cr.openOutputStream(doc, "rwt")
    override fun delete(doc: Uri): Boolean = DocumentsContract.deleteDocument(cr, doc)
}
