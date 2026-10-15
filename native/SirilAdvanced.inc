// SPDX-License-Identifier: GPL-3.0-or-later
/* Mobile input/ownership adapters. Interpolation, color transforms and
 * expression evaluation remain in the pinned upstream implementations. */
#include "filters/curve_transform.h"
#include "algos/geometry.h"
#include "io/fits_keywords.h"
#include "pixelMath/pixel_math_runner.h"
#include "yyjson.h"
float siril_curve_tone(int channel, float r, float g, float b) {
    r = CLAMP(r, 0.f, 1.f); g = CLAMP(g, 0.f, 1.f); b = CLAMP(b, 0.f, 1.f);
    switch (channel) {
    case CHAN_R: return r; case CHAN_G: return g; case CHAN_B: return b;
    case CHAN_L: return curve_lab_L_norm(r, g, b);
    case CHAN_C: return curve_lab_chroma_norm(r, g, b);
    case CHAN_S: { float high = fmaxf(r, fmaxf(g, b));
        return high > 0 ? (high - fminf(r, fminf(g, b))) / high : 0; }
    default: return (r + g + b) / 3.f;
    }
}
int siril_image_curve_histograms(SirilImage *image, uint64_t *counts, size_t bins) {
    if (!image || !counts || bins < 2 || bins > 65536) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &image->fit;
    int ok = (fit->type == DATA_FLOAT && fit->fdata) || (fit->type == DATA_USHORT && fit->data);
    if (ok) {
        memset(counts, 0, CHAN_COUNT * bins * sizeof(uint64_t));
        size_t n = (size_t)fit->rx * fit->ry;
        float norm = get_normalized_value(fit);
        for (size_t i = 0; i < n; i++) {
            float r, g, b;
            if (fit->type == DATA_USHORT) {
                r = fit->pdata[0][i] / norm;
                g = fit->naxes[2] > 1 ? fit->pdata[1][i] / norm : r;
                b = fit->naxes[2] > 2 ? fit->pdata[2][i] / norm : r;
            } else {
                r = fit->fpdata[0][i];
                g = fit->naxes[2] > 1 ? fit->fpdata[1][i] : r;
                b = fit->naxes[2] > 2 ? fit->fpdata[2][i] : r;
            }
            for (int c = 0; c < CHAN_COUNT; c++) {
                float v = siril_curve_tone(c, r, g, b);
                if (isfinite(v)) {
                    size_t bin = MIN((size_t)(CLAMP(v, 0.f, 1.f) * bins), bins - 1);
                    counts[c * bins + bin]++;
                }
            }
        }
    }
    g_mutex_unlock(&engine_mutex); return ok;
}

