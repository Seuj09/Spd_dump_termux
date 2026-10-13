package io.github.seuj09.spdhost.engine

/**
 * One `--events` line (README "Event channel"): a flat JSON object with the
 * envelope {"v":1,"seq":N,"t":MS,"ev":"TYPE",...}. Values are kept as text
 * (strings unescaped, numbers/booleans as written). Unknown types and fields
 * are kept and ignored by the UI, as the README asks. Pure Kotlin (no
 * org.json, which is a stub on the JVM test classpath).
 */
data class EngineEvent(val ev: String, val fields: Map<String, String>) {
    operator fun get(key: String): String? = fields[key]

    /** One line for the screen. `op` events branch on the op field (P1-5). */
    fun summary(): String = when (ev) {
        "start" -> "core ${this["build_sha"]?.take(7)} pid ${this["pid"]}"
        "session" -> "session usb=${this["usb"]}"
        "stage" -> "stage ${this["stage"]}"
        "cmd" -> "${this["name"]}: ${this["state"]}"
        "hello" -> "hello ${this["stage"]} try ${this["try"]}/${this["of"]}: ${this["result"]}" +
            (this["ms"]?.let { " ($it ms)" } ?: "")
        "progress" -> "${this["op"]} ${this["name"]} ${this["done"]}/${this["total"]}"
        "usb" -> "usb ${this["state"]}"
        "op" -> "op ${this["op"]}: ${this["state"]}" + (this["why"]?.let { " ($it)" } ?: "")
        "dropped" -> "events dropped: ${this["count"]}"
        "end" -> "end rc=${this["rc"]}"
        else -> ev
    }

    companion object {
        /** Null for a line that is not a flat JSON object with an `ev`. */
        fun parse(line: String): EngineEvent? {
            val m = parseFlat(line.trim()) ?: return null
            val ev = m["ev"] ?: return null
            return EngineEvent(ev, m)
        }

        private fun parseFlat(s: String): Map<String, String>? {
            var i = 0
            fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
            fun str(): String? {
                if (i >= s.length || s[i] != '"') return null
                i++
                val sb = StringBuilder()
                while (i < s.length) {
                    val c = s[i++]
                    when (c) {
                        '"' -> return sb.toString()
                        '\\' -> {
                            if (i >= s.length) return null
                            when (val e = s[i++]) {
                                '"', '\\', '/' -> sb.append(e)
                                'b' -> sb.append('\b'); 'f' -> sb.append('\u000c')
                                'n' -> sb.append('\n'); 'r' -> sb.append('\r'); 't' -> sb.append('\t')
                                'u' -> {
                                    if (i + 4 > s.length) return null
                                    sb.append(s.substring(i, i + 4).toIntOrNull(16)?.toChar() ?: return null)
                                    i += 4
                                }
                                else -> return null
                            }
                        }
                        else -> sb.append(c)
                    }
                }
                return null
            }
            val out = LinkedHashMap<String, String>()
            ws()
            if (i >= s.length || s[i] != '{') return null
            i++; ws()
            if (i < s.length && s[i] == '}') return if (i + 1 == s.length) out else null
            while (true) {
                ws()
                val k = str() ?: return null
                ws()
                if (i >= s.length || s[i] != ':') return null
                i++; ws()
                val v = if (i < s.length && s[i] == '"') str() ?: return null else {
                    val st = i
                    while (i < s.length && s[i] != ',' && s[i] != '}' && !s[i].isWhitespace()) i++
                    val raw = s.substring(st, i)
                    if (raw.isEmpty() || raw.startsWith("{") || raw.startsWith("[")) return null
                    raw
                }
                out[k] = v
                ws()
                if (i >= s.length) return null
                when (s[i++]) {
                    ',' -> continue
                    '}' -> { ws(); return if (i == s.length) out else null }
                    else -> return null
                }
            }
        }
    }
}
