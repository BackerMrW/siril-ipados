// SPDX-License-Identifier: GPL-3.0-or-later
/* C ABI for the actual upstream Siril core. No desktop entry point is invoked. */
#include "SirilCore.h"
#include "core/siril.h"
#include "core/settings.h"
#include "core/arithm.h"
#include "io/image_format_fits.h"
#include "filters/mtf.h"
#include "algos/siril_random.h"
#include "git-version.h"
#include "core/command_line_processor.h"
#include "core/command.h"
#include "core/processing_thread.h"
#include "core/gui_iface.h"
#include "core/proto.h"
#include "core/icc_profile.h"
#include "core/siril_log.h"
#include "io/sequence.h"
#include "io/conversion.h"
#include <gsl/gsl_errno.h>
#include <fftw3.h>
#include <stdio.h>
#include <string.h>

/* Upstream desktop entry points own these; the embedding app provides them. */
cominfo com;
fits *gfit = NULL;
struct SirilImage { fits fit; };
static GMutex engine_mutex;
static gsize initialized;
static GMutex log_mutex;
static GString *processing_log;
static gint cancel_requested;

static void capture_log(const char *message, const char *color) {
    (void)color;
    if (!message) return;
    g_mutex_lock(&log_mutex);
    if (!processing_log) processing_log = g_string_new(NULL);
    g_string_append(processing_log, message);
    if (processing_log->len > 128 * 1024) {
        size_t skip = processing_log->len - 96 * 1024;
        while (skip < processing_log->len && (processing_log->str[skip] & 0xc0) == 0x80) skip++;
        g_string_erase(processing_log, 0, skip);
    }
    g_mutex_unlock(&log_mutex);
}

static void embedded_quit(void) {
    capture_log("Desktop exit is unavailable inside an iPad App.\n", NULL);
}

static void initialize(void) {
    if (g_once_init_enter(&initialized)) {
        com.headless = TRUE;
        com.script = TRUE;
        com.max_thread = 1;
        gsl_set_error_handler_off();
        siril_initialize_rng();
        initialize_default_settings();
#if defined(HAVE_FFTW3F_THREADS) || defined(HAVE_FFTW3F_OMP)
        fftwf_init_threads();
#endif
        com.pref.memory_ratio = 0.5;
        gfit = g_new0(fits, 1);
        initialize_sequence(&com.seq, TRUE);
        processing_system_init();
        g_free(initialize_converters());
        gui_iface.log_message = capture_log;
        gui_iface.quit_application = embedded_quit;
        initialize_profiles_and_transforms();
        g_once_init_leave(&initialized, 1);
    }
}
const char *siril_core_version(void) { return "Siril " VERSION "-" SIRIL_GIT_VERSION_ABBREV; }

