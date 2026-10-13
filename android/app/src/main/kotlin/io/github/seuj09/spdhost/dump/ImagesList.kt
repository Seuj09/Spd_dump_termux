package io.github.seuj09.spdhost.dump

/**
 * `images list DIR --json` (README, offline): the image files of a dump
 * folder. Pickers use this, never the human stderr listing, and then keep only
 * names that are rows of the saved partition table (Debugger #30 leftover 3).
 */
data class ImageFile(val name: String, val file: String, val bytes: Long, val slot: String?, val sha256: String?)

data class ImagesList(val dir: String, val layout: String, val images: List<ImageFile>) {
    /** Only images whose name is a row of [table]; no table = nothing offered. */
    fun filterBy(table: PartsTable?): List<ImageFile> {
        val names = table?.names ?: return emptyList()
        return images.filter { it.name in names }
    }

    companion object {
        fun parse(json: String): ImagesList {
            val m = Json.parse(json.trim()) as? Map<*, *> ?: throw Json.Bad("not an object")
            if (m["v"] != 1L) throw Json.Bad("unknown images list v=${m["v"]}")
            val imgs = (m["images"] as? List<*> ?: throw Json.Bad("no images")).map { e ->
                val o = e as? Map<*, *> ?: throw Json.Bad("bad image entry")
                ImageFile(
                    name = o["name"] as? String ?: throw Json.Bad("image without name"),
                    file = o["file"] as? String ?: throw Json.Bad("image without file"),
                    bytes = (o["bytes"] as? Long) ?: -1,
                    slot = o["slot"] as? String,
                    sha256 = o["sha256"] as? String,
                )
            }
            return ImagesList(m["dir"] as? String ?: "", m["layout"] as? String ?: "none", imgs)
        }
    }
}
