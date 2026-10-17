// SPDX-License-Identifier: GPL-3.0-or-later
/* C ABI for the actual upstream Siril core. No desktop entry point is invoked. */
#include "SirilCore.h"
#include "core/siril.h"
#include "core/settings.h"
#include "core/arithm.h"
#include "core/masks.h"
#include "io/image_format_fits.h"
#include "io/ser.h"
#include "filters/mtf.h"
#include "filters/deconvolution/deconvolution.h"
#include "algos/siril_random.h"
#include "algos/background_extraction.h"
#include "algos/demosaicing.h"
#include "algos/colors.h"
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
#include "core/siril_app_dirs.h"
#include "algos/photometric_cc.h"
#include "algos/spcc.h"
#include "io/sequence.h"
#include "io/fits_sequence.h"
#include "io/single_image.h"
#include "io/conversion.h"
#include "io/fits_keywords.h"
#include <gsl/gsl_errno.h>
#include <fftw3.h>
#ifdef HAVE_LIBCURL
#include <curl/curl.h>
#endif
#include <stdio.h>
#include <limits.h>
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
static void embedded_delete_selection(void) {
    /* Worker callbacks run inside the embedding's serialized processing.
     * The headless GUI stub otherwise leaves boxselect -clear ineffective. */
    memset(&com.selection, 0, sizeof com.selection);
}

