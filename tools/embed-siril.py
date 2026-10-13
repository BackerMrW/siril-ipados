#!/usr/bin/env python3
"""Attach our C ABI to a previously patched, pinned upstream Siril checkout."""
from pathlib import Path
import shutil

root = Path.cwd()
source = root / "siril-src"
directories = source / "src/core/siril_app_dirs.c"
text = directories.read_text()
needle = 'static void search_for_spcc_repo_dir() {\n'
assert text.count(needle) == 1
text = text.replace(needle, needle + '''#ifdef OS_IOS
    const gchar *bundled = g_getenv("SIRIL_SPCC_DIR");
    if (bundled && g_file_test(bundled, G_FILE_TEST_IS_DIR)) {
        siril_spcc_repo_dir = g_strdup(bundled);
        return;
    }
#endif
''')
directories.write_text(text)
commands = source / "src/core/command.c"
text = commands.read_text()
needle = 'if (oscsensor || mono_or_osc == 1) {'
assert text.count(needle) == 1
# Explicit sensor options must win over the desktop's saved camera mode.
text = text.replace(needle, 'if (oscsensor || (!monosensor && mono_or_osc == 1)) {')
commands.write_text(text)
formats = source / "src/io/image_formats_libraries.c"
text = formats.read_text()
start = text.index('static int readraw_in_cfa(')
end = text.index('int open_raw_files(', start)
body = text[start:end]
needle = '\tlibraw_data_t *raw = libraw_init(0);'
assert body.count(needle) == 1
body = body.replace(needle, needle + '\n\tif (!raw) return OPEN_IMAGE_ERROR;')
# The decoder's early open/unpack/no-CFA failures must release its handle.
needle = '\t\tsiril_log_error("Error in libraw %s\\n", libraw_strerror(ret));\n\t\treturn OPEN_IMAGE_ERROR;'
assert body.count(needle) == 2
body = body.replace(needle, '\t\tsiril_log_error("Error in libraw %s\\n", libraw_strerror(ret));\n\t\tlibraw_close(raw);\n\t\treturn OPEN_IMAGE_ERROR;')
needle = '\t\t\t\t"no RAW data available.\\n"));\n\t\treturn OPEN_IMAGE_ERROR;'
assert body.count(needle) == 1
body = body.replace(needle, '\t\t\t\t"no RAW data available.\\n"));\n\t\tlibraw_close(raw);\n\t\treturn OPEN_IMAGE_ERROR;')
formats.write_text(text[:start] + body + text[end:])

# Original JPEG XL readers return a channel count, so failures must be negative.
# Release the compressed input and propagate encoder / filesystem failures.
text = formats.read_text()
start = text.index('int readjxl(')
end = text.index('int savejxl(', start)
body = text[start:end]
needle = '\t\tsiril_log_debug("Error while decoding the jxl file\\n");\n\t\treturn 1;'
assert body.count(needle) == 1
body = body.replace(needle, '\t\tsiril_log_debug("Error while decoding the jxl file\\n");\n'
                    '\t\tg_free(jxl_data); free(pixels); free(icc_profile); free(internal_icc_profile);\n\t\treturn -1;')
