package io.github.seuj09.spdhost.dump

import android.content.Context
import io.github.seuj09.spdhost.engine.CoreEnv
import io.github.seuj09.spdhost.engine.CoreRunner
import io.github.seuj09.spdhost.engine.SessionArgs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.concurrent.Executors
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class DumpState(
    val dir: File? = null,
    val table: PartsTable? = null,
    val images: ImagesList? = null,
    val message: String? = null,
    /** NAME.img.partial / NAME.img.unverified left by a cancelled or failed dump. */
    val partials: List<String> = emptyList(),
)

/**
 * The dump folder (P1-5): getExternalFilesDir(null)/dumps/<time>, app-owned,
 * no storage permission and no MediaStore. Reads the saved table
 * (meta/partition_list.txt) and runs the offline `images list DIR --json`.
 */
class DumpRepo(private val ctx: Context) {
    private val _state = MutableStateFlow(DumpState())
    // All state writes go through update{} (P1-5 review note 4); refresh work
    // runs on one worker so two refreshes never interleave.
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "dumps").apply { isDaemon = true } }
    val state: StateFlow<DumpState> = _state.asStateFlow()

    val base: File? get() = ctx.getExternalFilesDir(null)?.let { File(it, "dumps") }

    /** The current folder, created on first use. */
    fun dir(): File? {
        _state.value.dir?.let { return it }
        return newFolder()
    }

    fun newFolder(): File? {
        val b = base ?: run { _state.update { DumpState(message = "app external storage is not available") }; return null }
        val d = File(b, SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()))
        if (!d.isDirectory && !d.mkdirs()) { _state.update { DumpState(message = "cannot create $d") }; return null }
        _state.update { DumpState(dir = d, message = "Folder ${d.name}") }
        return d
    }

    fun refresh() { worker.execute { refreshNow() } }

    private fun refreshNow() {
        val d = _state.value.dir ?: return
        val pt = File(SessionArgs.partsFile(d.absolutePath))
        val table = if (pt.isFile) runCatching { PartsTable.parse(pt.readText()) }.getOrNull() else null
        val (rc, out) = run(listOf(CoreRunner.corePath(ctx).path, "images", "list", d.absolutePath, "--json"))
        val imgs = if (rc == 0) runCatching { ImagesList.parse(out) }.getOrNull() else null
        val partials = leftovers(d)
        _state.update { s ->
            if (s.dir != d) s // the folder changed meanwhile: drop this result
            else s.copy(table = table, images = imgs, partials = partials,
                message = if (rc == 0 && imgs == null) "images list: unreadable JSON" else s.message)
        }
    }

    /** Deletes the *.partial files of the current folder (app-private storage only). */
    fun deletePartials() {
        worker.execute {
            val d = _state.value.dir ?: return@execute
            val gone = leftovers(d).filter { it.endsWith(".partial") }.count { File(d, it).delete() }
            _state.update { it.copy(message = "deleted $gone partial file(s)") }
            refreshNow()
        }
    }

    companion object {
        /** Unfinished dump files: NAME.img.partial (failed/cancelled) and NAME.img.unverified. */
        fun leftovers(d: File): List<String> =
            d.listFiles()?.filter { it.isFile && (it.name.endsWith(".partial") || it.name.endsWith(".unverified")) }
                ?.map { it.name }?.sorted().orEmpty()
    }

    // Process.waitFor(timeout) is API 26; minSdk is 24, so wait on a thread.
    private fun run(argv: List<String>): Pair<Int?, String> = runCatching {
        val pb = ProcessBuilder(argv).redirectErrorStream(false)
        CoreEnv.sanitize(pb.environment())
        val p = pb.start()
        p.outputStream.close()
        val out = StringBuffer()
        val r = Thread { runCatching { p.inputStream.bufferedReader().use { out.append(it.readText()) } } }.apply { isDaemon = true; start() }
        Thread { runCatching { p.errorStream.readBytes() } }.apply { isDaemon = true; start() }
        var rc: Int? = null
        val w = Thread { rc = runCatching { p.waitFor() }.getOrNull() }.apply { isDaemon = true; start() }
        w.join(10_000)
        if (w.isAlive) p.destroy()
        r.join(1_000)
        rc to out.toString()
    }.getOrElse { null to "" }
}
