package io.github.seuj09.spdhost.dump

import android.content.Context
import io.github.seuj09.spdhost.engine.CoreEnv
import io.github.seuj09.spdhost.engine.CoreRunner
import io.github.seuj09.spdhost.engine.SessionArgs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class DumpState(
    val dir: File? = null,
    val table: PartsTable? = null,
    val images: ImagesList? = null,
    val message: String? = null,
)

/**
 * The dump folder (P1-5): getExternalFilesDir(null)/dumps/<time>, app-owned,
 * no storage permission and no MediaStore. Reads the saved table
 * (meta/partition_list.txt) and runs the offline `images list DIR --json`.
 */
class DumpRepo(private val ctx: Context) {
    private val _state = MutableStateFlow(DumpState())
    val state: StateFlow<DumpState> = _state.asStateFlow()

    val base: File? get() = ctx.getExternalFilesDir(null)?.let { File(it, "dumps") }

    /** The current folder, created on first use. */
    fun dir(): File? {
        _state.value.dir?.let { return it }
        return newFolder()
    }

    fun newFolder(): File? {
        val b = base ?: run { _state.value = DumpState(message = "app external storage is not available"); return null }
        val d = File(b, SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()))
        if (!d.isDirectory && !d.mkdirs()) { _state.value = DumpState(message = "cannot create $d"); return null }
        _state.value = DumpState(dir = d, message = "Folder ${d.name}")
        return d
    }

    fun refresh() = Thread {
        val d = _state.value.dir ?: return@Thread
        val pt = File(SessionArgs.partsFile(d.absolutePath))
        val table = if (pt.isFile) runCatching { PartsTable.parse(pt.readText()) }.getOrNull() else null
        val (rc, out) = run(listOf(CoreRunner.corePath(ctx).path, "images", "list", d.absolutePath, "--json"))
        val imgs = if (rc == 0) runCatching { ImagesList.parse(out) }.getOrNull() else null
        _state.value = _state.value.copy(table = table, images = imgs,
            message = if (rc == 0 && imgs == null) "images list: unreadable JSON" else _state.value.message)
    }.apply { name = "dumps"; isDaemon = true; start() }

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