body = body.replace('\tclearfits(fit);', '\tg_free(jxl_data);\n\tclearfits(fit);', 1)
text = text[:start] + body + text[end:]
start = text.index('int savejxl(')
body = text[start:]
needle = '\tEncodeJpegXlOneshotWrapper(buffer, fit->rx,'
assert body.count(needle) == 1
body = body.replace(needle, '\tint encode_error = EncodeJpegXlOneshotWrapper(buffer, fit->rx,', 1)
needle = '\tg_file_set_contents(name, (const gchar *) compressed, compressed_length, &error);'
assert body.count(needle) == 1
body = body.replace(needle, '\tgboolean saved = !encode_error && g_file_set_contents(name, (const gchar *) compressed, compressed_length, &error);')
needle = '\t\tsiril_log_error(_("Error interleaving image\\n"));\n\t}'
assert body.count(needle) == 1
body = body.replace(needle, '\t\tsiril_log_error(_("Error interleaving image\\n"));\n\t\tfree(buffer); free(filename); return OPEN_IMAGE_ERROR;\n\t}')
needle = '\tfree(filename);\n\tg_error_free(error);\n\treturn OPEN_IMAGE_OK;'
assert body.count(needle) == 1
body = body.replace(needle, '\tfree(filename); free(profile);\n\tif (error) g_error_free(error);\n\treturn saved ? OPEN_IMAGE_OK : OPEN_IMAGE_ERROR;')
needle = '\tsiril_log_info(_("Save complete.\\n"));'
assert body.count(needle) == 1
body = body.replace(needle, '', 1)
body = body.replace('\tfree(buffer);\n\tfree(compressed);', '\tif (saved) siril_log_info(_("Save complete.\\n"));\n\tfree(buffer);\n\tfree(compressed);', 1)
formats.write_text(text[:start] + body)

wrapper = source / "src/io/SirilJpegXLWrapper.cpp"
text = wrapper.read_text()
needle = '#include <vector>'
assert text.count(needle) == 1
text = text.replace(needle, needle + '\n#include "core/OS_utils.h"')
needle = '      *xsize = info.xsize;'
assert text.count(needle) == 1
text = text.replace(needle, '''#ifdef OS_IOS
      if (!info.xsize || !info.ysize || info.xsize > 100000 || info.ysize > 100000 ||
          (info.num_color_channels != 1 && info.num_color_channels != 3) || info.num_extra_channels != 0 ||
          (double)info.xsize * info.ysize * info.num_color_channels * 12 > (double)get_available_memory() * .8) {
        fprintf(stderr, "JPEG XL layout unsupported or exceeds the available memory budget\\n");
        return false;
      }
#endif
''' + needle)
wrapper.write_text(text)

wrapper = source / "src/io/SirilXISFReader.cpp"
text = wrapper.read_text()
needle = 'catch (const LibXISF::Error &error)'
assert text.count(needle) == 2
# Numeric XML parsing and allocation may throw standard exceptions as well.
wrapper.write_text(text.replace(needle, 'catch (const std::exception &error)'))

text = commands.read_text()
start = text.index('int process_savejxl(')
end = text.index('int process_savepng(', start)
body = text[start:end]
needle = 'double quality = g_ascii_strtod(arg, &end);'
assert body.count(needle) == 1
body = body.replace(needle, 'quality = g_ascii_strtod(arg, &end);')
commands.write_text(text[:start] + body + text[end:])

# PCC's automatic background must use the worker's image, not the desktop's
# global displayed image. The two can have different geometry in embedding.
path = source / "src/algos/statistics_float.c"
text = path.read_text()
start = text.index('double robust_median_f(')
body = text[start:]
needle = '\t\tx1 = gfit->rx;\n\t\ty1 = gfit->ry;'
assert body.count(needle) == 1
body = body.replace(needle, '\t\tx1 = fit->rx;\n\t\ty1 = fit->ry;', 1)
path.write_text(text[:start] + body)
destination = source / "src/ipados"
destination.mkdir(exist_ok=True)
for name in ("SirilCore.c", "SirilCore.h", "SirilAdvanced.inc", "SirilDeconvolution.inc", "SirilAstrometry.inc", "SirilSER.inc", "core-link-probe.c", "core-runtime-tests.c", "xisf-runtime-tests.inc", "photometry-runtime-tests.inc", "ser-runtime-tests.inc", "jxl-runtime-tests.inc", "cfa-format-tests.inc"):
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

