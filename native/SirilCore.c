// SPDX-License-Identifier: GPL-3.0-or-later
/* C ABI for the actual upstream Siril core. No desktop entry point is invoked. */
#include "SirilCore.h"
#include "core/siril.h"
#include "core/settings.h"
#include "core/arithm.h"
#include "io/image_format_fits.h"
#include "filters/mtf.h"
#include "algos/siril_random.h"
#include "algos/background_extraction.h"
#include "algos/demosaicing.h"
#include "core/processing.h"
#include "algos/statistics.h"
#include "git-version.h"
#include "core/command_line_processor.h"
#include "core/command.h"
#include "core/processing_thread.h"
#include "core/gui_iface.h"
#include "core/proto.h"
#include "core/icc_profile.h"
#include "core/siril_log.h"
#include "core/OS_utils.h"
#include "io/sequence.h"
#include "io/single_image.h"
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

static sequence *embedded_sequence(const char *directory, const char *name, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!directory || !name || !*name || strchr(name, '/') || strchr(name, '\\') || !g_str_has_suffix(name, ".seq")) {
        if (error && capacity) snprintf(error, capacity, "Invalid sequence basename");
        return NULL;
    }
    gchar *message = NULL;
    if (siril_change_dir(directory, &message)) {
        if (error && capacity) snprintf(error, capacity, "Cannot open sequence directory");
        return NULL;
    }
    sequence *seq = readseqfile(name);
    if (!seq) { if (error && capacity) snprintf(error, capacity, "Cannot read sequence %s", name); return NULL; }
    gchar *base = g_strndup(name, strlen(name) - 4);
    gboolean matching = seq->seqname && !strcmp(seq->seqname, base);
    g_free(base);
    if (!matching || seq->number < 1 || seq_check_basic_data(seq, FALSE) < 0 || seq->nb_layers < 1 || seq->nb_layers > 3) {
        if (error && capacity) snprintf(error, capacity, "Invalid or unavailable sequence data");
        free_sequence(seq, TRUE);
        return NULL;
    }
    return seq;
}
int siril_sequence_inspect(const char *directory, const char *name, int layer,
    SirilSequenceInfo *info, SirilSequenceFrame *frames, size_t capacity, char *error, size_t error_size) {
    g_mutex_lock(&engine_mutex);
    initialize();
    sequence *seq = embedded_sequence(directory, name, error, error_size);
    int count = -1;
    if (!seq) goto done;
    if (layer < 0 || layer >= seq->nb_layers || (frames && capacity < (size_t)seq->number)) {
        if (error && error_size) snprintf(error, error_size, "Invalid sequence layer or frame capacity");
        goto free_seq;
    }
    count = seq->number;
    if (info) *info = (SirilSequenceInfo){seq->number, seq->selnum, seq->nb_layers, seq->reference_image,
        seq->rx, seq->ry, seq->is_drizzle, seq->type};
    if (frames) for (int i = 0; i < seq->number; i++) {
        SirilSequenceFrame *frame = &frames[i];
        memset(frame, 0, sizeof *frame);
        frame->index = i; frame->file_number = seq->imgparam[i].filenum;
        frame->included = seq->imgparam[i].incl;
        frame->width = seq->is_variable ? seq->imgparam[i].rx : seq->rx;
        frame->height = seq->is_variable ? seq->imgparam[i].ry : seq->ry;
        if (seq->regparam && seq->regparam[layer]) {
            regdata *reg = &seq->regparam[layer][i];
            frame->has_registration = reg->fwhm > 0 || reg->H.h22 != 0;
            frame->fwhm = reg->fwhm; frame->weighted_fwhm = reg->weighted_fwhm;
            frame->roundness = reg->roundness; frame->background = reg->background_lvl;
            frame->quality = reg->quality; frame->stars = reg->number_of_stars;
            frame->translation_x = reg->H.h02; frame->translation_y = reg->H.h12;
        }
        if (seq->stats && seq->stats[layer] && seq->stats[layer][i]) {
            imstats *stat = seq->stats[layer][i];
            double norm = stat->normValue > 0 ? stat->normValue : (seq->bitpix == FLOAT_IMG ? 1 : USHRT_MAX_DOUBLE);
            frame->has_statistics = TRUE;
            frame->mean = stat->mean / norm; frame->median = stat->median / norm; frame->sigma = stat->sigma / norm;
        }
    }
free_seq:
    free_sequence(seq, TRUE);
done:
    g_mutex_unlock(&engine_mutex);
    return count;
}
SirilImage *siril_sequence_frame(const char *directory, const char *name, int index, char *error, size_t error_size) {
    g_mutex_lock(&engine_mutex);
    initialize();
    sequence *seq = embedded_sequence(directory, name, error, error_size);
    SirilImage *image = NULL;
    if (!seq) goto done;
    if (index >= 0 && index < seq->number) {
        image = g_try_new0(SirilImage, 1);
        if (image && seq_read_frame(seq, index, &image->fit, TRUE, -1)) {
            clearfits(&image->fit); g_free(image); image = NULL;
        }
    }
    if (!image && error && error_size) snprintf(error, error_size, "Cannot read sequence frame %d", index + 1);
    free_sequence(seq, TRUE);
done:
    g_mutex_unlock(&engine_mutex);
    return image;
}
int siril_sequence_select(const char *directory, const char *name, const uint8_t *included,
    size_t count, int reference, char *error, size_t error_size) {
    g_mutex_lock(&engine_mutex);
    initialize();
    sequence *seq = embedded_sequence(directory, name, error, error_size);
    int ok = 0;
    if (!seq) goto done;
    if (!included || count != (size_t)seq->number || reference < -1 || reference >= seq->number ||
        (reference >= 0 && !included[reference])) {
        if (error && error_size) snprintf(error, error_size, "Invalid frame selection or excluded reference");
        goto free_seq;
    }
    for (int i = 0; i < seq->number; i++) seq->imgparam[i].incl = included[i] != 0;
    seq->reference_image = reference;
    fix_selnum(seq, FALSE);
    ok = writeseqfile(seq) == 0;
    if (!ok && error && error_size) snprintf(error, error_size, "Cannot save sequence selection");
free_seq:
    free_sequence(seq, TRUE);
done:
    g_mutex_unlock(&engine_mutex);
    return ok;
}

