// SPDX-License-Identifier: GPL-3.0-or-later
/* C ABI for the actual upstream Siril core. No desktop entry point is invoked. */
#include "SirilCore.h"
#include "core/siril.h"
#include "core/settings.h"
#include "core/arithm.h"
#include "io/image_format_fits.h"
#include "git-version.h"
#include <gsl/gsl_errno.h>
#include <stdio.h>
#include <string.h>

/* Upstream desktop entry points own these; the embedding app provides them. */
cominfo com;
fits *gfit = NULL;
struct SirilImage { fits fit; };
static GMutex engine_mutex;
static gsize initialized;

static void initialize(void) {
    if (g_once_init_enter(&initialized)) {
        com.headless = TRUE;
        com.script = TRUE;
        com.max_thread = 1;
        gsl_set_error_handler_off();
        initialize_default_settings();
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
    info->channels = (uint32_t)fit->naxes[2]; info->source_bitpix = fit->orig_bitpix;
    info->gain = fit->keywords.key_gain; info->offset = fit->keywords.key_offset;
    info->exposure = fit->keywords.exposure; info->temperature = fit->keywords.ccd_temp;
    snprintf(info->object, sizeof info->object, "%.*s", FLEN_VALUE, fit->keywords.object);
    snprintf(info->bayer, sizeof info->bayer, "%.*s", FLEN_VALUE, fit->keywords.bayer_pattern);
    g_mutex_unlock(&engine_mutex);
    return 1;
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
    g_mutex_lock(&engine_mutex);
    int ok = !g_file_test(path, G_FILE_TEST_EXISTS) && savefits(path, (fits *)&image->fit) == 0;
    g_mutex_unlock(&engine_mutex);
    return ok;
}