SirilImage *siril_image_read(const char *path, char *error, size_t error_size) {
    if (error && error_size) error[0] = 0;
    if (!path) return NULL;
    g_mutex_lock(&engine_mutex);
    initialize();
    SirilImage *image = g_try_new0(SirilImage, 1);
    if (!image || readfits(path, &image->fit, NULL, TRUE) != 0) {
        if (image) { clearfits(&image->fit); g_free(image); }
        image = NULL;
        if (error && error_size) snprintf(error, error_size, "Siril could not read this FITS file");
    }
    g_mutex_unlock(&engine_mutex);
    return image;
}
void siril_image_free(SirilImage *image) {
    if (!image) return;
    g_mutex_lock(&engine_mutex);
    clearfits(&image->fit);
    g_free(image);
    g_mutex_unlock(&engine_mutex);
}
int siril_image_info(const SirilImage *image, SirilImageInfo *info) {
    if (!image || !info) return 0;
    g_mutex_lock(&engine_mutex);
    const fits *fit = &image->fit;
    memset(info, 0, sizeof *info);
    info->width = fit->rx; info->height = fit->ry;
    info->channels = (uint32_t)fit->naxes[2]; info->working_bitpix = fit->orig_bitpix;
    info->gain = fit->keywords.key_gain; info->offset = fit->keywords.key_offset;
    info->exposure = fit->keywords.exposure; info->temperature = fit->keywords.ccd_temp;
    snprintf(info->object, sizeof info->object, "%.*s", FLEN_VALUE, fit->keywords.object);
    snprintf(info->bayer, sizeof info->bayer, "%.*s", FLEN_VALUE, fit->keywords.bayer_pattern);
    g_mutex_unlock(&engine_mutex);
    return 1;
}
int siril_image_preview(SirilImage *image, uint32_t max_dimension, SirilPreview *preview) {
    if (!image || !preview || !max_dimension || max_dimension > 2048) return 0;
    memset(preview, 0, sizeof *preview);
    g_mutex_lock(&engine_mutex);
    fits *fit = &image->fit;
    int ok = 0;
    struct mtf_params params;
    if (fit->type != DATA_FLOAT || !fit->rx || !fit->ry ||
        find_linked_midtones_balance_default(fit, &params) != 0) goto done;
    double scale = fmin(1.0, (double)max_dimension / fmax(fit->rx, fit->ry));
    uint32_t w = fmax(1, floor(fit->rx * scale));
    uint32_t h = fmax(1, floor(fit->ry * scale));
    uint8_t *pixels = g_try_malloc_n((size_t)w * h, 4);
    if (!pixels) goto done;
    for (uint32_t y = 0; y < h; y++) {
        uint32_t sy = (uint64_t)y * fit->ry / h;
        if (!fit->top_down) sy = fit->ry - 1 - sy;
        for (uint32_t x = 0; x < w; x++) {
            size_t source = (size_t)sy * fit->rx + (uint64_t)x * fit->rx / w;
            size_t target = ((size_t)y * w + x) * 4;
            for (unsigned c = 0; c < 3; c++) {
                unsigned channel = fit->naxes[2] == 3 ? c : 0;
                float value = MTFp(fit->fpdata[channel][source], params);
                pixels[target + c] = isfinite(value) ? (uint8_t)lroundf(fminf(1, fmaxf(0, value)) * 255) : 0;
            }
            pixels[target + 3] = 255;
        }
    }
    preview->width = w; preview->height = h; preview->rgba = pixels;
    ok = 1;
done:
    g_mutex_unlock(&engine_mutex);
    return ok;
}
void siril_preview_free(SirilPreview *preview) {
    if (!preview) return;
    g_free(preview->rgba);
    memset(preview, 0, sizeof *preview);
}
static int operate(SirilImage *a, const SirilImage *b, image_operator op) {
    if (!a || !b || a == b) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = imoper(&a->fit, (fits *)&b->fit, op, TRUE) == 0;
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_image_add(SirilImage *a, const SirilImage *b) { return operate(a, b, OPER_ADD); }
int siril_image_subtract(SirilImage *a, const SirilImage *b) { return operate(a, b, OPER_SUB); }
int siril_image_divide_scalar(SirilImage *image, float divisor) {
    if (!image || !isfinite(divisor) || divisor <= 0) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = soper(&image->fit, divisor, OPER_DIV, TRUE) == 0;
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_image_write(const SirilImage *image, const char *path) {
    if (!image || !path) return 0;
    /* Upstream savefits adds/rewrites suffixes. Require an exact output path
     * so our existing-file check protects the actual destination. */
    if (!g_str_has_suffix(path, ".fit") && !g_str_has_suffix(path, ".fits") &&
        !g_str_has_suffix(path, ".fts")) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = !g_file_test(path, G_FILE_TEST_EXISTS) && savefits(path, (fits *)&image->fit) == 0;
    g_mutex_unlock(&engine_mutex);
    return ok;
}

void siril_copy_processing_log(char *buffer, size_t capacity) {
    if (!buffer || !capacity) return;
    g_mutex_lock(&log_mutex);
    g_strlcpy(buffer, processing_log ? processing_log->str : "", capacity);
    g_mutex_unlock(&log_mutex);
}

void siril_cancel_processing(void) {
    g_atomic_int_set(&cancel_requested, 1);
    processing_request_cancel();
}

int siril_run_commands(const char *directory, const char *script, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!directory || !script) return 0;
    g_mutex_lock(&engine_mutex);
    initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    int ok = 0;
    gchar *directory_error = NULL;
    if (siril_change_dir(directory, &directory_error)) {
        if (error && capacity) snprintf(error, capacity, "Working directory: %s", directory_error ? directory_error : directory);
        /* siril_change_dir returns a borrowed pointer to the upstream log. */
        goto done;
    }
    /* Windows-authored UTF-8 .ssf files may include a byte order mark. */
    if (g_str_has_prefix(script, "\xef\xbb\xbf")) script += 3;
    gchar **lines = g_strsplit(script, "\n", -1);
    ok = 1;
    for (size_t i = 0; lines[i]; i++) {
        char *line = g_strstrip(lines[i]);
        if (!*line || *line == '#') continue;
        if (g_atomic_int_get(&cancel_requested)) {
            if (error && capacity) snprintf(error, capacity, "Processing cancelled before line %zu", i + 1);
            ok = 0;
            break;
        }
        /* Use the upstream parser even for command identification. '@' would
         * launch a detached script thread; users import the script text instead. */
        gchar *parsed = g_strdup(line);
        int count = 0;
        parse_line(parsed, strlen(parsed), &count);
        gboolean unsupported = line[0] == '@' || (count &&
            (!g_ascii_strcasecmp(word[0], "exit") || !g_ascii_strcasecmp(word[0], "livestack") ||
             !g_ascii_strcasecmp(word[0], "stop_ls")));
        g_free(parsed);
        int result = unsupported ? CMD_NOT_SCRIPTABLE : processcommand(line, TRUE);
        if (result || g_atomic_int_get(&cancel_requested)) {
            if (error && capacity) snprintf(error, capacity, "Line %zu: %s (%s)", i + 1,
                line, g_atomic_int_get(&cancel_requested) ? "cancelled" : cmd_err_to_str(result));
            ok = 0;
            break;
        }
    }
    g_strfreev(lines);
done:
    if (!ok && error && capacity && error[0]) capture_log(error, NULL);
    g_mutex_unlock(&engine_mutex);
    return ok;
}