struct SirilBackground {
    SirilImage *original;
    fits corrected;
    GSList *samples;
    int computed, correction;
};
static void background_invalidate(SirilBackground *session) {
    clearfits(&session->corrected);
    session->computed = 0;
}
SirilBackground *siril_background_open(const char *path, char *error, size_t capacity) {
    SirilImage *image = siril_image_read(path, error, capacity);
    if (!image) return NULL;
    SirilBackground *session = g_try_new0(SirilBackground, 1);
    if (!session) {
        siril_image_free(image);
        if (error && capacity) snprintf(error, capacity, "Not enough memory for background session");
        return NULL;
    }
    session->original = image;
    return session;
}
void siril_background_free(SirilBackground *session) {
    if (!session) return;
    g_mutex_lock(&engine_mutex);
    free_background_sample_list(session->samples);
    clearfits(&session->corrected);
    g_mutex_unlock(&engine_mutex);
    siril_image_free(session->original);
    g_free(session);
}
int siril_background_generate(SirilBackground *session, int count, double tolerance,
        int randomize, int descent, double border, int percent, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!session || count < 2 || count > 100 || !isfinite(tolerance) || !isfinite(border) || border < 0) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &session->original->fit;
    int bx = percent ? (int)(fit->rx * border / 100.0) : (int)border;
    int by = percent ? (int)(fit->ry * border / 100.0) : (int)border;
    rectangle bounds = { .x = bx, .y = by, .w = fit->rx - 2 * bx, .h = fit->ry - 2 * by };
    int ok = 0;
    if (bounds.w < SAMPLE_SIZE + 2 || bounds.h < SAMPLE_SIZE + 2) {
        if (error && capacity) snprintf(error, capacity, "Border leaves too little area for 25-pixel samples");
        goto end;
    }
    fits *saved_fit = gfit;
    GSList *saved_samples = com.grad_samples;
    gfit = fit; com.grad_samples = NULL;
    ok = generate_background_samples(count, tolerance, randomize, descent, &bounds) == 0;
    free_background_sample_list(session->samples);
    session->samples = com.grad_samples;
    com.grad_samples = saved_samples; gfit = saved_fit;
    background_invalidate(session);
    if (!ok && error && capacity) snprintf(error, capacity, "Siril could not place samples: check image brightness, tolerance and sample density");
