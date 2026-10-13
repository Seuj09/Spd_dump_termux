package io.github.seuj09.spdhost.engine

/**
 * What the Dump screen shows, folded from `--events` (README "Event channel").
 * `op` events branch on the op field: `dump` carries files/failed/why, a misc
 * op (`misc-reboot`/`set-active`, never started by P1) carries target/ending/
 * backup fields, which are shown as-is and never treated as a dump result.
 */
data class Preflight(
    val files: Int?, val needBytes: Long?, val headroomBytes: Long?, val availBytes: Long?,
    val slot: String?, val tableVerified: Boolean, val ok: Boolean,
) {
    /** Free space is an estimate only when the table was not verified (Debugger #30 leftover 2). */
    fun text(): String {
        fun mib(b: Long?) = if (b == null || b < 0) "unknown" else "${b shr 20} MiB"
        val base = "need ${mib(needBytes)} + ${mib(headroomBytes)} headroom, free ${mib(availBytes)}"
        val est = if (tableVerified) "" else " (ESTIMATE: partition table sizes not verified by the device)"
        return (if (ok) "Preflight OK: " else "Preflight REFUSED: ") + base + est + (slot?.let { ", slot $it" } ?: "")
    }
}

data class DumpFile(val name: String, val file: String?, val bytes: Long?, val state: String, val sha256: String?)

data class SessionView(
    val hello: String? = null,
    val stage: String? = null,
    val progress: String? = null,
    val preflight: Preflight? = null,
    val files: List<DumpFile> = emptyList(),
    val dumpResult: String? = null,
    val otherOp: String? = null,
    val rc: Int? = null,
) {
    fun reduce(e: EngineEvent): SessionView = when (e.ev) {
        "hello" -> copy(hello = e.summary())
        "stage" -> copy(stage = e["stage"])
        "progress" -> copy(progress = progressText(e))
        "preflight" -> if (e["op"] == "dump") copy(preflight = Preflight(
            e["files"]?.toIntOrNull(), e["need"]?.toLongOrNull(), e["headroom"]?.toLongOrNull(), e["avail"]?.toLongOrNull(),
            e["slot"], e["table_verified"] == "true" || e["table_verified"] == "1", e["ok"] == "true" || e["ok"] == "1",
        )) else this
        "dump-file" -> copy(files = files + DumpFile(e["name"] ?: "?", e["file"], e["bytes"]?.toLongOrNull(), e["state"] ?: "?", e["sha256"]))
        "op" -> when (e["op"]) {
            "dump" -> copy(dumpResult = "dump ${e["state"]}: ${e["files"] ?: "?"} files" +
                (e["failed"]?.let { ", $it failed" } ?: "") + (e["why"]?.let { " ($it)" } ?: ""))
            else -> copy(otherOp = "${e["op"]} ${e["state"]}" + (e["target"]?.let { " target=$it" } ?: "") + (e["why"]?.let { " ($it)" } ?: ""))
        }
        "end" -> copy(rc = e["rc"]?.toIntOrNull())
        else -> this
    }

    private fun progressText(e: EngineEvent): String {
        val d = e["done"]?.toLongOrNull(); val t = e["total"]?.toLongOrNull()
        val pct = if (d != null && t != null && t > 0) " ${d * 100 / t}%" else ""
        return "${e["op"]} ${e["name"]} ${d?.shr(20) ?: "?"}/${t?.shr(20) ?: "?"} MiB$pct"
    }
}
