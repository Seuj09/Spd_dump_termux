package io.github.seuj09.spdhost.loader

import android.content.Context
import android.net.Uri
import io.github.seuj09.spdhost.engine.CoreEnv
import io.github.seuj09.spdhost.engine.CoreRunner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

data class LoaderState(
    val busy: Boolean = false,
    val index: LoaderIndex? = null,
    val message: String? = null,
    val error: Boolean = false,
    /** The model the user picked and `loaders check` accepted; null = none. */
    val selected: LoaderPair? = null,
    val lastCheck: LoadersCheck.Verdict? = null,
)

/**
 * App-side loader pack (P1-4): lives in filesDir/loaders (app-private), is
 * imported from a SAF zip, and a model is only "selected" after a clean
 * `loaders check`. Nothing here talks to USB or writes to a phone.
 */
class LoaderRepo(private val ctx: Context) {
    val root: File get() = File(ctx.filesDir, "loaders")
    private val _state = MutableStateFlow(LoaderState())
    val state: StateFlow<LoaderState> = _state.asStateFlow()

    fun load() = bg {
        val ix = runCatching { LoaderPack.installed(root) }.getOrNull()
        _state.value = LoaderState(index = ix, message = if (ix == null) "No loader pack imported" else "Pinned pack installed")
    }

    fun import(uri: Uri) = bg {
        _state.value = _state.value.copy(busy = true, message = "Importing…", error = false)
        _state.value = try {
            val ix = ctx.contentResolver.openInputStream(uri)?.use { LoaderPack.import(it, root) }
                ?: throw LoaderPack.Refused("cannot open the picked file")
            LoaderState(index = ix, message = "Imported: ${ix.pairs.size} models, pinned sha verified")
        } catch (e: Exception) {
            // A refused pack never replaces the installed one.
            LoaderState(index = runCatching { LoaderPack.installed(root) }.getOrNull(),
                message = "Refused: ${e.message}", error = true)
        }
    }

    fun pick(pair: LoaderPair) = bg {
        val ix = _state.value.index ?: return@bg
        _state.value = _state.value.copy(busy = true, selected = null, lastCheck = null, message = "Checking ${pair.id}…", error = false)
        val v = try {
            val argv = LoadersCheck.argvFor(CoreRunner.corePath(ctx).path, root.absolutePath, ix, pair)
            val (rc, out) = run(argv)
            LoadersCheck.judge(rc, out, pair)
        } catch (e: Exception) {
            LoadersCheck.Verdict(false, listOf("${e.javaClass.simpleName}: ${e.message}"), emptyMap())
        }
        _state.value = _state.value.copy(busy = false, lastCheck = v, selected = if (v.ok) pair else null,
            message = if (v.ok) "Selected ${pair.id}" else "Refused ${pair.id}", error = !v.ok)
    }

    private fun run(argv: List<String>): Pair<Int?, String> {
        val pb = ProcessBuilder(argv).directory(root).redirectErrorStream(false)
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
        return rc to out.toString()
    }

    private fun bg(f: () -> Unit) { Thread { f() }.apply { name = "loaders"; isDaemon = true; start() } }
}
