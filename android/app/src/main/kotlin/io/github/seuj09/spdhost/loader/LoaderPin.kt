package io.github.seuj09.spdhost.loader

/**
 * The loader pack this APK accepts (plan Decision 6: CI `fdl-pack-<sha7>.zip`,
 * sha-pinned in the APK). Two pins, both checked on import:
 *  - [PACK_SHA256]: sha256 of the deterministic zip `scripts/fdl-pack.sh`
 *    builds (same tree => same bytes, whatever the sha7 in its name);
 *  - [INDEX_SHA256]: sha256 of the `fdl/index` inside it. The index lists the
 *    sha256 of every loader, so this pins every file too.
 * LoaderPinTest recomputes both from no-root/fdl, so an fdl/ change that does
 * not bump these fails the build. No loader is bundled in the APK.
 */
object LoaderPin {
    const val PACK_SHA256 = "a8eb3ec2fe6b81046f7cf4c3bf02a684507b4d5dcc94bd6ffe785493ebb53c12"
    const val INDEX_SHA256 = "b02222a3b4007e4a2c6e4effdc37e14d7bef2a7648a78ed74d12027bcc739bd9"
}
