package io.github.seuj09.spdhost.loader

/**
 * `spdhost loaders check` for a picked model (plan P1-4, Debugger #29 notes):
 *  - always `--index <ABSOLUTE path>` so the core's cwd can never pick a
 *    stray ./fdl/index;
 *  - the app is stricter than the CLI: any `warning=`, or a stub / FDL whose
 *    id is not `index`, or a pair= other than the one picked, is REFUSE.
 * Offline: no USB, no device. FDL/stub sha binding into plans is P2.
 */
object LoadersCheck {
    data class Verdict(val ok: Boolean, val reasons: List<String>, val kv: Map<String, String>)

    fun argv(core: String, indexAbs: String, soc: SocAddrs, fdl1Abs: String, fdl2Abs: String): List<String> {
        for (p in listOf(indexAbs, fdl1Abs, fdl2Abs)) require(p.startsWith("/")) { "not an absolute path: $p" }
        return listOf(core, "loaders", "check", "--index", indexAbs, "--soc", soc.name,
            fdl1Abs, soc.fdl1, fdl2Abs, soc.fdl2)
    }

    fun argvFor(core: String, root: String, index: LoaderIndex, pair: LoaderPair): List<String> {
        val dir = "$root/fdl"
        val soc = index.socs.getValue(pair.soc)
        return argv(core, "$dir/index", soc, "$dir/${pair.fdl1}", "$dir/${pair.fdl2}")
    }

    fun judge(rc: Int?, stdout: String, pair: LoaderPair): Verdict {
        val kv = LinkedHashMap<String, String>()
        val warnings = ArrayList<String>()
        var format = false
        var end = false
        for (line in stdout.lineSequence()) {
            if (line == "end") { end = true; continue }
            val i = line.indexOf('=')
            if (i <= 0) continue
            val k = line.substring(0, i); val v = line.substring(i + 1)
            if (k == "loaders_format") format = v == "1"
            if (k == "warning") warnings += v else kv[k] = v
        }
        val why = ArrayList<String>()
        if (rc != 0) why += "loaders check exited rc=${rc ?: "timeout"}"
        if (!format || !end) why += "output is not loaders_format=1 … end"
        if (kv["verdict"] != "ok") why += "verdict=${kv["verdict"] ?: "missing"}${kv["reason"]?.let { ": $it" } ?: ""}"
        warnings.forEach { why += "warning: $it" }
        for (k in listOf("fdl1_id", "fdl2_id", "stub_id"))
            if (kv[k] != "index") why += "$k=${kv[k] ?: "missing"} (must be index)"
        if (kv["pair"] != pair.id) why += "pair=${kv["pair"] ?: "missing"} is not ${pair.id}"
        if (kv["soc"] != pair.soc) why += "soc=${kv["soc"] ?: "missing"} is not ${pair.soc}"
        return Verdict(why.isEmpty(), why, kv)
    }
}
