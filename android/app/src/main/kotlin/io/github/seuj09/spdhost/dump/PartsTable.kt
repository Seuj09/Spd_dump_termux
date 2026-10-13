package io.github.seuj09.spdhost.dump

/**
 * The `parts FILE` table (README `parts`): a `# spdhost-parts shift S verified V`
 * header, then `index name units` rows in raw table units (bytes = units << S).
 * The app shows it as JSON ([toJson]) and uses the names to filter pickers.
 */
data class PartRow(val index: Int, val name: String, val units: Long, val bytes: Long?)

data class PartsTable(val shift: Int?, val verified: Boolean, val rows: List<PartRow>) {
    val names: Set<String> get() = rows.mapTo(LinkedHashSet()) { it.name }

    fun toJson(): String = buildString {
        append("{\"shift\":").append(shift?.toString() ?: "null")
        append(",\"verified\":").append(verified)
        append(",\"rows\":[")
        rows.forEachIndexed { k, r ->
            if (k > 0) append(',')
            append("{\"index\":").append(r.index).append(",\"name\":\"").append(esc(r.name))
            append("\",\"units\":").append(r.units).append(",\"bytes\":").append(r.bytes?.toString() ?: "null").append('}')
        }
        append("]}")
    }

    companion object {
        private val HEADER = Regex("""#\s*spdhost-parts shift (\d+) verified ([01]).*""")
        private fun esc(s: String) = s.replace("\\", "\\\\").replace("\"", "\\\"")

        fun parse(text: String): PartsTable {
            var shift: Int? = null; var verified = false
            val rows = ArrayList<PartRow>()
            for (raw in text.lineSequence()) {
                val line = raw.trim()
                if (line.isEmpty()) continue
                HEADER.matchEntire(line)?.let { shift = it.groupValues[1].toInt(); verified = it.groupValues[2] == "1"; continue }
                if (line.startsWith("#")) continue
                val t = line.split(Regex("""\s+"""))
                if (t.size != 3) continue
                val idx = t[0].toIntOrNull() ?: continue
                val units = t[2].toLongOrNull() ?: continue
                val s = shift
                rows += PartRow(idx, t[1], units, if (s != null && s in 0..40) units shl s else null)
            }
            return PartsTable(shift, verified, rows)
        }
    }
}
