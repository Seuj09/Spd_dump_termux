package io.github.seuj09.spdhost.loader

import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/** One `pair SOC MODEL FDL1 FDL2` line of fdl/index (paths relative to it). */
data class LoaderPair(val soc: String, val model: String, val fdl1: String, val fdl2: String) {
    /** What `loaders check` prints as pair= for this set. */
    val id get() = "$soc/$model"
}

/** A `soc NAME fdl1=… fdl2=…` line: the load addresses for that chip. */
data class SocAddrs(val name: String, val fdl1: String, val fdl2: String)

data class LoaderIndex(
    val socs: Map<String, SocAddrs>,
    val files: Map<String, String>, // rel path -> sha256
    val pairs: List<LoaderPair>,
)

/**
 * Loader-pack import (plan P1-4), pure JVM so it is unit-tested:
 *  zip (from SAF) -> staging dir -> pin + per-file sha check -> atomic swap
 *  into `<root>/fdl`. Anything unexpected refuses the whole pack; nothing from
 *  a refused pack is ever left where the core could pick it up.
 */
object LoaderPack {
    class Refused(msg: String) : Exception(msg)

    const val MAX_FILE_BYTES = 16L shl 20 // the core's LOADER_MAX_BYTES
    const val MAX_TOTAL_BYTES = 64L shl 20
    const val MAX_ENTRIES = 512
    /** Cap on the raw SAF file copied to .incoming.zip.tmp before the pin check. */
    const val MAX_PACK_BYTES = 64L shl 20

    /**
     * Soft 2: a crash between "fdl -> .old" and ".staging -> fdl" leaves no
     * installed pack; put the previous one back.
     */
    fun restoreOld(root: File) {
        val dest = File(root, "fdl"); val old = File(root, ".old")
        if (!dest.exists() && old.isDirectory) old.renameTo(dest)
    }

    private val SAFE_REL = Regex("""[A-Za-z0-9._+\-]+(/[A-Za-z0-9._+\-]+)*""")