static gboolean advanced_number(yyjson_val *object, const char *name,
        double low, double high, double *value) {
    yyjson_val *v = yyjson_obj_get(object, name);
    if (!yyjson_is_num(v)) return FALSE;
    *value = yyjson_get_num(v);
    return isfinite(*value) && *value >= low && *value <= high;
}
#include "SirilDeconvolution.inc"
static int advanced_region(fits *fit, yyjson_val *values, const char *prefix, rectangle *area) {
    double fields[4];
    const char *suffix[] = { "X", "Y", "Width", "Height" };
    for (int i = 0; i < 4; i++) {
        char key[32]; snprintf(key, sizeof key, "%s%s", prefix, suffix[i]);
        if (!advanced_number(values, key, 0, 100000, &fields[i]) || fields[i] != floor(fields[i])) return 0;
    }
    SirilRegion input = { (int32_t)fields[0], (int32_t)fields[1], (int32_t)fields[2], (int32_t)fields[3] };
    return displayed_region(fit, &input, area);
}
static int advanced_apply_preview_region(SirilImage *image, yyjson_val *root) {
    rectangle area;
    if (!advanced_region(&image->fit, yyjson_obj_get(root, "values"), "preview", &area)) return 0;
    if (yyjson_get_bool(yyjson_obj_get(root, "externalGuide"))) {
        // Keep the guide's original bit depth: guided-filter epsilon depends
        // on its numeric scale. Only the detached science image is promoted.
        fits guide = {0}; rectangle guide_area;
        int ok = !readfits("guide.fits", &guide, NULL, FALSE) &&
            guide.rx == image->fit.rx && guide.ry == image->fit.ry &&
            advanced_region(&guide, yyjson_obj_get(root, "values"), "preview", &guide_area);
        if (ok) {
            clear_Bayer_information(&guide);
            ok = !crop(&guide, &guide_area) && !savefits("preview-guide.fits", &guide);
        }
        clearfits(&guide);
        if (!ok) return 0;
    }
    // GUI populate_roi copies exactly the selected raster, including odd CFA
    // coordinates. Geometry crop's Bayer alignment is not a preview operation.
    clear_Bayer_information(&image->fit);
    return crop(&image->fit, &area) == 0;
}
static int advanced_apply_color(SirilImage *image, yyjson_val *root) {
    fits *fit = &image->fit;
    yyjson_val *values = yyjson_obj_get(root, "values");
    double mode, low, high, kw[3] = {0}, bg[3] = { NAN, NAN, NAN };
    rectangle black, white;
    if (fit->naxes[2] != 3 || fit->type != DATA_FLOAT ||
            !advanced_number(values, "operation", 0, 2, &mode) || mode != floor(mode)) return 0;
    if (mode == 0) {
        const char *keys[] = { "red", "green", "blue" };
        for (int c = 0; c < 3; c++) {
            if (!advanced_number(values, keys[c], 0, 1, &kw[c])) return 0;
            bg[c] = 0;
        }
    } else {
        if (!advanced_region(fit, values, "background", &black)) return 0;
        for (int c = 0; c < 3; c++) {
            imstats *stat = statistics(NULL, -1, fit, c, &black, STATS_BASIC, MULTI_THREADED);
            int valid = stat && isfinite(stat->mean) && isfinite(stat->median);
            if (stat) free_stats(stat);
            if (!valid) return 0;
        }
        if (mode == 1) {
            background_neutralize(fit, black);
            return !g_atomic_int_get(&cancel_requested);
        }
        if (!advanced_region(fit, values, "white", &white) ||
                !advanced_number(values, "low", 0, 1, &low) ||
                !advanced_number(values, "high", 0, 1, &high) || low >= high) return 0;
        // The original void API does not report an empty rejected selection.
        // Check it before calling the original coefficient computation.
        for (int c = 0; c < 3; c++) {
            size_t valid = 0;
            for (int y = 0; y < white.h; y++) {
                float *row = fit->fpdata[c] + (size_t)(fit->ry - white.y - white.h + y) * fit->rx + white.x;
                for (int x = 0; x < white.w; x++) if (row[x] > low && row[x] < high) valid++;
            }
            if (!valid) return 0;
        }
        get_coeff_for_wb(fit, white, black, kw, bg, get_normalized_value(fit), low, high);
        for (int c = 0; c < 3; c++) if (!isfinite(kw[c]) || kw[c] <= 0 || !isfinite(bg[c])) return 0;
    }
    for (int c = 0; c < 3; c++) if (calibrate(fit, c, kw[c], bg[c], get_normalized_value(fit))) return 0;
    invalidate_stats_from_fit(fit);
    return !g_atomic_int_get(&cancel_requested);
}
static struct curve_params *advanced_curve(yyjson_val *stage) {
    double algorithm;
    yyjson_val *channels = yyjson_obj_get(stage, "channels");
    if (!advanced_number(stage, "algorithm", 0, 2, &algorithm) ||
            algorithm != floor(algorithm) || yyjson_arr_size(channels) != CHAN_COUNT) return NULL;
    struct curve_params *params = new_curve_params();
    if (!params) return NULL;
    params->algorithm = (int)algorithm;
    for (int c = 0; c < CHAN_COUNT; c++) {
        yyjson_val *channel = yyjson_arr_get(channels, c);
        yyjson_val *points = yyjson_obj_get(channel, "points");
        size_t count = yyjson_arr_size(points);
        double low, high, feather;
        if (count < 2 || count > MAX_POINTS ||
                !advanced_number(channel, "low", 0, 1, &low) ||
                !advanced_number(channel, "high", low, 1, &high) ||
                !advanced_number(channel, "feather", 0, 1, &feather)) goto fail;
        curve_channel_config *cfg = &params->channels[c];
        cfg->range_enabled = yyjson_get_bool(yyjson_obj_get(channel, "rangeEnabled"));
        cfg->lum_min = low; cfg->lum_max = high; cfg->feather = feather;
        double previous = -1;
        for (size_t i = 0; i < count; i++) {
            double x, y;
            yyjson_val *v = yyjson_arr_get(points, i);
            if (!advanced_number(v, "x", 0, 1, &x) ||
                    !advanced_number(v, "y", 0, 1, &y) || x <= previous ||
                    (i == 0 && x != 0) || (i == count - 1 && x != 1)) goto fail;
            point *p = g_try_new(point, 1);
            if (!p) goto fail;
            p->x = x; p->y = y;
            cfg->points = g_list_append(cfg->points, p); previous = x;
        }
        cfg->active = TRUE; /* Original kernel detects the identity itself. */
    }
    return params;
fail:
    free_curve_params(params);
    return NULL;
}
int siril_curve_plot(const char *json, int channel, float *samples, size_t count) {
    if (!json || !samples || channel < 0 || channel >= CHAN_COUNT || count < 2 || count > 4096) return 0;
    yyjson_doc *doc = yyjson_read(json, strlen(json), 0);
    if (!doc) return 0;
    g_mutex_lock(&engine_mutex);
    struct curve_params *params = advanced_curve(yyjson_doc_get_root(doc));
    int ok = params != NULL;
    if (params) {
        GList *points = params->channels[channel].points;
        double slopes[MAX_POINTS] = {0};
        cubic_spline_data cubic = {0}; akima_spline_data akima = {0};
        if (params->algorithm == LINEAR) linear_fit(points, slopes);
        else if (params->algorithm == AKIMA_SPLINE) akima_spline_fit(points, &akima);
        else cubic_spline_fit(points, &cubic);
        for (size_t i = 0; i < count; i++) {
            float x = (float)i / (count - 1);
            samples[i] = params->algorithm == LINEAR ? linear_interpolate(x, points, slopes) :
                params->algorithm == AKIMA_SPLINE ? akima_spline_interpolate(x, &akima) : cubic_spline_interpolate(x, &cubic);
        }
        free_curve_params(params);
    }
    g_mutex_unlock(&engine_mutex); yyjson_doc_free(doc);
    return ok;
}
static int advanced_apply_curves(SirilImage *image, yyjson_val *root,
        int preview, int64_t *clipped) {
    yyjson_val *stages = yyjson_obj_get(root, "stages");
    yyjson_val *current = yyjson_obj_get(root, "current");
    double selected;
    size_t count = yyjson_arr_size(stages);
    if (count > 30 || !advanced_number(root, "selectedChannel", 0, 6, &selected) ||
            selected != floor(selected)) return 0;
    for (size_t i = 0; i <= count; i++) {
        if (g_atomic_int_get(&cancel_requested)) return 0;
        struct curve_params *params = advanced_curve(i == count ? current : yyjson_arr_get(stages, i));
        if (!params) return 0;
        long clip[2] = {0}; params->clipped_count = clip;
        params->target_channel = (int)selected;
        params->for_preview = preview && i == count; params->show_mask = params->for_preview;
        struct generic_img_args args = { .user = params };
        int ok = curve_image_hook(&args, &image->fit, 1) == 0;
        if (clipped) { clipped[0] += clip[0]; clipped[1] += clip[1]; }
        free_curve_params(params);
        if (!ok) return 0;
    }
    invalidate_stats_from_fit(&image->fit);
    return 1;
}
static gboolean advanced_symbol(const gchar *name) {
    if (!name || !*name || strlen(name) > 64 ||
            !(g_ascii_isalpha(*name) || *name == '_') ||
            !strcmp(name, "gfit") || !strcmp(name, "T") || !strcmp(name, "e") || !strcmp(name, "pi")) return FALSE;
    for (const gchar *p = name; *p; p++) if (!g_ascii_isalnum(*p) && *p != '_') return FALSE;
    return TRUE;
}
static int advanced_apply_pm(SirilImage *image, yyjson_val *root) {
    yyjson_val *expressions = yyjson_obj_get(root, "expressions");
    yyjson_val *bindings = yyjson_obj_get(root, "bindings");
    size_t count = yyjson_arr_size(bindings);
    gboolean single = yyjson_get_bool(yyjson_obj_get(root, "singleRGB"));
    double low, high;
    if (count > (size_t)pm_get_max_images() || yyjson_arr_size(expressions) != 3 ||
            !advanced_number(root, "low", 0, 1, &low) ||
            !advanced_number(root, "high", low, 1, &high)) return 0;
    double required = (double)image->fit.rx * image->fit.ry * sizeof(float) *
        (image->fit.naxes[2] * (count + 3) + 3);
    if (required > (double)get_available_memory() * 0.8) {
        capture_log("Not enough remaining iPad memory for PixelMath inputs/output.\n", NULL); return 0;
    }
    close_sequence(FALSE); close_single_image(); free_pm_var(pm_get_max_images());
    com.pref.force_16bit = FALSE;
    if (copyfits(&image->fit, gfit, CP_ALLOC | CP_DEEPCOPY | CP_COPYMASK, 0)) return 0;
    create_uniq_from_gfit(g_strdup("Native PixelMath input"), FALSE);
    struct pixel_math_data *args = g_try_new0(struct pixel_math_data, 1);
    if (!args) goto done;
    args->single_rgb = single; args->do_sum = yyjson_get_bool(yyjson_obj_get(root, "doSum"));
    args->rescale = yyjson_get_bool(yyjson_obj_get(root, "rescale"));
    args->min = low; args->max = high;
    args->nb_rows = (int)count;
    args->varname = g_new0(gchar *, count);
    gchar **dest[3] = { &args->expression1, &args->expression2, &args->expression3 };
    for (int c = 0; c < (single ? 1 : 3); c++) {
        const char *text = yyjson_get_str(yyjson_arr_get(expressions, c));
        if (!text || !*text || strlen(text) > 16384) goto fail;
        *dest[c] = g_strdup(text); remove_spaces_from_str(*dest[c]);
    }
    if (replace_t_with_gfit(args) && !single) goto fail;
    /* A constant expression still operates on the currently opened image. */
    if (!count && single) args->has_gfit = TRUE;
    if (!single && !count) goto fail;
    for (size_t i = 0; i < count; i++) {
        yyjson_val *item = yyjson_arr_get(bindings, i);
        const char *name = yyjson_get_str(yyjson_obj_get(item, "name"));
        const char *path = yyjson_get_str(yyjson_obj_get(item, "path"));
        if (!advanced_symbol(name) || !path || !*path) goto fail;
        for (size_t j = 0; j < i; j++) if (!strcmp(name, args->varname[j])) goto fail;
        args->varname[i] = g_strdup(name);
        int w, h, c;
        if (load_pm_var(path, i, &w, &h, &c) || w != image->fit.rx || h != image->fit.ry ||
                (!single && c != 1) ||
                (i && c != var_fit[0].naxes[2]) ||
                (args->has_gfit && c != gfit->naxes[2])) {
            capture_log("PixelMath variables must have matching dimensions/channels; three-expression RGB composition requires mono inputs.\n", NULL);
            goto fail;
        }
    }
    int channels = single ? (count ? var_fit[0].naxes[2] : image->fit.naxes[2]) : 3;
    if (new_fit_image(&args->fit, image->fit.rx, image->fit.ry, channels, DATA_FLOAT)) goto fail;
    int failed = GPOINTER_TO_INT(apply_pixel_math_operation(args));
    args = NULL; /* Original worker owns its inputs/strings/output struct. */
    if (!failed) icc_auto_assign(gfit, ICC_ASSIGN_ON_COMPOSITION);
    if (!failed && copyfits(gfit, &image->fit, CP_ALLOC | CP_DEEPCOPY | CP_COPYMASK, 0) == 0) {
        close_single_image(); return 1;
    }
    goto done;
fail:
    if (args) {
        for (int c = 0; c < 3; c++) g_free(*dest[c]);
        for (size_t i = 0; i < count; i++) g_free(args->varname[i]);
        g_free(args->varname);
        if (args->fit) { clearfits(args->fit); g_free(args->fit); }
        g_free(args);
    }
done:
    free_pm_var(pm_get_max_images()); close_single_image();
    return 0;
}
#include "filters/fft.h"
static int advanced_apply_fft(SirilImage *image, yyjson_val *root) {
    gboolean inverse = yyjson_get_bool(yyjson_obj_get(root, "inverse"));
    const char *modulus = yyjson_get_str(yyjson_obj_get(root, "modulus"));
    const char *phase = yyjson_get_str(yyjson_obj_get(root, "phase"));
    double order;
    if (!modulus || !*modulus || !phase || !*phase || !strcmp(modulus, phase) ||
            !advanced_number(root, "order", 0, 1, &order) || order != floor(order)) return 0;
    /* The original worker holds spatial/frequency planes and both spectra.
     * Account for them before allocating, including already-owned previews. */
    double required = (double)image->fit.rx * image->fit.ry *
        (image->fit.naxes[2] * 4 * sizeof(float) + 2 * sizeof(fftwf_complex) + 2 * sizeof(float));
    if (required > (double)get_available_memory() * 0.8) {
        capture_log("Not enough remaining iPad memory for FFT spectra/work buffers.\n", NULL); return 0;
    }
    fits a = {0}, p = {0};
    int valid = 1;
    if (inverse) {
        valid = !readfits(modulus, &a, NULL, FALSE) && !readfits(phase, &p, NULL, FALSE);
        if (valid) valid = a.rx == p.rx && a.ry == p.ry && a.naxes[2] == p.naxes[2] &&
            a.rx == image->fit.rx && a.ry == image->fit.ry && a.naxes[2] == image->fit.naxes[2] &&
            a.bitpix == p.bitpix && a.type == p.type &&
            (a.type == DATA_FLOAT || a.type == DATA_USHORT) &&
            !strcmp(a.keywords.dft.type, "SPECTRUM") && !strcmp(p.keywords.dft.type, "PHASE") &&
            (!strcmp(a.keywords.dft.ord, "CENTERED") || !strcmp(a.keywords.dft.ord, "REGULAR")) &&
            !strcmp(a.keywords.dft.ord, p.keywords.dft.ord);
        if (valid) for (int c = 0; c < a.naxes[2]; c++)
            {
                gchar *key = g_strdup_printf("DFTNORM%d", c + 1);
                if (!a.header || !strstr(a.header, key) || !isfinite(a.keywords.dft.norm[c]) || a.keywords.dft.norm[c] < 0) valid = 0;
                g_free(key);
            }
        if (valid && a.type == DATA_FLOAT) {
            size_t n = (size_t)a.rx * a.ry * a.naxes[2];
            for (size_t i = 0; i < n; i++) if (!isfinite(a.fdata[i]) || !isfinite(p.fdata[i])) { valid = 0; break; }
        }
        // Retain the original integer inverse algorithm/rounding for desktop
        // spectra. Convert only its spatial result to the shared float ABI.
        if (valid && a.type == DATA_USHORT)
            valid = copyfits(&a, &image->fit, CP_ALLOC | CP_DEEPCOPY, 0) == 0;
        clearfits(&a); clearfits(&p);
        if (!valid) {
            capture_log("FFT needs matching SPECTRUM/PHASE dimensions, channels, depth, order and finite normalization.\n", NULL);
            return 0;
        }
    }
    if (g_atomic_int_get(&cancel_requested)) return 0;
    struct fft_data args = { .fit = &image->fit, .type = inverse ? "ffti" : "fftd",
        .modulus = (gchar *)modulus, .phase = (gchar *)phase, .type_order = (int)order };
    struct generic_img_args worker = { .user = &args };
    int ok = fft_image_hook(&worker, &image->fit, 1) == 0;
    if (ok && image->fit.type == DATA_USHORT) ok = soper(&image->fit, 1.f, OPER_MUL, TRUE) == 0;
    if (!inverse && ok) {
        valid = !readfits(modulus, &a, NULL, FALSE) && !readfits(phase, &p, NULL, FALSE);
        if (valid) {
            size_t n = (size_t)a.rx * a.ry * a.naxes[2];
            for (size_t i = 0; i < n; i++) if (!isfinite(a.fdata[i]) || !isfinite(p.fdata[i])) { valid = 0; break; }
        }
        clearfits(&a); clearfits(&p); ok = valid;
    }
    return ok && !g_atomic_int_get(&cancel_requested);
}
int siril_image_advanced(SirilImage *image, const char *json, int preview,
        int64_t *clipped, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (clipped) clipped[0] = clipped[1] = 0;
    if (!image || image->fit.type != DATA_FLOAT || !image->fit.fdata || !json || strlen(json) > 2 * 1024 * 1024) return 0;
    yyjson_doc *doc = yyjson_read(json, strlen(json), 0);
    if (!doc) return 0;
    yyjson_val *root = yyjson_doc_get_root(doc);
    const char *kind = yyjson_get_str(yyjson_obj_get(root, "kind"));
    g_mutex_lock(&engine_mutex);
    initialize();
    int ok = kind && (!strcmp(kind, "curves") ? advanced_apply_curves(image, root, preview, clipped) :
        !strcmp(kind, "deconvolution") && !preview ? advanced_apply_deconv(image, root) :
        !strcmp(kind, "fft") && !preview ? advanced_apply_fft(image, root) :
        !strcmp(kind, "pixelMath") && !preview ? advanced_apply_pm(image, root) :
        !strcmp(kind, "colorCalibration") && !preview ? advanced_apply_color(image, root) :
        !strcmp(kind, "previewRegion") && !preview ? advanced_apply_preview_region(image, root) : 0);
    if (ok) {
        size_t count = (size_t)image->fit.rx * image->fit.ry * image->fit.naxes[2];
        for (size_t i = 0; i < count; i++) if (!isfinite(image->fit.fdata[i])) { ok = 0; break; }
    }
    if (g_atomic_int_get(&cancel_requested)) ok = 0;
    if (!ok && error && capacity) snprintf(error, capacity,
        "Original %s computation failed, was cancelled, or returned nonfinite pixels; see the processing log",
        kind ? kind : "advanced tool");
    g_mutex_unlock(&engine_mutex); yyjson_doc_free(doc);
    return ok;
}
static int run_advanced_locked(const char *path, char *error, size_t capacity) {
    if (!path || !gfit) return 0;
    // set32bits controls output precision but load retains integer input.
    // Promote the detached command image with the original bit-depth converter.
    if (gfit->type == DATA_USHORT && gfit->data && soper(gfit, 1.f, OPER_MUL, TRUE)) return 0;
    if (gfit->type != DATA_FLOAT || !gfit->fdata) return 0;
    if ((double)gfit->rx * gfit->ry * gfit->naxes[2] * sizeof(float) * 3 >
            (double)get_available_memory() * 0.8) return 0;
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    int ok = 0;
    gchar *json = NULL;
    SirilImage image = {0};
    yyjson_doc *doc = NULL;
    if (fseek(file, 0, SEEK_END)) goto done;
    long size = ftell(file);
    if (size <= 0 || size > 2 * 1024 * 1024 || fseek(file, 0, SEEK_SET)) goto done;
    json = g_try_malloc(size + 1);
    if (!json || fread(json, 1, size, file) != (size_t)size) goto done;
    json[size] = 0;
    doc = yyjson_read(json, size, 0);
    if (!doc || copyfits(gfit, &image.fit, CP_ALLOC | CP_DEEPCOPY | CP_COPYMASK, 0)) goto done;
    yyjson_val *root = yyjson_doc_get_root(doc);
    const char *kind = yyjson_get_str(yyjson_obj_get(root, "kind"));
    int64_t clip[2] = {0};
    ok = kind && (!strcmp(kind, "curves") ? advanced_apply_curves(&image, root, 0, clip) :
        !strcmp(kind, "deconvolution") ? advanced_apply_deconv(&image, root) :
        !strcmp(kind, "fft") ? advanced_apply_fft(&image, root) :
        !strcmp(kind, "pixelMath") ? advanced_apply_pm(&image, root) :
        !strcmp(kind, "colorCalibration") ? advanced_apply_color(&image, root) :
        !strcmp(kind, "previewRegion") ? advanced_apply_preview_region(&image, root) : 0);
    if (ok) {
        size_t n = (size_t)image.fit.rx * image.fit.ry * image.fit.naxes[2];
        for (size_t i = 0; i < n; i++) if (!isfinite(image.fit.fdata[i])) { ok = 0; break; }
    }
    if (ok && !g_atomic_int_get(&cancel_requested)) {
        ok = copyfits(&image.fit, gfit, CP_ALLOC | CP_DEEPCOPY | CP_COPYMASK, 0) == 0;
        if (ok && !com.uniq) create_uniq_from_gfit(g_strdup("Native advanced result"), FALSE);
        gchar *history = g_strdup_printf("Original %s; curve clipped low/high: %lld/%lld",
            kind, (long long)clip[0], (long long)clip[1]);
        gfit->history = g_slist_append(gfit->history, g_strdup(history));
        capture_log(history, NULL); capture_log("\n", NULL); g_free(history);
        update_fits_header(gfit);
    } else ok = 0;
done:
    if (!ok && error && capacity) snprintf(error, capacity, "Advanced original worker/settings failed");
    clearfits(&image.fit); if (doc) yyjson_doc_free(doc);
    g_free(json); fclose(file);
    return ok;
}
