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

# Expose an original per-frame sequence hook for a matching native preview.
# No algorithm is copied or reimplemented; static hooks stay in their own TU.
background = source / "src/algos/background_extraction.c"
background.write_text(background.read_text() + r'''

int siril_ipados_background_sequence_preview(fits *fit, struct background_data *data) {
    sensor_pattern pattern = get_cfa_pattern_index_from_string(fit->keywords.bayer_pattern);
    data->is_cfa = fit->naxes[2] == 1 && pattern >= BAYER_FILTER_MIN && pattern <= BAYER_FILTER_MAX;
    struct generic_seq_args args = { .user = data };
    return data->is_cfa && data->method != BACKGROUND_METHOD_AUTO
        ? bgcfa_image_hook(&args, 0, 0, fit, NULL, 1)
        : background_image_hook(&args, 0, 0, fit, NULL, 1);
}
''')

# Upstream's luminance mask command currently points at the channel parser.
# Bind it to the existing original luminance parser; keep the algorithm intact.
command_table = source / "src/core/command_list.h"
text = command_table.read_text()
old = 'process_mask_from_channel, STR_MASK_FROM_LUM'
assert text.count(old) == 1
command_table.write_text(text.replace(old, 'process_mask_from_lum, STR_MASK_FROM_LUM'))

# The original bilateral history exceeds its fixed 90-byte stack buffer even
# at default parameters. Preserve the full history with an owned string.
command = source / "src/core/command.c"
text = command.read_text()
start = text.index("int process_epf(")
end = text.index("int process_getref(", start)
epf = text[start:end]
assert epf.count("char log[90];") == 1
epf = epf.replace("char log[90];", "gchar *log = NULL;")
epf = epf.replace("sprintf(log,", "log = g_strdup_printf(")
epf = epf.replace("g_slist_append(gfit->history, g_strdup(log))", "g_slist_append(gfit->history, log)")
# The original GUI permits zero modulation (identity); the native command
# parser unnecessarily rejected it even though the original worker handles it.
epf = epf.replace("if (mod <= 0.0 || mod > 1.0)", "if (mod < 0.0 || mod > 1.0)")
command.write_text(text[:start] + epf + text[end:])

# A script findstar normally frees its single-image results after reporting.
# The native star-mask workflow needs that selected-channel result, just as the
# desktop GUI does. Use the original locked ownership helpers; private/sequence
# callers keep their existing lifetime.
finder = source / "src/algos/star_finder.c"
text = finder.read_text()
old = "\telse if (!args->update_GUI)\n\t\tfree_fitted_stars(stars);"
assert text.count(old) == 1
finder.write_text(text.replace(old, "\telse if (!args->update_GUI) {\n\t\tif (com.headless && !args->im.from_seq) replace_com_stars(stars);\n\t\telse free_fitted_stars(stars);\n\t}"))
single = source / "src/io/single_image.c"
text = single.read_text()
text = '#include "algos/PSF.h"\n' + text
old = "\tif (!com.headless)\n\t\tgui_iface.on_image_closed();"
assert text.count(old) == 1
single.write_text(text.replace(old, old + "\n\telse\n\t\treplace_com_stars(NULL);"))

formats = source / "src/io/image_formats_libraries.c"
text = formats.read_text()
start = text.index("int readjpg(")
end = text.index("int savejpg(", start)
reader = text[start:end]
reader = reader.replace("struct jpeg_decompress_struct cinfo;", "struct jpeg_decompress_struct cinfo = {0};")
reader = reader.replace("struct jpeg_error_mgr jerr;", "struct ipad_jpeg_error jerr = {0};")
reader = reader.replace("cinfo.err = jpeg_std_error(&jerr);", "cinfo.err = jpeg_std_error(&jerr.manager);\n\tjerr.manager.error_exit = ipad_jpeg_error_exit;\n\tif (setjmp(jerr.recovery)) {\n\t\tjpeg_destroy_decompress(&cinfo); fclose(f); free(jerr.pixels);\n\t\treturn OPEN_IMAGE_ERROR;\n\t}")
reader = reader.replace("WORD *data = malloc(npixels * sizeof(WORD) * 3);", "WORD *data = malloc(npixels * sizeof(WORD) * 3);\n\tjerr.pixels = data;")
# The original allocation has exactly three planes. Four-component CMYK must
# fail before allocation instead of exposing a fourth plane outside the buffer.
old_start = "\tjpeg_start_decompress(&cinfo);"
assert reader.count(old_start) == 1
reader = reader.replace(old_start, old_start + "\n\tif (cinfo.output_components != 1 && cinfo.output_components != 3) {\n\t\tsiril_log_error(\"Unsupported JPEG component layout\\n\");\n\t\tjpeg_destroy_decompress(&cinfo); fclose(f);\n\t\treturn OPEN_IMAGE_ERROR;\n\t}")
# libjpeg can still consume source bytes during finish. Keep FILE alive until
# then so the error handler can safely close it exactly once on late failures.
old_finish = "\tfclose(f);\n\tjpeg_finish_decompress(&cinfo);\n\tjpeg_destroy_decompress(&cinfo);"
assert reader.count(old_finish) == 1
reader = reader.replace(old_finish, "\tjpeg_finish_decompress(&cinfo);\n\tjpeg_destroy_decompress(&cinfo);\n\tfclose(f);")
reader = reader.replace("\t\tPRINT_ALLOC_ERR;\n\t\tfclose(f);", "\t\tPRINT_ALLOC_ERR;\n\t\tjpeg_destroy_decompress(&cinfo);\n\t\tfclose(f);")
helper = """struct ipad_jpeg_error {
    struct jpeg_error_mgr manager;
    jmp_buf recovery;
    void *volatile pixels;
};
static void ipad_jpeg_error_exit(j_common_ptr decoder) {
    struct ipad_jpeg_error *error = (struct ipad_jpeg_error *)decoder->err;
    char text[JMSG_LENGTH_MAX];
    decoder->err->format_message(decoder, text);
    siril_log_error("JPEG decode failed: %s\\n", text);
    longjmp(error->recovery, 1);
}
"""
formats.write_text(text[:start] + helper + reader + text[end:])