# PixelMath's original integer branch used variable slot zero for plane bounds
# even for $T-only evaluation. Match the existing float branch's actual bounds.
# Constant rescaling must remain finite; failed expressions must not rescale an
# uninitialized output. Release the previous headless single-image owner.
runner = source / "src/pixelMath/pixel_math_runner.c"
text = runner.read_text()
assert text.count("var_fit[0].naxes[0] * var_fit[0].naxes[1]") == 2
text = text.replace("var_fit[0].naxes[0] * var_fit[0].naxes[1]", "width * height")
assert text.count("if (args->rescale) {") == 1
text = text.replace("if (args->rescale) {", "if (args->rescale && !failed) {")
text = text.replace("/ (float)(maximum - minimum) + args->min",
                    "/ (float)(maximum == minimum ? 1.f : maximum - minimum) + args->min")
text = text.replace("/ (maximum - minimum)) + args->min",
                    "/ (maximum == minimum ? 1.f : maximum - minimum)) + args->min")
needle = "if (com.headless) {\n\t\tif (!failed) {\n\t\t\tclearfits(gfit);"
assert text.count(needle) == 1
text = text.replace(needle, "if (com.headless) {\n\t\tif (!failed) {\n\t\t\tclose_single_image();")
# Whole variable tokens prevent I1 from contributing metadata merely because
# I10 appears. Statistics-only use is still a use of that variable's image.
needle = '\t\tconst gchar *test = g_strrstr(result, image[j]);\n\t\tif (test) {'
assert text.count(needle) == 1
text = text.replace(needle, '\t\tgchar *escaped = g_regex_escape_string(image[j], -1);\n'
    '\t\tgchar *pattern = g_strconcat("\\\\b", escaped, "\\\\b", NULL);\n'
    '\t\tgboolean used = g_regex_match_simple(pattern, result, 0, 0);\n'
    '\t\tg_free(pattern); g_free(escaped);\n\t\tif (used) {')
needle = '\t\t\t\t\tif (g_strcmp0(param, image[j]) == 0) {'
assert text.count(needle) == 1
text = text.replace(needle, needle + '\n\t\t\t\t\t\tvar_fit_mask[j] = TRUE;')
runner.write_text(text)

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

# Bridge desktop GUI geometry states that the command parser rejected: identity
# transforms, the GUI's full percentage range, and independent X/Y dimensions.
text = command.read_text()
start = text.index("int process_resample(")
end = text.index("int process_crop(", start)
resample = text[start:end]
resample = resample.replace("factor <= 0.2 || factor > 5.0", "factor < 0.01 || factor > 10.0")
resample = resample.replace("Should be between 0.2 and 5.0.", "Should be between 0.01 and 10.0.")
identity = '\t\tif (factor == 1.0) {\n\t\t\tsiril_log_message(_("Scale is 1.0. Not doing anything.\\n"));\n\t\t\treturn CMD_ARG_ERROR;\n\t\t}\n'
assert resample.count(identity) == 1
resample = resample.replace(identity, "")
branch = '\t\t} else if (!strcmp(word[i], "-noclamp")) {'
assert resample.count(branch) == 1
resample = resample.replace(branch, '\t\t} else if (g_str_has_prefix(word[i], "-height=")) {\n\t\t\ttoY = g_ascii_strtoull(word[i] + 8, &end, 10);\n\t\t\tif (end == word[i] + 8 || *end) return CMD_ARG_ERROR;\n' + branch)
guard = '\timage_cfa_warning_check();\n\tgui_iface.set_busy(TRUE);'
assert resample.count(guard) == 1
resample = resample.replace(guard, '''\tif (toX < 1 || toY < 1) return CMD_ARG_ERROR;
\tif (toX == gfit->rx && toY == gfit->ry) return CMD_OK;
#ifdef OS_IOS
\t/* Include output/copy/clamping buffers before allocating a large Mat. */
\tdouble required = (double)toX * toY * (gfit->naxes[2] * sizeof(float) + 4) * (clamp ? 5 : 3);
\tif (required > (double)get_available_memory() * 0.8) {
\t\tsiril_log_error("Not enough iPad processing memory for these output dimensions\\n");
\t\treturn CMD_ALLOC_ERROR;
\t}
#endif
''' + guard)
text = text[:start] + resample + text[end:]
start = text.index("int process_rotate(")
end = text.index("int process_rotatepi(", start)
rotation = text[start:end]
identity = '\t\tsiril_log_message(_("Angle is 0.0 or 360.0 degrees. Doing nothing...\\n"));\n\t\treturn CMD_ARG_ERROR;'
assert rotation.count(identity) == 1
rotation = rotation.replace(identity, '\t\tgui_iface.set_busy(FALSE);\n\t\treturn CMD_OK;')
command.write_text(text[:start] + rotation + text[end:])