    fun sha256Hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    /**
     * Imports [zip] into `[root]/fdl`. Returns the parsed index. The zip
     * file's own sha256 (hashed while copying, before any parsing) must equal [packPin]; the extracted fdl/index must
     * equal [indexPin]; every indexed file must be present with its sha256 and
     * nothing else may be in the pack.
     */
    fun import(zip: InputStream, root: File, packPin: String = LoaderPin.PACK_SHA256,
               indexPin: String = LoaderPin.INDEX_SHA256): LoaderIndex {
        root.mkdirs()
        restoreOld(root)
        val incoming = File(root, ".incoming.zip.tmp")
        val staging = File(root, ".staging")
        try {
            // #37 D1: copy + hash the SAF stream first (capped); no zip parsing
            // and no .staging until the whole file matches the pin.
            incoming.delete()
            val zipMd = MessageDigest.getInstance("SHA-256")
            var size = 0L
            incoming.outputStream().use { o ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val r = zip.read(buf)
                    if (r < 0) break
                    size += r
                    if (size > MAX_PACK_BYTES) throw Refused("pack file is larger than ${MAX_PACK_BYTES shr 20} MiB")
                    zipMd.update(buf, 0, r); o.write(buf, 0, r)
                }
            }
            val packSha = sha256Hex(zipMd.digest())
            if (packSha != packPin) throw Refused("pack sha256 $packSha is not the pinned $packPin")
            staging.deleteRecursively()
            if (!staging.mkdirs()) throw Refused("cannot create ${staging.path}")
            val shas = HashMap<String, String>()
            var total = 0L
            var entries = 0
            ZipInputStream(incoming.inputStream().buffered()).use { z ->
                while (true) {
                    val e = z.nextEntry ?: break
                    // Soft 1: directory entries count toward the limit too.
                    if (++entries > MAX_ENTRIES) throw Refused("more than $MAX_ENTRIES entries")
                    val name = e.name
                    if (e.isDirectory) continue
                    if (!name.startsWith("fdl/")) throw Refused("entry outside fdl/: $name")
                    val rel = name.removePrefix("fdl/")
                    if (!SAFE_REL.matches(rel) || rel.split('/').any { it == "." || it == ".." })
                        throw Refused("unsafe entry name: $name")
                    if (rel in shas) throw Refused("duplicate entry: $name")
                    val out = File(staging, rel)
                    out.parentFile!!.mkdirs()
                    val md = MessageDigest.getInstance("SHA-256")
                    var n = 0L
                    out.outputStream().use { o ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val r = z.read(buf)
                            if (r < 0) break
                            n += r; total += r
                            if (n > MAX_FILE_BYTES) throw Refused("$name is larger than ${MAX_FILE_BYTES shr 20} MiB")
                            if (total > MAX_TOTAL_BYTES) throw Refused("pack is larger than ${MAX_TOTAL_BYTES shr 20} MiB")
                            md.update(buf, 0, r); o.write(buf, 0, r)
                        }
                    }
                    shas[rel] = sha256Hex(md.digest())
                }
            }
            val idxSha = shas["index"] ?: throw Refused("no fdl/index in the pack")
            if (idxSha != indexPin) throw Refused("fdl/index sha256 $idxSha is not the pinned $indexPin")
            val index = parseIndex(File(staging, "index").readText())
            for ((rel, want) in index.files) {
                val got = shas[rel] ?: throw Refused("missing $rel")
                if (got != want) throw Refused("$rel sha256 $got does not match fdl/index ($want)")
            }
            val extra = shas.keys - index.files.keys - "index"
            if (extra.isNotEmpty()) throw Refused("files not in fdl/index: ${extra.sorted().take(5).joinToString()}")
            // Swap: old -> .old, staging -> fdl, drop .old.
            val dest = File(root, "fdl")
            val old = File(root, ".old")
            old.deleteRecursively()
            if (dest.exists() && !dest.renameTo(old)) throw Refused("cannot move the old pack aside")
            if (!staging.renameTo(dest)) { old.renameTo(dest); throw Refused("cannot install the pack") }
            old.deleteRecursively()
            return index
        } finally {
            staging.deleteRecursively()
            incoming.delete()
        }
    }

    /** The installed pack's index, re-verified against the pin; null if absent or not pinned. */
    fun installed(root: File, indexPin: String = LoaderPin.INDEX_SHA256): LoaderIndex? {
        // Soft 3: index-only recheck is enough here; `loaders check` re-hashes
        // FDL1/FDL2/stub against this index before any model is selected.
        restoreOld(root)
        val f = File(root, "fdl/index")
        if (!f.isFile) return null
        val b = f.readBytes()
        if (sha256Hex(MessageDigest.getInstance("SHA-256").digest(b)) != indexPin) return null
        return runCatching { parseIndex(String(b, Charsets.UTF_8)) }.getOrNull()
    }

    fun parseIndex(text: String): LoaderIndex {
        val socs = LinkedHashMap<String, SocAddrs>()
        val files = LinkedHashMap<String, String>()
        val pairs = ArrayList<LoaderPair>()
        var header = false
        var ended = false
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            if (ended) throw Refused("fdl/index: data after end")
            val t = line.split(Regex("""\s+"""))
            when (t[0]) {
                "spdhost-fdl-index" -> { if (t.getOrNull(1) != "1") throw Refused("fdl/index: unknown format ${t.getOrNull(1)}"); header = true }
                "soc" -> {
                    val kv = t.drop(2).mapNotNull { it.split('=', limit = 2).takeIf { p -> p.size == 2 } }.associate { it[0] to it[1] }
                    socs[t[1]] = SocAddrs(t[1], kv["fdl1"] ?: throw Refused("soc ${t[1]}: no fdl1"), kv["fdl2"] ?: throw Refused("soc ${t[1]}: no fdl2"))
                }
                "file" -> { if (t.size != 6) throw Refused("fdl/index: bad file line"); files[t[5]] = t[1] }
                "pair" -> { if (t.size != 5) throw Refused("fdl/index: bad pair line"); pairs += LoaderPair(t[1], t[2], t[3], t[4]) }
                "end" -> ended = true
                else -> throw Refused("fdl/index: unknown line ${t[0]}")
            }
        }
        if (!header || !ended) throw Refused("fdl/index: missing header or end")
        for (p in pairs) {
            if (p.soc !in socs) throw Refused("pair ${p.id}: unknown soc")
            if (p.fdl1 !in files || p.fdl2 !in files) throw Refused("pair ${p.id}: file not indexed")
        }
        return LoaderIndex(socs, files, pairs)
    }
}