static void initialize(void) {
    if (g_once_init_enter(&initialized)) {
        com.headless = TRUE;
        com.script = TRUE;
        com.max_thread = 1;
        gsl_set_error_handler_off();
        siril_initialize_rng();
        initialize_siril_directories();
        initialize_default_settings();
        initialize_spcc_mirrors();
#ifdef HAVE_LIBCURL
        curl_global_init(CURL_GLOBAL_ALL);
#endif
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
        gui_iface.delete_selection = embedded_delete_selection;
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
    gboolean previous_debayer = com.pref.debayer.open_debayer;
    com.pref.debayer.open_debayer = FALSE;
    sequence *seq = readseqfile(name);
    if (!seq) {
        com.pref.debayer.open_debayer = previous_debayer;
        if (error && capacity) snprintf(error, capacity, "Cannot read sequence %s", name);
        return NULL;
    }
    gchar *base = g_strndup(name, strlen(name) - 4);
    gboolean matching = seq->seqname && !strcmp(seq->seqname, base);
    g_free(base);
    int invalid = !matching || seq->number < 1 || seq_check_basic_data(seq, FALSE) < 0 || seq->nb_layers < 1 || seq->nb_layers > 3;
    com.pref.debayer.open_debayer = previous_debayer;
    if (invalid) {
        if (error && capacity) snprintf(error, capacity, "Invalid or unavailable sequence data");
        free_sequence(seq, TRUE);
        return NULL;
    }
    return seq;
}
int siril_sequence_discover(const char *directory, char *error, size_t error_size) {
    g_mutex_lock(&engine_mutex);
    initialize();
    if (error && error_size) error[0] = 0;
    gchar *message = NULL;
    gboolean previous_debayer = com.pref.debayer.open_debayer;
    com.pref.debayer.open_debayer = FALSE;
    int ok = directory && !siril_change_dir(directory, &message) && !check_seq();
    com.pref.debayer.open_debayer = previous_debayer;
    if (!ok && error && error_size) snprintf(error, error_size, "Cannot index converted sequence frames");
    g_mutex_unlock(&engine_mutex);
    return ok;
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
            double norm = stat->normValue > 0 ? stat->normValue : (seq->bitpix == FLOAT_IMG ? 1 : seq->bitpix == BYTE_IMG ? UCHAR_MAX_DOUBLE : USHRT_MAX_DOUBLE);
            frame->has_statistics = TRUE;
            /* Original caches may contain only median/normalization fields.
             * Preserve missing values as NaN, never as measured graph points. */
            frame->mean = stat->mean == NULL_STATS ? NAN : stat->mean / norm;
            frame->median = stat->median == NULL_STATS ? NAN : stat->median / norm;
            frame->sigma = stat->sigma == NULL_STATS ? NAN : stat->sigma / norm;
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
        gboolean previous_debayer = com.pref.debayer.open_debayer;
        if (seq->type == SEQ_SER) com.pref.debayer.open_debayer = FALSE;
        int failed = image && seq_read_frame(seq, index, &image->fit, TRUE, -1);
        com.pref.debayer.open_debayer = previous_debayer;
        if (failed) {
            clearfits(&image->fit); g_free(image); image = NULL;
        }
    }
    if (!image && error && error_size) snprintf(error, error_size, "Cannot read sequence frame %d", index + 1);
    /* FITSEQ attaches a borrowed HDU handle; the returned image owns pixels
     * and metadata, while the sequence reader is closed below. */
    if (image) image->fit.fptr = NULL;
    if (image && seq->type == SEQ_SER) {
        import_metadata_from_serfile(seq->ser_file, &image->fit);
        // Keep the same displayed-pixel and saved sensor-pattern boundary
        // as standalone SER import; the embedded reader corrects row order.
        image->fit.top_down = FALSE;
        if (image->fit.keywords.bayer_pattern[0]) {
            sensor_pattern pattern = get_cfa_pattern_index_from_string(image->fit.keywords.bayer_pattern);
            adjust_Bayer_pattern_orientation(&pattern, image->fit.ry, TRUE);
            g_strlcpy(image->fit.keywords.bayer_pattern, filter_pattern[pattern], FLEN_VALUE);
        }
        g_strlcpy(image->fit.keywords.row_order, "BOTTOM-UP", FLEN_VALUE);
    }
    free_sequence(seq, TRUE);
done:
    g_mutex_unlock(&engine_mutex);
    return image;
}
int siril_sequence_files(const char *directory, const char *name, char *output,
    size_t capacity, char *error, size_t error_size) {
    g_mutex_lock(&engine_mutex);
    initialize();
    sequence *seq = embedded_sequence(directory, name, error, error_size);
    int result = -1;
    if (!seq) goto done;
    if (seq->type != SEQ_REGULAR && seq->type != SEQ_FITSEQ && seq->type != SEQ_SER) {
        if (error && error_size) snprintf(error, error_size, "Independent file ownership requires a FITS/FITSEQ/SER sequence");
        goto free_seq;
    }
    GString *paths = g_string_new(name);
    if (seq->type == SEQ_FITSEQ || seq->type == SEQ_SER) {
        gchar *filename = g_path_get_basename(seq->type == SEQ_SER ? seq->ser_file->filename : seq->fitseq_file->filename);
        if (strchr(filename, '\n') || strchr(filename, '\r')) {
            g_free(filename); g_string_free(paths, TRUE); goto free_seq;
        }
        g_string_append_printf(paths, "\n%s", filename);
        g_free(filename);
    }
    const char *folders[] = {"cache", "cache", "drizztmp"};
    const char *extensions[] = {"lst", "msk", "fit"};
    for (int i = 0; i < seq->number; i++) {
        char filename[256];
        if (seq->type == SEQ_REGULAR && (!fit_sequence_get_image_filename_checkext(seq, i, filename) ||
            strchr(filename, '/') || strchr(filename, '\\') || strchr(filename, '\n') || strchr(filename, '\r'))) {
            if (error && error_size) snprintf(error, error_size, "Invalid or missing sequence frame filename");
            g_string_free(paths, TRUE);
            goto free_seq;
        }
        if (seq->type == SEQ_REGULAR) g_string_append_printf(paths, "\n%s", filename);
        for (int k = 0; k < 3; k++) {
            gchar *cache = get_sequence_cache_filename(seq, i, folders[k], extensions[k], NULL);
            if (cache && g_file_test(cache, G_FILE_TEST_EXISTS)) {
                gchar *base = g_path_get_basename(cache);
                g_string_append_printf(paths, "\n%s/%s", folders[k], base);
                g_free(base);
            }
            g_free(cache);
        }
    }
    if (paths->len < INT_MAX && (!output || capacity > paths->len)) {
        result = (int)paths->len + 1;
        if (output) memcpy(output, paths->str, result);
    } else if (error && error_size) snprintf(error, error_size, "Sequence file-list capacity too small");
    g_string_free(paths, TRUE);
free_seq:
    free_sequence(seq, TRUE);
done:
    g_mutex_unlock(&engine_mutex);
    return result;
}
int siril_sequence_enable_drizzle(const char *directory, const char *name,
    char *error, size_t error_size) {
    g_mutex_lock(&engine_mutex);
    initialize();
    sequence *seq = embedded_sequence(directory, name, error, error_size);
    int ok = 0;
    if (!seq) goto done;
    if (seq->type != SEQ_REGULAR) goto free_seq;
    for (int i = 0; i < seq->number; i++) {
        fits weights = {0};
        gchar *path = get_sequence_cache_filename(seq, i, "drizztmp", "fit", NULL);
        int invalid = !path || readfits(path, &weights, NULL, FALSE);
        if (!invalid) invalid = weights.rx != seq->rx || weights.ry != seq->ry || weights.naxes[2] != seq->nb_layers;
        clearfits(&weights); g_free(path);
        if (invalid) goto free_seq;
    }
    seq->is_drizzle = TRUE;
    ok = writeseqfile(seq) == 0;
free_seq:
    if (!ok && error && error_size) snprintf(error, error_size, "Cannot validate or save cropped Drizzle weights");
    free_sequence(seq, TRUE);
done:
    g_mutex_unlock(&engine_mutex);
    return ok;
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

#include "SirilPatternRegistration.inc"
#include "SirilMultipoint.inc"
#include "SirilCometRegistration.inc"
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
SirilBackground *siril_background_open_sequence(const char *directory, const char *name,
        int index, char *error, size_t capacity) {
    SirilImage *image = siril_sequence_frame(directory, name, index, error, capacity);
    if (!image) return NULL;
    SirilBackground *session = g_try_new0(SirilBackground, 1);
    if (!session) { siril_image_free(image); return NULL; }
    session->original = image;
    return session;
}
static int sequence_background_options(const SirilBackgroundOptions *o, const SirilBackgroundSampling *s,
        struct background_data *data, char *error, size_t capacity) {
    if (!o || !s || o->method < 0 || o->method > 1 || o->interpolation < 0 || o->interpolation > 1 ||
        o->degree < 1 || o->degree > 4 || o->correction < 0 || o->correction > 1 ||
        !isfinite(o->smoothing) || o->smoothing < 0 || o->smoothing > 1 ||
        !isfinite(o->scale) || o->scale < 1 || o->scale > 10 ||
        !isfinite(o->smoothness) || o->smoothness < 0 ||
        !isfinite(o->protect_threshold) || o->protect_threshold < 0 || o->protect_threshold > 1 ||
        !isfinite(o->protect_amount) || o->protect_amount < 0 || o->protect_amount > 1 ||
        o->auto_degree < 1 || o->auto_degree > 6 ||
        (o->downsample != 1 && o->downsample != 2 && o->downsample != 4 && o->downsample != 8) ||
        s->per_line < 2 || s->per_line > 100 || !isfinite(s->tolerance) || s->tolerance < 0 ||
        !isfinite(s->border) || s->border < 0 || s->border > G_MAXINT / 2 || (s->border_percent && s->border >= 50)) {
        if (error && capacity) snprintf(error, capacity, "Invalid background model or sampling parameters");
        return 0;
    }
    *data = (struct background_data) {
        .destroy_fn = free_background_data, .method = o->method,
        .nb_of_samples = s->per_line, .tolerance = s->tolerance,
        .correction = o->correction, .interpolation_method = o->interpolation,
        .degree = o->degree - 1, .smoothing = o->smoothing, .threads = 1, .dither = o->dither,
        .randomize = s->randomize, .grad_descent = s->gradient_descent,
        .border_value = s->border, .border_is_percent = s->border_percent,
        .autograd = { .scale = o->scale, .smoothness = o->smoothness, .protect = o->protect,
            .protect_threshold = o->protect_threshold, .protect_amount = o->protect_amount,
            .simplified = o->simplified, .degree = o->auto_degree, .downsample = o->downsample }
    };
    return 1;
}
extern int siril_ipados_background_sequence_preview(fits *, struct background_data *);
int siril_background_compute_sequence(SirilBackground *session, const SirilBackgroundOptions *o,
        const SirilBackgroundSampling *sampling, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    struct background_data data;
    if (!session || !sequence_background_options(o, sampling, &data, error, capacity)) return 0;
    g_mutex_lock(&engine_mutex);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    fits *fit = &session->original->fit;
    double needed = (double)fit->rx * fit->ry * fit->naxes[2] * sizeof(float) * (o->method ? 8 : 5);
    if (!o->method && !o->interpolation) {
        double n = sampling->randomize ? sampling->per_line + 400 : sampling->per_line * sampling->per_line;
        needed += (n + 1) * (n + 1) * sizeof(double);
    }
    int ok = 0;
    if (needed > (double)get_available_memory() * 0.8) {
        if (error && capacity) snprintf(error, capacity, "Not enough iPad memory for sequence preview");
        goto done;
    }
    background_invalidate(session);
    if (copyfits(fit, &session->corrected, CP_ALLOC | CP_DEEPCOPY, 0)) goto done;
    ok = siril_ipados_background_sequence_preview(&session->corrected, &data) == 0;
    if (ok) { session->computed = 1; session->correction = o->correction; }
    else {
        background_invalidate(session);
        if (error && capacity) snprintf(error, capacity, "Original per-frame background extraction failed; check samples and image values");
    }
done:
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_sequence_background(const char *directory, const char *name, const char *prefix,
        const SirilBackgroundOptions *o, const SirilBackgroundSampling *sampling, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    struct background_data data;
    if (!prefix || !*prefix || strlen(prefix) > 64 ||
        !sequence_background_options(o, sampling, &data, error, capacity)) return 0;
    for (const char *p = prefix; *p; p++) if (!g_ascii_isalnum(*p) && *p != '_') {
        if (error && capacity) snprintf(error, capacity, "Invalid output prefix");
        return 0;
    }
    g_mutex_lock(&engine_mutex);
    initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    int ok = 0;
    sequence *seq = embedded_sequence(directory, name, error, capacity);
    if (!seq) goto done;
    /* seq_prepare_hook removes old prefixed files. Never let an embedding
     * caller accidentally overwrite a prior run, including orphan outputs. */
    GDir *dir = g_dir_open(directory, 0, NULL);
    if (!dir) { free_sequence(seq, TRUE); goto done; }
    const gchar *entry;
    gboolean collision = FALSE;
    while ((entry = g_dir_read_name(dir))) if (g_str_has_prefix(entry, prefix)) { collision = TRUE; break; }
    g_dir_close(dir);
    if (seq->selnum < 1 || collision || strlen(prefix) + strlen(seq->seqname) > 230) {
        if (error && capacity) snprintf(error, capacity, "Empty selection, reused output prefix or overlong sequence name");
        free_sequence(seq, TRUE); goto done;
    }
    /* Upstream sequence memory hook budgets sample models, even for auto.
     * Budget the auto allocations and dense RBF matrix before submitting a
     * worker; available memory already excludes any retained preview. */
    double pixel_count = (double)seq->rx * seq->ry;
    if (seq->is_variable) for (int i = 0; i < seq->number; i++) if (seq->imgparam[i].incl) {
        double frame_pixels = (double)seq->imgparam[i].rx * seq->imgparam[i].ry;
        if (frame_pixels > pixel_count) pixel_count = frame_pixels;
    }
    double needed = pixel_count * seq->nb_layers * sizeof(float) * (o->method ? 8 : 5);
    if (!o->method && !o->interpolation) {
        double n = sampling->randomize ? sampling->per_line + 400 : sampling->per_line * sampling->per_line;
        needed += (n + 1) * (n + 1) * sizeof(double);
    }
    if (needed > (double)get_available_memory() * 0.8) {
        if (error && capacity) snprintf(error, capacity, "Not enough remaining iPad memory for this background model; use fewer samples or close other Apps");
        free_sequence(seq, TRUE); goto done;
    }
    struct background_data *args = g_try_new(struct background_data, 1);
    if (!args) { free_sequence(seq, TRUE); goto done; }
    *args = data; args->seq = seq; args->seqEntry = strdup(prefix);
    /* com.script makes the original persistent worker synchronous. It owns
     * args and seq, including on startup failure; consume its cached result. */
    waiting_for_thread();
    apply_background_extraction_to_sequence(args);
    ok = GPOINTER_TO_INT(waiting_for_thread()) == 0 && !g_atomic_int_get(&cancel_requested);
    if (!ok && error && capacity) snprintf(error, capacity, "Original sequence background extraction failed or was cancelled");
done:
    g_mutex_unlock(&engine_mutex);
    return ok;
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
    GSList *generated = com.grad_samples;
    com.grad_samples = saved_samples; gfit = saved_fit;
    if (ok) {
        free_background_sample_list(session->samples);
        session->samples = generated;
        background_invalidate(session);
    } else free_background_sample_list(generated);
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
static int background_position(fits *fit, double x, double y, point *pt) {
    if (!isfinite(x) || !isfinite(y)) return 0;
    x = round(x); y = round(y);
    int radius = get_background_sample_radius();
    if (x < radius || y < radius || x >= fit->rx - radius || y >= fit->ry - radius) return 0;
    pt->x = x;
    pt->y = fit->top_down ? fit->ry - 1 - y : y;
    return 1;
}
int siril_background_add(SirilBackground *session, double x, double y, int descent) {
    if (!session) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &session->original->fit;
    point pt;
    int ok = background_position(fit, x, y, &pt);
    GSList *replacement = ok ? add_background_sample(NULL, fit, pt, descent) : NULL;
    ok = replacement && replacement->data;
    background_sample *added = ok ? replacement->data : NULL;
    for (GSList *node = session->samples; ok && node; node = node->next) {
        background_sample *s = node->data;
        if (s->position.x == added->position.x && s->position.y == added->position.y) ok = 0;
    }
    if (ok) {
        session->samples = g_slist_concat(session->samples, replacement); replacement = NULL;
        background_invalidate(session);
    }
    free_background_sample_list(replacement);
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_background_move(SirilBackground *session, size_t index, double x, double y) {
    if (!session || index > G_MAXUINT) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &session->original->fit;
    point pt;
    GSList *target = g_slist_nth(session->samples, (guint)index);
    int ok = target && background_position(fit, x, y, &pt);
    for (GSList *node = session->samples; ok && node; node = node->next) {
        background_sample *s = node->data;
        if (node != target && s->position.x == pt.x && s->position.y == pt.y) ok = 0;
    }
    if (ok) {
        GSList *replacement = add_background_sample(NULL, fit, pt, FALSE);
        ok = replacement && replacement->data;
        if (ok) {
            g_free(target->data);
            target->data = replacement->data;
            replacement->data = NULL;
            background_invalidate(session);
        }
        free_background_sample_list(replacement);
    }
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_background_restore(SirilBackground *session, const SirilBackgroundSample *samples, size_t count) {
    if (!session || (count && !samples) || count > G_MAXUINT) return 0;
    g_mutex_lock(&engine_mutex);
    fits *fit = &session->original->fit;
    point *coords = count ? g_try_new(point, count) : NULL;
    GSList *pts = NULL, *replacement = NULL;
    GHashTable *seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    int ok = !count || coords != NULL;
    for (size_t i = 0; ok && i < count; i++) {
        ok = background_position(fit, samples[i].x, samples[i].y, &coords[i]);
        if (!ok) break;
        char *key = g_strdup_printf("%.0f,%.0f", coords[i].x, coords[i].y);
        if (g_hash_table_contains(seen, key)) { g_free(key); ok = 0; break; }
        g_hash_table_add(seen, key);
        pts = g_slist_prepend(pts, &coords[i]);
    }
    if (ok && count) {
        pts = g_slist_reverse(pts);
        replacement = add_background_samples(NULL, fit, pts);
        ok = g_slist_length(replacement) == count;
    }
    if (ok) {
        free_background_sample_list(session->samples);
        session->samples = replacement; replacement = NULL;
        background_invalidate(session);
    }
    free_background_sample_list(replacement);
    g_slist_free(pts); g_free(coords); g_hash_table_destroy(seen);
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
SirilImage *siril_image_read_any(const char *path, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!path) return NULL;
    g_mutex_lock(&engine_mutex);
    initialize();
    SirilImage *image = g_try_new0(SirilImage, 1);
    int failed = !image || read_single_image(path, &image->fit, NULL, FALSE, NULL, FALSE, TRUE, TRUE);
    /* force_float is honored by FITS/TIFF readers; PNG/JPEG/BMP/PNM
     * readers keep integer samples. Use upstream's bit-depth-aware conversion
     * before exposing the normalized floating-point image through this ABI. */
    if (!failed && image->fit.type == DATA_USHORT)
        failed = soper(&image->fit, 1.0f, OPER_MUL, TRUE);
    if (failed || image->fit.type != DATA_FLOAT) {
        if (image) { clearfits(&image->fit); g_free(image); }
        image = NULL;
        if (error && capacity) snprintf(error, capacity, "Original Siril could not decode this image format");
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
    info->top_down = fit->top_down;
    info->gain = fit->keywords.key_gain; info->offset = fit->keywords.key_offset;
    info->exposure = fit->keywords.exposure; info->temperature = fit->keywords.ccd_temp;
    info->focal_length = fit->keywords.focal_length; info->aperture = fit->keywords.aperture;
    info->pixel_size_x = fit->keywords.pixel_size_x; info->pixel_size_y = fit->keywords.pixel_size_y;
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
#include "SirilAstrometry.inc"

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
            .sqrt_bwmv = stat->sqrtbwmv, .minimum = stat->min, .maximum = stat->max, .norm = stat->normValue,
            .background_noise = stat->bgnoise
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
static int embedded_keyword_valid(const char *key, fits *fit) {
    if (!key || !*key || strlen(key) > 8) return 0;
    for (const char *p = key; *p; p++)
        if (!g_ascii_isupper(*p) && !g_ascii_isdigit(*p) && *p != '-' && *p != '_') return 0;
    char card[FLEN_CARD]; snprintf(card, sizeof card, "%-8s= 0", key);
    return !keyword_is_protected(card, fit);
}
static int embedded_fits_text_valid(const char *value) {
    if (!value) return 1;
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) if (*p < 32 || *p > 126) return 0;
    return 1;
}
static int embedded_keyword_format(fits *fit, int action, const char *key,
    const char *value, const char *comment, int string_value, char formatted[FLEN_VALUE]) {
    if (action < 0 || action > 3 ||
        (action != 3 && !embedded_keyword_valid(key, fit)) ||
        (action == 2 && !embedded_keyword_valid(value, fit))) return 0;
    if (!embedded_fits_text_valid(value) || !embedded_fits_text_valid(comment) ||
        (value && strlen(value) > 68) || (comment && strlen(comment) > 70) ||
        (action == 0 && !value) || (action == 3 && (!comment || !*comment))) return 0;
    memset(formatted, 0, FLEN_VALUE);
    if (action == 0) {
        if (string_value) {
            size_t escaped = strlen(value);
            for (const char *p = value; *p; p++) if (*p == '\'') escaped++;
            if (escaped > 68) return 0;
        }
        process_keyword_string_value(value, formatted, string_value != 0);
        if (strlen(formatted) + (comment ? strlen(comment) + 3 : 0) + 11 > 80) return 0;
        char template[FLEN_CARD], card[FLEN_CARD]; int kind = 0, status = 0;
        snprintf(template, sizeof template, "%s = %s%s%s", key, formatted, comment ? " / " : "", comment ? comment : "");
        fits_parse_template(template, card, &kind, &status);
        if (status || kind != 0) return 0;
    }
    return 1;
}
SirilImage *siril_image_edit_keyword(SirilImage *image, int action, const char *key,
    const char *value, const char *comment, int string_value, char *error, size_t error_size) {
    if (error && error_size) *error = 0;
    if (!image) return NULL;
    g_mutex_lock(&engine_mutex);
    SirilImage *result = NULL;
    char formatted[FLEN_VALUE];
    if (!embedded_keyword_format(&image->fit, action, key, value, comment, string_value, formatted)) goto done;
    result = g_try_new0(SirilImage, 1);
    if (!result) goto done;
    if (copyfits(&image->fit, &result->fit, CP_ALLOC | CP_DEEPCOPY | CP_COPYMASK, 0) ||
        updateFITSKeyword(&result->fit, action == 3 ? NULL : key, action == 2 ? value : NULL,
            action == 0 ? formatted : NULL, action == 0 || action == 3 ? comment : NULL, TRUE, FALSE)) {
        clearfits(&result->fit); g_free(result); result = NULL;
    }
done:
    if (!result && error && error_size) snprintf(error, error_size, "Keyword edit failed: invalid/protected key, invalid value or original FITS error");
    g_mutex_unlock(&engine_mutex); return result;
}
extern int siril_ipados_sequence_keywords(sequence *, struct keywords_data *);
int siril_sequence_edit_keyword(const char *directory, const char *name, int action,
    const char *key, const char *value, const char *comment, int string_value,
    char *error, size_t error_size) {
    g_mutex_lock(&engine_mutex);
    initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    int ok = 0;
    sequence *seq = embedded_sequence(directory, name, error, error_size);
    if (!seq) goto done;
    /* The original worker edits its inputs. The App supplies a private job
     * copy; regular workers retain selection and registration. */
    if ((seq->type != SEQ_REGULAR && seq->type != SEQ_FITSEQ) || seq->selnum < 1) goto free_seq;
    fits validation = {0};
    int first = 0;
    while (first < seq->number && !seq->imgparam[first].incl) first++;
    char formatted[FLEN_VALUE];
    int valid = first < seq->number && !seq_read_frame(seq, first, &validation, TRUE, -1) &&
        embedded_keyword_format(&validation, action, key, value, comment, string_value, formatted);
    clearfits(&validation);
    if (!valid) goto free_seq;
    struct keywords_data *args = g_try_new0(struct keywords_data, 1);
    if (!args) goto free_seq;
    args->FITS_key = action == 3 ? NULL : g_strdup(key);
    args->newkey = action == 2 ? g_strdup(value) : NULL;
    args->value = action == 0 ? g_strdup(formatted) : NULL;
    args->comment = action == 0 || action == 3 ? g_strdup(comment) : NULL;
    /* Original hooks own args and seq, even when a worker cannot start. */
    ok = siril_ipados_sequence_keywords(seq, args) && !g_atomic_int_get(&cancel_requested);
    goto done;
free_seq:
    free_sequence(seq, TRUE);
done:
    if (!ok && error && error_size && !error[0]) snprintf(error, error_size, "Original sequence keyword edit failed: invalid/protected key, write error or cancellation");
    g_mutex_unlock(&engine_mutex);
    return ok;
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
static int preview_mode_locked(fits *fit, uint32_t maximum, int selected, const SirilDisplayOptions *options, SirilPreview *preview);
static int background_preview_settings(SirilBackground *session, int view, int channel, int automatic, const SirilDisplayOptions *options, SirilPreview *preview) {
    if (!session || view < 0 || view > 2) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = 0;
    fits model = {0};
    fits *original = &session->original->fit;
    if (view == 0) ok = options ? preview_mode_locked(original, 2048, channel, options, preview) : preview_locked(original, 2048, channel, automatic, preview);
    else if (session->computed) {
        if (view == 1) ok = options ? preview_mode_locked(&session->corrected, 2048, channel, options, preview) : preview_locked(&session->corrected, 2048, channel, automatic, preview);
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
            ok = options ? preview_mode_locked(&model, 2048, channel, options, preview) : preview_locked(&model, 2048, channel, automatic, preview);
        }
    }
    clearfits(&model);
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_background_preview(SirilBackground *session, int view, int channel, int automatic, SirilPreview *preview) {
    return background_preview_settings(session, view, channel, automatic, NULL, preview);
}
int siril_background_preview_mode(SirilBackground *session, int view, int channel, const SirilDisplayOptions *options, SirilPreview *preview) {
    if (!options) return 0;
    return background_preview_settings(session, view, channel, 0, options, preview);
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
#include "SirilICCPrimaries.inc"
int siril_icc_chromaticity(const void *buffer, size_t size, double xy[8], char *description, size_t capacity) {
    if (!buffer || size < 128 || size > 16 * 1024 * 1024 || !xy || !description || !capacity) return 0;
    g_mutex_lock(&engine_mutex);
    cmsHPROFILE profile = cmsOpenProfileFromMem(buffer, (cmsUInt32Number)size);
    int channels = profile ? cmsGetColorSpace(profile) == cmsSigRgbData ? 3 : cmsGetColorSpace(profile) == cmsSigGrayData ? 1 : 0 : 0;
    for (int i = 0; i < 8; i++) xy[i] = NAN;
    description[0] = 0;
    if (channels) {
        char *name = siril_color_profile_get_description(profile);
        g_strlcpy(description, name ? name : "ICC profile", capacity); g_free(name);
    }
    if (channels == 3) {
        cmsCIEXYZTRIPLE primaries; cmsCIEXYZ white;
        if (!siril_color_profile_get_rgb_matrix_colorants_d50(profile, &primaries, &white)) channels = 0;
        else {
            cmsCIEXYZ values[4] = {primaries.Red, primaries.Green, primaries.Blue, white};
            for (int i = 0; i < 4; i++) { cmsCIExyY point; cmsXYZ2xyY(&point, &values[i]); xy[2 * i] = point.x; xy[2 * i + 1] = point.y; }
        }
    }
    if (profile) cmsCloseProfile(profile);
    g_mutex_unlock(&engine_mutex);
    return channels;
}
int siril_icc_spectral_locus(double *xy, size_t capacity) {
    if (!xy || capacity < 644) return 0;
    for (int i = 0; i < 321; i++) {
        cmsCIEXYZ xyz = {x1931(380 + i), y1931(380 + i), z1931(380 + i)};
        cmsCIExyY point; cmsXYZ2xyY(&point, &xyz); xy[2 * i] = point.x; xy[2 * i + 1] = point.y;
    }
    xy[642] = xy[0]; xy[643] = xy[1]; return 1;
}
size_t siril_image_copy_icc(const SirilImage *image, void *buffer, size_t capacity) {
    if (!image) return 0;
    g_mutex_lock(&engine_mutex);
    cmsUInt32Number size = 0;
    int ok = image->fit.icc_profile && cmsSaveProfileToMem(image->fit.icc_profile, NULL, &size);
    if (ok && buffer && capacity >= size) ok = cmsSaveProfileToMem(image->fit.icc_profile, buffer, &size);
    g_mutex_unlock(&engine_mutex);
    return ok ? size : 0;
}
int siril_icc_validate(const void *buffer, size_t size, int channels) {
    if (!buffer || size < 128 || size > 16 * 1024 * 1024 || (channels != 0 && channels != 1 && channels != 3)) return 0;
    g_mutex_lock(&engine_mutex);
    cmsHPROFILE profile = cmsOpenProfileFromMem(buffer, (cmsUInt32Number)size);
    cmsColorSpaceSignature color = profile ? cmsGetColorSpace(profile) : 0;
    int ok = profile && (channels ? color == (channels == 1 ? cmsSigGrayData : cmsSigRgbData) :
        (color == cmsSigGrayData || color == cmsSigRgbData || color == cmsSigCmykData));
    if (ok) {
        cmsUInt32Number kind = color == cmsSigGrayData ? TYPE_GRAY_FLT : color == cmsSigCmykData ? TYPE_CMYK_FLT : TYPE_RGB_FLT;
        cmsHTRANSFORM transform = cmsCreateTransform(profile, kind, profile, kind, INTENT_RELATIVE_COLORIMETRIC, 0);
        ok = transform != NULL;
        if (transform) cmsDeleteTransform(transform);
    }
    if (profile) cmsCloseProfile(profile);
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

int siril_image_export_jxl_profile(SirilImage *image, const char *path, int depth, int effort, double quality, int profile) {
    if (!image || !path || !g_str_has_suffix(path, ".jxl") || (depth != 8 && depth != 32) ||
        effort < 1 || effort > 9 || !isfinite(quality) || quality < 0 || quality > 100 || profile < -1 || profile > 2) return 0;
    g_mutex_lock(&engine_mutex);
    int old8 = com.pref.icc.export_8bit_method, old16 = com.pref.icc.export_16bit_method;
    if (profile >= 0) com.pref.icc.export_8bit_method = com.pref.icc.export_16bit_method = profile;
    int ok = 0;
#ifdef HAVE_LIBJXL
    if (!g_file_test(path, G_FILE_TEST_EXISTS)) ok = savejxl(path, &image->fit, effort, quality, depth == 8) == 0;
#endif
    com.pref.icc.export_8bit_method = old8; com.pref.icc.export_16bit_method = old16;
    g_mutex_unlock(&engine_mutex); return ok;
}
int siril_image_export_jxl(SirilImage *image, const char *path, int depth, int effort, double quality) {
    return siril_image_export_jxl_profile(image, path, depth, effort, quality, -1);
}
int siril_image_export_profile(SirilImage *image, const char *path, int format, int depth, int quality, int profile) {
    if (profile < -1 || profile > 2) return 0;
    if (format == 4) return siril_image_export_jxl_profile(image, path, depth, 7, quality, profile);
    if (!image || !path || (format == 1 && !g_str_has_suffix(path, ".png")) ||
        (format == 2 && !g_str_has_suffix(path, ".jpg")) || (format == 3 && !g_str_has_suffix(path, ".tif"))) return 0;
    g_mutex_lock(&engine_mutex);
    int old8 = com.pref.icc.export_8bit_method, old16 = com.pref.icc.export_16bit_method;
    if (profile >= 0) com.pref.icc.export_8bit_method = com.pref.icc.export_16bit_method = profile;
    int ok = 0;
    if (g_file_test(path, G_FILE_TEST_EXISTS)) goto done;
#ifdef HAVE_LIBPNG
    if (format == 1 && (depth == 8 || depth == 16)) ok = savepng(path, &image->fit, depth / 8, image->fit.naxes[2] == 3) == 0;
#endif
#ifdef HAVE_LIBJPEG
    if (format == 2 && quality >= 1 && quality <= 100) ok = savejpg(path, &image->fit, quality, FALSE) == 0;
#endif
#ifdef HAVE_LIBTIFF
    if (format == 3 && (depth == 8 || depth == 16 || depth == 32)) ok = savetif(path, &image->fit, depth, NULL, NULL, FALSE, TRUE, FALSE) == 0;
#endif
done:
    com.pref.icc.export_8bit_method = old8; com.pref.icc.export_16bit_method = old16;
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_image_export(SirilImage *image, const char *path, int format, int depth, int quality) {
    return siril_image_export_profile(image, path, format, depth, quality, -1);
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
        reset_conv_kernel();
    }
    g_mutex_unlock(&engine_mutex);
}

static int run_advanced_locked(const char *path, char *error, size_t capacity);
static int run_commands_locked(const char *directory, const char *script, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!directory || !script) return 0;
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
        int result;
        if (valid_name && !g_ascii_strcasecmp(word[0], "native_advanced") && count == 2) {
            gchar *settings_path = g_shell_unquote(word[1], NULL);
            result = run_advanced_locked(settings_path, error, capacity) ? CMD_OK : CMD_GENERIC_ERROR;
            g_free(settings_path);
        } else {
            if (valid_name && (!g_ascii_strcasecmp(word[0], "spcc") || !g_ascii_strcasecmp(word[0], "spcc_list"))) load_spcc_metadata_if_needed();
            result = !valid_name ? CMD_NOT_FOUND : unsupported ? CMD_NOT_SCRIPTABLE : processcommand(line, TRUE);
        }
        g_free(parsed);
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
    return ok;
}

int siril_run_commands(const char *directory, const char *script, char *error, size_t capacity) {
    g_mutex_lock(&engine_mutex);
    int ok = run_commands_locked(directory, script, error, capacity);
    g_mutex_unlock(&engine_mutex);
    return ok;
}

/* Native tool previews own their result, including the original mask. Copy and
 * workspace release stay inside the same lock as command execution. A second
 * Swift actor can never replace gfit between execution and result capture. */
SirilImage *siril_tool_compute(const char *directory, const char *script, char *error, size_t capacity) {
    g_mutex_lock(&engine_mutex);
    initialize();
    memset(&com.selection, 0, sizeof com.selection);
    SirilImage *result = NULL;
    if (run_commands_locked(directory, script, error, capacity) && gfit->fdata && gfit->type == DATA_FLOAT) {
        double bytes = (double)gfit->rx * gfit->ry * (gfit->naxes[2] * sizeof(float) + 4);
        if (bytes < (double)get_available_memory() * 0.8) {
            result = g_try_new0(SirilImage, 1);
            if (result && copyfits(gfit, &result->fit, CP_ALLOC | CP_DEEPCOPY | CP_COPYMASK, 0)) {
                clearfits(&result->fit); g_free(result); result = NULL;
            }
        }
        if (!result && error && capacity) snprintf(error, capacity, "Not enough memory to retain this tool preview");
    }
    close_sequence(FALSE);
    close_single_image();
    memset(&com.selection, 0, sizeof com.selection);
    g_mutex_unlock(&engine_mutex);
    return result;
}
int siril_image_load_mask(SirilImage *image, const char *path) {
    if (!image || !path) return 0;
    g_mutex_lock(&engine_mutex);
    fits mask = {0};
    int ok = !readfits(path, &mask, NULL, TRUE) && mask.rx == image->fit.rx && mask.ry == image->fit.ry && mask.naxes[2] == 1;
    if (ok) {
        int depth = mask.orig_bitpix == BYTE_IMG ? 8 : mask.type == DATA_USHORT ? 16 : 32;
        ok = !mask_create_from_channel(&image->fit, &mask, 0, depth);
    }
    clearfits(&mask);
    g_mutex_unlock(&engine_mutex);
    return ok;
}
SirilImage *siril_image_mask_copy(SirilImage *image) {
    if (!image) return NULL;
    g_mutex_lock(&engine_mutex);
    fits *mask = mask_to_fits(&image->fit);
    SirilImage *result = NULL;
    /* Upstream mask_to_fits clones the RGB source format but changes only
     * naxes[2]. A persisted single-channel mask also needs a 2-D FITS header. */
    if (mask) mask->naxis = 2;
    if (mask && mask->type == DATA_USHORT) {
        float *pixels = ushort_buffer_to_float(mask->data, (size_t)mask->rx * mask->ry);
        if (pixels) {
            g_free(mask->data); mask->data = NULL;
            for (int c = 0; c < 3; c++) { mask->pdata[c] = NULL; mask->fpdata[c] = pixels; }
            mask->fdata = pixels; mask->type = DATA_FLOAT; mask->bitpix = FLOAT_IMG; mask->orig_bitpix = FLOAT_IMG;
        }
    }
    if (mask && mask->type == DATA_FLOAT) {
        result = g_try_new0(SirilImage, 1);
        if (result) { result->fit = *mask; g_free(mask); mask = NULL; }
    }
    if (mask) { clearfits(mask); g_free(mask); }
    g_mutex_unlock(&engine_mutex);
    return result;
}
#include "SirilDisplay.inc"
#include "SirilAdvanced.inc"
#include "SirilSER.inc"
#include "SirilVideo.inc"
