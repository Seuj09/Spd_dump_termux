#ifndef SPDHOST_LOADERS_H
#define SPDHOST_LOADERS_H
/* P0-6: `spdhost loaders {check|list|verify}` -- offline, no USB.
 * argv[0] is "loaders". self_path locates the package's fdl/index.
 * Returns the process exit code: 0 ok, 1 refused / bad index, 2 usage. */
int spd_loaders_main(int argc, char **argv, const char *self_path);
#endif
