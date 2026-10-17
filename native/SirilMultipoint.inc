// SPDX-License-Identifier: GPL-3.0-or-later
#include "registration/mpp.h"
#include "registration/mpp/mpp_config.h"
#include "registration/mpp/mpp_ap.h"
#include "registration/mpp/mpp_shift.h"
#include "registration/mpp/mpp_sidecar.h"

struct SirilMultipointAnalysis { mpp_run_t *run; };
SirilMultipointAnalysis *siril_multipoint_open(const char *sidecar, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    g_mutex_lock(&engine_mutex); initialize();
    SirilMultipointAnalysis *analysis = NULL;
    mpp_run_t *run = NULL;
    if (sidecar && g_path_is_absolute(sidecar) && g_str_has_suffix(sidecar, ".mpp") &&
            mpp_sidecar_read(sidecar, &run) == MPP_OK && run && run->aps && run->mean_frame_data &&
            run->mean_frame_rows > 0 && run->mean_frame_cols > 0) {
        analysis = g_try_new0(SirilMultipointAnalysis, 1);
        if (analysis) { analysis->run = run; run = NULL; }
    }
    if (run) mpp_run_free(run);
    if (!analysis && error && capacity) snprintf(error, capacity, "Cannot open original multipoint analysis");
    g_mutex_unlock(&engine_mutex);
    return analysis;
}
void siril_multipoint_close(SirilMultipointAnalysis *analysis) {
    if (!analysis) return;
    g_mutex_lock(&engine_mutex);
    mpp_run_free(analysis->run); g_free(analysis);
    g_mutex_unlock(&engine_mutex);
}
int siril_multipoint_info(SirilMultipointAnalysis *analysis, SirilMultipointAnalysisInfo *info) {
    if (!analysis || !info) return 0;
    g_mutex_lock(&engine_mutex);
    mpp_run_t *run = analysis->run;
    int included = 0;
    for (int i = 0; i < run->num_frames; i++) if (run->included[i]) included++;
    *info = (SirilMultipointAnalysisInfo){run->mean_frame_cols, run->mean_frame_rows,
        run->num_frames, included, run->aps->count, run->best_frame_idx,
        run->best_frame_indices != NULL && run->shifts != NULL};
    g_mutex_unlock(&engine_mutex);
    return 1;
}
int siril_multipoint_point(SirilMultipointAnalysis *analysis, int index, SirilMultipointPoint *point) {
    if (!analysis || !point) return 0;
    g_mutex_lock(&engine_mutex);
    mpp_run_t *run = analysis->run;
    int ok = index >= 0 && index < run->aps->count;
    if (ok) {
        const mpp_ap_record_t *p = &run->aps->records[index];
        *point = (SirilMultipointPoint){p->x, run->mean_frame_rows - 1 - p->y,
            p->box_x_low, run->mean_frame_rows - p->box_y_high,
            p->box_x_high - p->box_x_low, p->box_y_high - p->box_y_low,
            p->patch_x_low, run->mean_frame_rows - p->patch_y_high,
            p->patch_x_high - p->patch_x_low, p->patch_y_high - p->patch_y_low, p->structure};
    }
    g_mutex_unlock(&engine_mutex);
    return ok;
}
SirilImage *siril_multipoint_reference(SirilMultipointAnalysis *analysis, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!analysis) return NULL;
    g_mutex_lock(&engine_mutex);
    mpp_run_t *run = analysis->run;
    SirilImage *image = NULL;
    size_t pixels = (size_t)run->mean_frame_cols * run->mean_frame_rows;
    if ((double)pixels * sizeof(float) <= (double)get_available_memory() * .8) {
        image = g_try_new0(SirilImage, 1);
        fits *fit = image ? &image->fit : NULL;
        if (!image || new_fit_image(&fit, run->mean_frame_cols, run->mean_frame_rows, 1, DATA_FLOAT)) {
            g_free(image); image = NULL;
        } else {
            for (size_t i = 0; i < pixels; i++) fit->fdata[i] = (float)run->mean_frame_data[i] / 65535.f;
        }
    }
    if (!image && error && capacity) snprintf(error, capacity, "Cannot allocate multipoint reference preview");
    g_mutex_unlock(&engine_mutex);
    return image;
}