# A script findstar normally frees its single-image results after reporting.
# The native star-mask workflow needs that selected-channel result, just as the
# desktop GUI does. Use the original locked ownership helpers; private/sequence
# callers keep their existing lifetime.
finder = source / "src/algos/star_finder.c"
text = finder.read_text()
old = "\telse if (!args->update_GUI)\n\t\tfree_fitted_stars(stars);"
assert text.count(old) == 1
text = text.replace(old, "\telse if (!args->update_GUI) {\n\t\tif (com.headless && !args->im.from_seq) replace_com_stars(stars);\n\t\telse free_fitted_stars(stars);\n\t}")
# Do not let a missing selected-channel result silently trigger the star-mask
# worker's green-channel fallback or reuse a previous single-image star list.
start = text.index("gpointer findstar_worker(")
empty = "\t} else {\n\t\tgoto END;\n\t}"
worker = text[start:]
assert worker.count(empty) == 1
worker = worker.replace(empty, "\t} else {\n\t\tif (com.headless && !args->im.from_seq && !args->stars) {\n\t\t\treplace_com_stars(NULL);\n\t\t\tretval = 1;\n\t\t}\n\t\tgoto END;\n\t}")
finder.write_text(text[:start] + worker)
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

# Keep the original FFTW kernels. Zero-amplitude spectra have zero modulus
# and a neutral phase; avoid 0/0 while retaining the actual DFTNORM=0.
fft = source / "src/filters/fft.c"
text = fft.read_text()
assert text.count("(modul[i] / maxi)") == 1
text = text.replace("(modul[i] / maxi)", "(maxi > 0.f ? modul[i] / maxi : 0.f)")
assert text.count("(modul[i] * USHRT_MAX_SINGLE / maxi)") == 1
text = text.replace("(modul[i] * USHRT_MAX_SINGLE / maxi)", "(maxi > 0.f ? modul[i] * USHRT_MAX_SINGLE / maxi : 0.f)")
# CP_COPYA copies pixels, not DFT keywords. The desktop helper accidentally
# overwrites ord twice and writes global gfit even when given an owned image.
start = text.index("static void save_dft_information_in_gfit(")
end = text.index("static void FFTD_ushort", start)
text = text[:start] + '''static void save_dft_information(fits *source, fits *target) {
    strcpy(target->keywords.dft.type, source->keywords.dft.type);
    strcpy(target->keywords.dft.ord, source->keywords.dft.ord);
    for (int i = 0; i < source->naxes[2]; i++)
        target->keywords.dft.norm[i] = source->keywords.dft.norm[i];
}

''' + text[end:]
assert text.count("save_dft_information_in_gfit(tmp1);") == 1
text = text.replace("save_dft_information_in_gfit(tmp1);", "save_dft_information(tmp1, fit);")
# Inverse output is spatial, not a spectrum. Original CP_FORMAT doesn't clear
# inherited DFT metadata from the opened magnitude image.
needle = "\t\t/* Copy inverse transform result into fit for display */"
assert text.count(needle) == 1
text = text.replace(needle, "\t\tmemset(&fit->keywords.dft, 0, sizeof(fit->keywords.dft));\n" + needle)
fft.write_text(text)