end:
    g_mutex_unlock(&engine_mutex);
    return ok;
}
size_t siril_background_samples(SirilBackground *session, SirilBackgroundSample *out, size_t capacity) {
    if (!session) return 0;
    g_mutex_lock(&engine_mutex);
    size_t count = 0;
    fits *fit = &session->original->fit;
    for (GSList *node = session->samples; node; node = node->next) {
        background_sample *sample = node->data;
        if (out && count < capacity) {
            out[count].x = sample->position.x;
            out[count].y = fit->top_down ? fit->ry - 1 - sample->position.y : sample->position.y;
            out[count].size = sample->size;
            memset(out[count].median, 0, sizeof out[count].median);
            for (int c = 0; c < fit->naxes[2]; c++) out[count].median[c] = sample->median[c];
        }
        count++;
    }
    g_mutex_unlock(&engine_mutex);
    return count;
}
int siril_background_add(SirilBackground *session, double x, double y, int descent) {
    if (!session || !isfinite(x) || !isfinite(y)) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &session->original->fit;
    int radius = get_background_sample_radius();
    int ok = x >= radius && y >= radius && x < fit->rx - radius && y < fit->ry - radius;
    double upstream_y = fit->top_down ? fit->ry - 1 - y : y;
    for (GSList *node = session->samples; ok && node; node = node->next) {
        background_sample *sample = node->data;
        if (hypot(sample->position.x - round(x), sample->position.y - round(upstream_y)) < 1) ok = 0;
    }
    if (ok) {
        point pt = { .x = round(x), .y = round(fit->top_down ? fit->ry - 1 - y : y) };
        session->samples = add_background_sample(session->samples, fit, pt, descent);
        /* Upstream returns a null sample on allocation failure / border rejection. */
        GSList *last = g_slist_last(session->samples);
        if (last && !last->data) { session->samples = g_slist_delete_link(session->samples, last); ok = 0; }
        background_invalidate(session);
    }
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_background_remove(SirilBackground *session, size_t index) {
    if (!session || index > G_MAXUINT) return 0;
    g_mutex_lock(&engine_mutex);
    GSList *node = g_slist_nth(session->samples, (guint)index);
    int ok = node != NULL;
    if (node) { g_free(node->data); session->samples = g_slist_delete_link(session->samples, node); background_invalidate(session); }
    g_mutex_unlock(&engine_mutex);
    return ok;
}
void siril_background_clear(SirilBackground *session) {
    if (!session) return;
    g_mutex_lock(&engine_mutex);
    free_background_sample_list(session->samples); session->samples = NULL;
    background_invalidate(session);
    g_mutex_unlock(&engine_mutex);
}
int siril_background_compute(SirilBackground *session, const SirilBackgroundOptions *o, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!session || !o || o->method < 0 || o->method > 1 || o->interpolation < 0 || o->interpolation > 1 ||
        o->degree < 1 || o->degree > 4 || o->correction < 0 || o->correction > 1 || !isfinite(o->smoothing) ||
        o->smoothing < 0 || o->smoothing > 1 || o->auto_degree < 1 || o->auto_degree > 6 ||
        (o->downsample != 1 && o->downsample != 2 && o->downsample != 4 && o->downsample != 8) ||
        !isfinite(o->scale) || o->scale < 1 || o->scale > 10 || !isfinite(o->smoothness) || o->smoothness < 0 ||
        !isfinite(o->protect_threshold) || o->protect_threshold < 0 || !isfinite(o->protect_amount) || o->protect_amount < 0) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = 0;
    fits *fit = &session->original->fit;
    guint count = g_slist_length(session->samples);
    unsigned terms = (o->degree + 1) * (o->degree + 2) / 2;
    if (o->method == 0 && count < (o->interpolation == 1 ? terms : 3)) {
        if (error && capacity) snprintf(error, capacity, "Not enough samples for this interpolation / polynomial degree");
        goto end;
    }
    /* The original GUI reserves 2x / 6x image memory for sample / auto methods.
     * Also account for our retained original and RBF's dense sample matrix. */
    double needed = (double)fit->rx * fit->ry * fit->naxes[2] * sizeof(float) * (o->method ? 8 : 5) +
        (o->method == 0 && o->interpolation == 0 ? (double)(count + 1) * (count + 1) * sizeof(double) : 0);
    if (needed > (double)get_available_memory() * 0.8) {
        if (error && capacity) snprintf(error, capacity, "Not enough remaining iPad memory for this model; close other Apps or use fewer samples");
        goto end;
    }
    background_invalidate(session);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    if (copyfits(fit, &session->corrected, CP_ALLOC | CP_DEEPCOPY, 0) != 0) goto end;
    sensor_pattern pattern = get_cfa_pattern_index_from_string(fit->keywords.bayer_pattern);
    struct background_data data = {
        .method = o->method, .correction = o->correction, .interpolation_method = o->interpolation,
        .degree = o->degree - 1, .smoothing = o->smoothing, .threads = 1, .dither = o->dither,
        .fit = &session->corrected, .from_ui = TRUE,
        .is_cfa = fit->naxes[2] == 1 && pattern >= BAYER_FILTER_MIN && pattern <= BAYER_FILTER_MAX,
        .autograd = { .scale = o->scale, .smoothness = o->smoothness, .protect = o->protect,
            .protect_threshold = o->protect_threshold, .protect_amount = o->protect_amount,
            .simplified = o->simplified, .degree = o->auto_degree, .downsample = o->downsample }
    };
    struct generic_img_args args = { .user = &data };
    GSList *saved = com.grad_samples; com.grad_samples = session->samples;
    ok = remove_gradient_image_hook(&args, &session->corrected, 1) == 0;
    com.grad_samples = saved;
    if (ok) { session->computed = 1; session->correction = o->correction; }
    else {
        background_invalidate(session);
        if (error && capacity) snprintf(error, capacity, "Siril could not fit the background model; check sample placement and image values");
    }
end:
    g_mutex_unlock(&engine_mutex);
    return ok;
}

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
static int displayed_region(fits *fit, const SirilRegion *input, rectangle *area) {
    memset(area, 0, sizeof *area);
    if (!input) return 1;
    if (input->x < 0 || input->y < 0 || input->width <= 0 || input->height <= 0 ||
        input->x >= fit->rx || input->y >= fit->ry ||
        input->width > fit->rx - input->x || input->height > fit->ry - input->y) return 0;
    area->x = input->x; area->w = input->width; area->h = input->height;
    /* Upstream stats/histogram selection extraction always uses ry-y-h,
     * while our display respects ROWORDER. Map exactly once at this boundary. */
    area->y = fit->top_down ? fit->ry - input->y - input->height : input->y;
    return 1;
}
int siril_image_statistics(SirilImage *image, const SirilRegion *region, int per_cfa,
        SirilChannelStatistics results[3]) {
    if (!image || !results) return 0;
    memset(results, 0, 3 * sizeof *results);
    g_mutex_lock(&engine_mutex);
    fits *fit = &image->fit;
    rectangle area;
    int channels = 0;
    if (!displayed_region(fit, region, &area)) goto end;
    gboolean cfa = per_cfa && fit->naxes[2] == 1 && fit->keywords.bayer_pattern[0] &&
        (!region || (region->width >= 2 && region->height >= 2));
    channels = cfa ? 3 : fit->naxes[2];
    for (int c = 0; c < channels; c++) {
        imstats *stat = statistics(NULL, -1, fit, cfa ? -c - 1 : c, &area, STATS_MAIN, MULTI_THREADED);
        if (!stat) { channels = 0; break; }
        results[c] = (SirilChannelStatistics){
            .total = stat->total, .good = stat->ngoodpix, .mean = stat->mean, .median = stat->median,
            .sigma = stat->sigma, .average_deviation = stat->avgDev, .mad = stat->mad,
            .sqrt_bwmv = stat->sqrtbwmv, .minimum = stat->min, .maximum = stat->max, .norm = stat->normValue
        };
        free_stats(stat);
    }
end:
    g_mutex_unlock(&engine_mutex);
    return channels;
}
int siril_image_histogram(SirilImage *image, const SirilRegion *region, int channel,
        double *counts, size_t buckets) {
    if (!image || !counts || !buckets || buckets > 65536 || 65536 % buckets) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &image->fit;
    rectangle area;
    int ok = 0;
    if (channel < 0 || channel >= fit->naxes[2] || !displayed_region(fit, region, &area)) goto end;
    gsl_histogram *histogram = region ? computeHisto_Selection(fit, channel, &area) : computeHisto(fit, channel);
    if (!histogram) goto end;
    memset(counts, 0, buckets * sizeof *counts);
    for (size_t i = 0; i < histogram->n; i++) {
        size_t target = i * buckets / histogram->n;
        counts[target] += gsl_histogram_get(histogram, i);
    }
    gsl_histogram_free(histogram);
    ok = 1;
end:
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_image_pixel(SirilImage *image, int32_t x, int32_t y, float values[3]) {
    if (!image || !values) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &image->fit;
    int channels = 0;
    if (x >= 0 && y >= 0 && x < fit->rx && y < fit->ry && fit->type == DATA_FLOAT) {
        int row = fit->top_down ? y : fit->ry - 1 - y;
        size_t offset = (size_t)row * fit->rx + x;
        channels = fit->naxes[2];
        memset(values, 0, 3 * sizeof *values);
        for (int c = 0; c < channels; c++) values[c] = fit->fpdata[c][offset];
    }
    g_mutex_unlock(&engine_mutex);
    return channels;
}
size_t siril_image_copy_header(SirilImage *image, char *buffer, size_t capacity) {
    if (!image) return 0;
    g_mutex_lock(&engine_mutex);
    const char *header = image->fit.header ? image->fit.header : "";
    size_t required = strlen(header) + 1;
    if (buffer && capacity >= required) memcpy(buffer, header, required);
    g_mutex_unlock(&engine_mutex);
    return required;
}
static int preview_locked(fits *fit, uint32_t max_dimension, int selected_channel, int automatic, SirilPreview *preview) {
    if (!fit || !preview || !max_dimension || max_dimension > 2048 || selected_channel < -1 || selected_channel >= fit->naxes[2]) return 0;
    memset(preview, 0, sizeof *preview);
    int ok = 0;
    struct mtf_params params;
    if (fit->type != DATA_FLOAT || !fit->rx || !fit->ry ||
        (automatic && find_linked_midtones_balance_default(fit, &params) != 0)) goto done;
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
                unsigned channel = selected_channel >= 0 ? selected_channel : fit->naxes[2] == 3 ? c : 0;
                float value = fit->fpdata[channel][source];
                if (automatic) value = MTFp(value, params);
                pixels[target + c] = isfinite(value) ? (uint8_t)lroundf(fminf(1, fmaxf(0, value)) * 255) : 0;
            }
            pixels[target + 3] = 255;
        }
    }
    preview->width = w; preview->height = h; preview->rgba = pixels;
    ok = 1;
