#!/usr/bin/env python3
"""Attach our C ABI to a previously patched, pinned upstream Siril checkout."""
from pathlib import Path
import shutil

root = Path.cwd()
source = root / "siril-src"
destination = source / "src/ipados"
destination.mkdir(exist_ok=True)
for name in ("SirilCore.c", "SirilCore.h", "core-link-probe.c", "core-runtime-tests.c"):
    shutil.copy2(root / "native" / name, destination / name)
meson = source / "src/meson.build"
text = meson.read_text()
needle = "siril_lib = static_library('siril',"
assert text.count(needle) == 1, "Pinned upstream static library layout changed"
text = text.replace(needle, "if enable_embedded\n  src_files += files('ipados/SirilCore.c')\nendif\n\n" + needle)
text += """

# Resolve every compiled core symbol against iPadOS and the headless stubs.
# This binary is only link-checked; executing it requires an Apple device.
if enable_embedded
  executable('siril-ipados-link-probe', 'ipados/core-link-probe.c',
    dependencies: siril_dep,
    link_whole: siril_lib,
    link_args: siril_link_arg,
    c_args: siril_c_flag,
    cpp_args: siril_cpp_flag)
  executable('siril-ipados-runtime-tests', 'ipados/core-runtime-tests.c',
    dependencies: siril_dep,
    c_args: siril_c_flag,
    cpp_args: siril_cpp_flag)
endif
"""
meson.write_text(text)

# Read the same configured table used by execute_command, without maintaining
# a separate list that could drift away from upstream features or build flags.
processor = source / "src/core/command_line_processor.c"
processor.write_text(processor.read_text() + r'''

const char *siril_command_catalog(void) {
  static gsize catalog_initialized;
  static char *catalog;
  if (g_once_init_enter(&catalog_initialized)) {
    GString *text = g_string_new(NULL);
    for (size_t i = 0; i < G_N_ELEMENTS(commands); i++) {
      if (!commands[i].scriptable || !strcmp(commands[i].name, "exit") ||
          !strcmp(commands[i].name, "livestack") || !strcmp(commands[i].name, "stop_ls")) continue;
      gchar *usage = g_strdup(commands[i].usage);
      for (char *p = usage; *p; p++) if (*p == '\n' || *p == '\t') *p = ' ';
      g_string_append_printf(text, "%s\t%s\n", commands[i].name, usage);
      g_free(usage);
    }
    catalog = g_string_free(text, FALSE);
    g_once_init_leave(&catalog_initialized, 1);
  }
  return catalog;
}
''')

# iPadOS gives Apps a per-process memory budget, unlike desktop macOS.
utilities = source / "src/core/OS_utils.c"
text = utilities.read_text()
needle = "#ifdef OS_OSX\nstatic gint64 find_space(const gchar *name) {"
assert text.count(needle) == 1
text = text.replace(needle, """#ifdef OS_IOS
static gint64 find_space(const gchar *name) {
    /* iPad sandbox volumes may omit the desktop format-description key.
     * Query the available capacity itself instead of requiring APFS metadata. */
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:name];
        NSURL *url = [NSURL fileURLWithPath:path];
        NSNumber *capacity = nil;
        if ([url getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil]
                && capacity && [capacity longLongValue] > 0) return [capacity longLongValue];
        capacity = nil;
        if ([url getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityKey error:nil] && capacity)
            return [capacity longLongValue];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:nil];
        NSNumber *freeSpace = attributes[NSFileSystemFreeSize];
        return freeSpace ? [freeSpace longLongValue] : -1;
    }
}
#elif defined(OS_OSX)
static gint64 find_space(const gchar *name) {""")
needle = "guint64 get_available_memory() {\n#if defined(__linux__) || defined(__CYGWIN__)"
assert text.count(needle) == 1
text = text.replace(needle, """#ifdef OS_IOS
#include <os/proc.h>
#include <TargetConditionals.h>
#endif
guint64 get_available_memory() {
#if defined(OS_IOS)
    /* This API reports zero in the simulator. Keep a conservative test budget;
     * physical iPads use the real per-process remaining-memory estimate. */
#if TARGET_OS_SIMULATOR
    return (guint64)512 * 1024 * 1024;
#else
    return (guint64)os_proc_available_memory();
#endif
#elif defined(__linux__) || defined(__CYGWIN__)""")
utilities.write_text(text)