# RGB PSF data already includes kernelchannels in ndata. The desktop helper
# multiplies it again, reading outside the original kernel when saving RGB.
deconv = source / "src/filters/deconvolution.c"
text = deconv.read_text()
assert text.count("ndata * com.kernelchannels * sizeof(float)") == 2
text = text.replace("ndata * com.kernelchannels * sizeof(float)", "ndata * sizeof(float)")
# Propagate original algorithm failures rather than reporting unchanged pixels
# as a successful operation (e.g. RL on an empty/black channel).
for name in ("split_bregman", "naive_richardson_lucy", "fft_richardson_lucy", "wienerdec"):
    needle = name + "(args->fdata,"
    assert text.count(needle) == 1
    text = text.replace(needle, "retval = " + needle)
needle = "\t\tgettimeofday(&t_end, NULL);\n\t\tif (sequence_is_running == 0)"
assert text.count(needle) == 1
text = text.replace(needle, "\t\tif (retval) goto ENDDECONV;\n" + needle)
# PSF estimation must also propagate get_kernel/save_kernel failures.
start = text.index("gpointer estimate_only(gpointer p)")
end = text.index("gpointer deconvolve(gpointer p)", start)
body = text[start:end]
assert body.count("\tget_kernel(args);") == 1
body = body.replace("\tget_kernel(args);", "\tretval = get_kernel(args);\n\tif (retval) goto ENDEST;")
body = body.replace("\t\tsave_kernel(args->savepsf_filename, args);", "\t\tretval = save_kernel(args->savepsf_filename, args);")
text = text[:start] + body + text[end:]
# Kernel samples are in pixel coordinates. Angular FWHM is for presentation,
# not for generating a pixel PSF: adding focal-length metadata must not change it.
needle = "\t\tdouble fwhmx, fwhmy;\n\t\tchar *unit;\n\t\tget_fwhm_as_arcsec_if_possible(com.stars[i], &fwhmx, &fwhmy, &unit);"
# Pinned source uses one more tab inside its while loop.
needle = needle.replace("\t\t", "\t\t\t")
assert text.count(needle) == 1
text = text.replace(needle, "\t\t\tdouble fwhmx = com.stars[i]->fwhmx, fwhmy = com.stars[i]->fwhmy;")
deconv.write_text(text)

# Spectral irregularity originally assumes a 150px patch even for smaller
# valid images. Preserve 150px for large inputs and bound small-image sampling.
gf = source / "src/filters/deconvolution/gf_estimate.cpp"
text = gf.read_text()
needle = "    assert(blurredImage.d == 1);"
assert text.count(needle) == 1
text = text.replace(needle, needle + "\n    windowSize = std::min(windowSize, std::min(static_cast<int>(blurredImage.w), static_cast<int>(blurredImage.h)));\n")
gf.write_text(text)

# The original light-curve engine leaks its SNR scratch buffer and can enter
# GSL/plot operations with zero simultaneous valid target/reference frames.
# Preserve its reference selection and math; reject the empty dataset before
# allocations/plotting and release the same scratch buffers on every path.
photometry = source / "src/algos/photometry.c"
text = photometry.read_text()
start = text.index("int new_light_curve(")
end = text.index("static gboolean end_light_curve_worker", start)
body = text[start:end]
needle = "\tint nb_valid_images = j;"
assert body.count(needle) == 1
body = body.replace(needle, needle + "\n\tif (!nb_valid_images) {\n\t\tfree(date); free(vmag); free(err); free(snr_opt);\n\t\tfree_siril_plot_data(spl_data);\n\t\treturn -1;\n\t}\n")
needle = "\tfree(err);\n\treturn ret;"
assert body.count(needle) == 1
body = body.replace(needle, "\tfree(err);\n\tfree(snr_opt);\n\treturn ret;")
photometry.write_text(text[:start] + body + text[end:])
