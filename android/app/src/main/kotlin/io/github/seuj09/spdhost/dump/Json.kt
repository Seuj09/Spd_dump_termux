package io.github.seuj09.spdhost.dump

/**
 * A small JSON reader (objects, arrays, strings, numbers, true/false/null) for
 * `images list --json`. Pure Kotlin: org.json is a stub on the JVM test
 * classpath. Numbers come back as Long when integral, else Double.
 */
object Json {
    class Bad(msg: String) : Exception(msg)

    fun parse(s: String): Any? {
        val p = P(s); p.ws(); val v = p.value(0); p.ws()
        if (p.i != s.length) throw Bad("trailing data at ${p.i}")
        return v
    }

    private class P(val s: String) {
        var i = 0
        fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
        fun value(depth: Int): Any? {
            if (depth > 32) throw Bad("too deep")
            if (i >= s.length) throw Bad("unexpected end")
            return when (s[i]) {
                '{' -> obj(depth)
                '[' -> arr(depth)
                '"' -> str()
                't' -> lit("true", true)
                'f' -> lit("false", false)
                'n' -> lit("null", null)
                else -> num()
            }
        }
        fun lit(w: String, v: Any?): Any? { if (!s.startsWith(w, i)) throw Bad("bad literal at $i"); i += w.length; return v }
        fun num(): Any {
            val st = i
            while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
            val t = s.substring(st, i)
            return t.toLongOrNull() ?: t.toDoubleOrNull() ?: throw Bad("bad number at $st")
        }
        fun str(): String {
            i++
            val sb = StringBuilder()
            while (i < s.length) {
                val c = s[i++]
                if (c == '"') return sb.toString()
                if (c != '\\') { sb.append(c); continue }
                if (i >= s.length) break
                when (val e = s[i++]) {
                    '"', '\\', '/' -> sb.append(e)
                    'b' -> sb.append('\b'); 'f' -> sb.append('\u000c')
                    'n' -> sb.append('\n'); 'r' -> sb.append('\r'); 't' -> sb.append('\t')
                    'u' -> { if (i + 4 > s.length) throw Bad("bad \\u"); sb.append(s.substring(i, i + 4).toIntOrNull(16)?.toChar() ?: throw Bad("bad \\u")); i += 4 }
                    else -> throw Bad("bad escape")
                }
            }
            throw Bad("unterminated string")
        }
        fun obj(d: Int): Map<String, Any?> {
            i++; ws()
            val m = LinkedHashMap<String, Any?>()
            if (i < s.length && s[i] == '}') { i++; return m }
            while (true) {
                ws(); if (i >= s.length || s[i] != '"') throw Bad("key expected at $i")
                val k = str(); ws()
                if (i >= s.length || s[i] != ':') throw Bad(": expected at $i")
                i++; ws(); m[k] = value(d + 1); ws()
                if (i >= s.length) throw Bad("unexpected end")
                when (s[i++]) { ',' -> continue; '}' -> return m; else -> throw Bad(", or } expected") }
            }
        }
        fun arr(d: Int): List<Any?> {
            i++; ws()
            val l = ArrayList<Any?>()
            if (i < s.length && s[i] == ']') { i++; return l }
            while (true) {
                ws(); l += value(d + 1); ws()
                if (i >= s.length) throw Bad("unexpected end")
                when (s[i++]) { ',' -> continue; ']' -> return l; else -> throw Bad(", or ] expected") }
            }
        }
    }
}