done:
    return ok;
}
int siril_image_preview_display(SirilImage *image, uint32_t maximum, int channel, int automatic, SirilPreview *preview) {
    if (!image) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = preview_locked(&image->fit, maximum, channel, automatic, preview);
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_image_preview(SirilImage *image, uint32_t maximum, SirilPreview *preview) {
    return siril_image_preview_display(image, maximum, -1, 1, preview);
}
int siril_background_preview(SirilBackground *session, int view, int channel, int automatic, SirilPreview *preview) {
    if (!session || view < 0 || view > 2) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = 0;
    fits model = {0};
    fits *original = &session->original->fit;
    if (view == 0) ok = preview_locked(original, 2048, channel, automatic, preview);
    else if (session->computed) {
        if (view == 1) ok = preview_locked(&session->corrected, 2048, channel, automatic, preview);
        else if (copyfits(original, &model, CP_ALLOC | CP_DEEPCOPY, 0) == 0) {
            /* Same model-view reconstruction as the original GTK dialog. */
            size_t count = (size_t)original->rx * original->ry;
            for (int c = 0; c < original->naxes[2]; c++) {
                double sum = 0;
                for (size_t i = 0; i < count; i++) sum += original->fpdata[c][i];
                float level = sum / count;
                for (size_t i = 0; i < count; i++) {
                    float a = original->fpdata[c][i], b = session->corrected.fpdata[c][i];
                    float value = session->correction ? a / fmaxf(b, 1e-6f) * level : a - b + level;
                    model.fpdata[c][i] = fminf(1, fmaxf(0, value));
                }
            }
            invalidate_stats_from_fit(&model);
            ok = preview_locked(&model, 2048, channel, automatic, preview);
        }
    }
    clearfits(&model);
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_background_write(SirilBackground *session, const char *path) {
    if (!session || !path) return 0;
    if (!g_str_has_suffix(path, ".fit") && !g_str_has_suffix(path, ".fits") && !g_str_has_suffix(path, ".fts")) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = session->computed && !g_file_test(path, G_FILE_TEST_EXISTS) && savefits(path, &session->corrected) == 0;
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

void siril_release_workspace(void) {
    g_mutex_lock(&engine_mutex);
    if (initialized) {
        close_sequence(FALSE);
        close_single_image();
    }
    g_mutex_unlock(&engine_mutex);
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
    if (get_max_memory_in_MB() < 1) {
        if (error && capacity) snprintf(error, capacity, "No processing memory budget is available; close other Apps and retry");
        goto done;
    }
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
        gboolean valid_name = count && word[0] && *word[0];
        gboolean unsupported = line[0] == '@' || (count &&
            (!g_ascii_strcasecmp(word[0], "exit") || !g_ascii_strcasecmp(word[0], "livestack") ||
             !g_ascii_strcasecmp(word[0], "stop_ls")));
        g_free(parsed);
        int result = !valid_name ? CMD_NOT_FOUND : unsupported ? CMD_NOT_SCRIPTABLE : processcommand(line, TRUE);
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