struct embedded_multipoint_args {
    sequence *seq;
    mpp_config_t config;
    const char *sidecar;
    SirilImage *image;
    SirilMultipointInfo info;
};
static gpointer embedded_multipoint_thread(gpointer pointer) {
    struct embedded_multipoint_args *args = pointer;
    mpp_run_t *run = NULL;
    int result = mpp_analyze(args->seq, &args->config, &run);
    if (!result && (!run || !run->aps || run->aps->count < 1)) result = MPP_ENODATA;
    if (!result) result = mpp_recompute_qualities(args->seq, run);
    if (!result && args->config.alignment_points_de_warp) {
        result = mpp_compute_shifts(args->seq, run->cfg, run);
    } else if (!result) {
        // Pinned MPP exposes de_warp in its GUI/config but never reads it.
        // A global-only stack uses the original AP merge with zero local
        // displacement; the global subpixel offsets remain in the run.
        size_t count = (size_t)run->num_frames * run->aps->count;
        run->shifts = calloc(1, sizeof *run->shifts);
        if (!run->shifts) result = MPP_ENOMEM;
        else {
            run->shifts->num_frames = run->num_frames;
            run->shifts->num_aps = run->aps->count;
            run->shifts->shifts = calloc(count * 2, sizeof(double));
            run->shifts->success = calloc(count, sizeof(uint8_t));
            if (!run->shifts->shifts || !run->shifts->success) result = MPP_ENOMEM;
            else for (int i = 0; i < run->num_frames; i++) if (run->included[i])
                memset(run->shifts->success + (size_t)i * run->aps->count, 1, run->aps->count);
        }
    }
    if (!result) result = mpp_sidecar_write(args->sidecar, run);
    if (!result) {
        args->info = (SirilMultipointInfo){run->num_frames, args->seq->selnum,
            run->aps->count, run->shifts ? run->shifts->failure_counter : 0,
            run->best_frame_idx, run->stack_size};
        result = mpp_stack_apply(args->seq, run->cfg, run, &args->image->fit);
    }
    if (run) mpp_run_free(run);
    stop_processing_thread();
    return GINT_TO_POINTER(result);
}
SirilImage *siril_sequence_multipoint_stack(const char *directory, const char *name,
        const char *sidecar, const SirilMultipointOptions *options, SirilMultipointInfo *info,
        char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (info) memset(info, 0, sizeof *info);
    g_mutex_lock(&engine_mutex); initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    SirilImage *image = NULL;
    sequence *seq = embedded_sequence(directory, name, error, capacity);
    if (!seq) goto done;
    if (!options || !sidecar || !g_path_is_absolute(sidecar) || !g_str_has_suffix(sidecar, ".mpp") ||
            g_file_test(sidecar, G_FILE_TEST_EXISTS) || seq->is_variable || seq->is_drizzle || seq->selnum < 2 ||
            options->alignment < 0 || options->alignment > 1 || options->half_box < 8 || options->half_box > 128 ||
            options->half_box * 2 > MIN(seq->rx, seq->ry) || options->search < 1 || options->search > 64 ||
            options->register_percent < 1 || options->register_percent > 100 || options->stack_percent < 1 ||
            options->stack_percent > options->register_percent || !isfinite(options->structure) ||
            options->structure < 0 || options->structure > 1 || !isfinite(options->scale) ||
            options->scale < 1 || options->scale > 3 || !isfinite(options->smooth_radius) ||
            options->smooth_radius < 0 || options->smooth_radius > 10 || !isfinite(options->background_fraction) ||
            options->background_fraction < 0 || options->background_fraction > 1 || !isfinite(options->background_blend) ||
            options->background_blend < 0 || options->background_blend > 1) {
        if (error && capacity) snprintf(error, capacity, "Invalid multipoint options, input sequence or analysis path");
        goto cleanup;
    }
    for (int layer = 0; layer < seq->nb_layers; layer++) if (layer_has_distortion(seq, layer)) {
        if (error && capacity) snprintf(error, capacity, "Multipoint input with existing distortion is not supported");
        goto cleanup;
    }
    image = g_try_new0(SirilImage, 1);
    if (!image) goto cleanup;
    struct embedded_multipoint_args args = {.seq = seq, .sidecar = sidecar, .image = image};
    mpp_config_defaults(&args.config);
    args.config.bitdepth = mpp_bitdepth_from_fits_bitpix(seq->bitpix);
    args.config.align_frames_mode = options->alignment;
    args.config.alignment_points_half_box_width = options->half_box;
    args.config.alignment_points_search_width = options->search;
    args.config.alignment_points_structure_threshold = options->structure;
    args.config.alignment_points_frame_percent = options->register_percent;
    args.config.stack_frame_percent = options->stack_percent;
    args.config.frames_normalization = !!options->normalize;
    // The pinned streaming correlator always fits subpixel peaks.
    args.config.alignment_points_refine_reference = !!options->refine;
    args.config.alignment_points_de_warp = !!options->dewarp;
    args.config.alignment_points_smooth_radius = options->smooth_radius;
    args.config.stack_skip_failed_aps = !!options->skip_failed;
    args.config.output_32bit = !!options->float_output;
    args.config.output_scale = options->scale;
    args.config.stack_frames_background_fraction = options->background_fraction;
    args.config.stack_frames_background_blend_threshold = options->background_blend;
    waiting_for_thread();
    int ok = start_in_new_thread(embedded_multipoint_thread, &args) &&
        GPOINTER_TO_INT(waiting_for_thread()) == MPP_OK && !g_atomic_int_get(&cancel_requested);
    if (ok && image->fit.rx > 0 && image->fit.ry > 0 && (image->fit.data || image->fit.fdata)) {
        if (info) *info = args.info;
    } else {
        clearfits(&image->fit); g_free(image); image = NULL;
    }
cleanup:
    free_sequence(seq, TRUE);
done:
    if (!image && error && capacity && !*error) snprintf(error, capacity, "Original multipoint processing failed or cancelled; inspect processing log");
    g_mutex_unlock(&engine_mutex);
    return image;
}
