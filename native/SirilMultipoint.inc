// SPDX-License-Identifier: GPL-3.0-or-later
#include "registration/mpp.h"
#include "registration/mpp/mpp_config.h"
#include "registration/mpp/mpp_ap.h"
#include "registration/mpp/mpp_shift.h"
#include "registration/mpp/mpp_sidecar.h"

struct SirilMultipointAnalysis { mpp_run_t *run; };
extern mpp_status_t embedded_mpp_ap_replace(mpp_run_t *run);
static void embedded_mpp_invalidate_shifts(mpp_run_t *run) {
    free(run->best_frame_indices); run->best_frame_indices = NULL;
    if (run->shifts) mpp_shift_free(run->shifts);
    run->shifts = NULL;
}
static int embedded_mpp_restore_points(mpp_run_t *run, const SirilMultipointPoint *points, int count) {
    int width = run->mean_frame_cols, height = run->mean_frame_rows;
    if (count < 0 || count > 10000000 || (count && !points) ||
            (double)count * sizeof(mpp_ap_record_t) > (double)get_available_memory() * .5) return 0;
    for (int i = 0; i < count; i++) {
        const SirilMultipointPoint *p = &points[i];
        if (p->x < 0 || p->x >= width || p->y < 0 || p->y >= height ||
                p->box_width <= 0 || p->box_width > width || p->box_height <= 0 || p->box_height > height ||
                p->box_x < 0 || p->box_x > width - p->box_width || p->box_y < 0 || p->box_y > height - p->box_height ||
                p->patch_width < p->box_width || p->patch_width > width ||
                p->patch_height < p->box_height || p->patch_height > height ||
                p->patch_x < 0 || p->patch_x > width - p->patch_width || p->patch_y < 0 || p->patch_y > height - p->patch_height ||
                p->patch_x > p->box_x || p->patch_y > p->box_y ||
                p->patch_x + p->patch_width < p->box_x + p->box_width ||
                p->patch_y + p->patch_height < p->box_y + p->box_height ||
                p->x < p->box_x || p->x >= p->box_x + p->box_width ||
                p->y < p->box_y || p->y >= p->box_y + p->box_height ||
                !isfinite(p->structure) || p->structure < 0) return 0;
    }
    mpp_aps_t *snapshot = calloc(1, sizeof *snapshot);
    if (!snapshot) return 0;
    snapshot->count = count; snapshot->user_edited = 1;
    snapshot->dropped_dim = run->aps->dropped_dim;
    snapshot->dropped_structure = run->aps->dropped_structure;
    if (count) {
        snapshot->records = calloc((size_t)count, sizeof *snapshot->records);
        if (!snapshot->records) { mpp_ap_free(snapshot); return 0; }
    }
    for (int i = 0; i < count; i++) {
        const SirilMultipointPoint *p = &points[i];
        snapshot->records[i] = (mpp_ap_record_t){
            .x = p->x, .y = height - 1 - p->y,
            .box_x_low = p->box_x, .box_x_high = p->box_x + p->box_width,
            .box_y_low = height - p->box_y - p->box_height, .box_y_high = height - p->box_y,
            .patch_x_low = p->patch_x, .patch_x_high = p->patch_x + p->patch_width,
            .patch_y_low = height - p->patch_y - p->patch_height, .patch_y_high = height - p->patch_y,
            .structure = p->structure};
    }
    mpp_aps_restore(run, snapshot);
    embedded_mpp_invalidate_shifts(run);
    return 1;
}
int siril_multipoint_restore_points(SirilMultipointAnalysis *analysis,
        const SirilMultipointPoint *points, int count, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!analysis) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = embedded_mpp_restore_points(analysis->run, points, count);
    if (!ok && error && capacity) snprintf(error, capacity, "Invalid multipoint snapshot or memory budget");
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_multipoint_edit(SirilMultipointAnalysis *analysis, int action, int index,
        int x, int y, int half_box, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!analysis) return 0;
    g_mutex_lock(&engine_mutex);
    mpp_run_t *run = analysis->run;
    int result = MPP_EINVAL;
    if (action == 4) { mpp_ap_clear_all(run); result = MPP_OK; }
    else if (action == 5) result = embedded_mpp_ap_replace(run);
    else if (action == 2) result = mpp_ap_remove(run, index);
    else if (action == 3 && half_box >= 6 && half_box <= 128) result = mpp_ap_set_half_box(run, index, half_box);
    else if ((action == 0 || action == 1) && x >= 0 && x < run->mean_frame_cols && y >= 0 && y < run->mean_frame_rows) {
        int native_x, native_y;
        mpp_display_to_ap_coord(run, run->mean_frame_cols, run->mean_frame_rows, -1, x, y, &native_x, &native_y);
        if (action == 0 && half_box >= 6 && half_box <= 128) {
            result = mpp_ap_add(run, native_x, native_y);
            if (!result) result = mpp_ap_set_half_box(run, run->aps->count - 1, half_box);
        } else if (action == 1) {
            int previous = mpp_ap_get_half_box(run, index);
            result = mpp_ap_move(run, index, native_x, native_y);
            if (!result) result = mpp_ap_set_half_box(run, index, previous);
        }
    }
    if (!result) embedded_mpp_invalidate_shifts(run);
    else if (error && capacity) snprintf(error, capacity, "Cannot edit AP; check selection and search margin at the reference boundary");
    g_mutex_unlock(&engine_mutex);
    return result == MPP_OK;
}
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
    const char *input;
    const SirilMultipointPoint *points;
    int point_count;
    SirilImage *image;
    SirilMultipointInfo info;
};
static gpointer embedded_multipoint_thread(gpointer pointer) {
    struct embedded_multipoint_args *args = pointer;
    mpp_run_t *run = NULL;
    int result = args->input ? mpp_sidecar_read(args->input, &run) : mpp_analyze(args->seq, &args->config, &run);
    if (!result && args->input) {
        sequence *seq = args->seq;
        if (!run || !run->cfg || !run->included || run->num_frames != seq->number ||
                run->frame_cols != seq->rx || run->frame_rows != seq->ry || run->num_layers != seq->nb_layers ||
                run->bitdepth != mpp_bitdepth_from_fits_bitpix(seq->bitpix)) result = MPP_EINVAL;
        for (int i = 0; !result && i < seq->number; i++)
            if (!!run->included[i] != !!seq->imgparam[i].incl) result = MPP_EINVAL;
        if (!result) {
            // Resume uses the baked analysis configuration, never recomputes
            // Stage A or silently replaces the edited alignment points.
            args->config = *run->cfg;
            if (args->point_count >= 0 && !embedded_mpp_restore_points(run, args->points, args->point_count)) result = MPP_EINVAL;
            if (!result) embedded_mpp_invalidate_shifts(run);
        }
    }
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
static SirilImage *embedded_multipoint_process(const char *directory, const char *name,
        const char *input, const SirilMultipointPoint *points, int count,
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
    if (!sidecar || !g_path_is_absolute(sidecar) || !g_str_has_suffix(sidecar, ".mpp") ||
            g_file_test(sidecar, G_FILE_TEST_EXISTS) || seq->is_variable || seq->is_drizzle || seq->selnum < 2 ||
            (input && (!g_path_is_absolute(input) || !g_str_has_suffix(input, ".mpp") || count < -1)) ||
            (!input && (!options ||
            options->alignment < 0 || options->alignment > 1 || options->half_box < 8 || options->half_box > 128 ||
            options->half_box * 2 > MIN(seq->rx, seq->ry) || options->search < 1 || options->search > 64 ||
            options->register_percent < 1 || options->register_percent > 100 || options->stack_percent < 1 ||
            options->stack_percent > options->register_percent || !isfinite(options->structure) ||
            options->structure < 0 || options->structure > 1 || !isfinite(options->scale) ||
            options->scale < 1 || options->scale > 3 || !isfinite(options->smooth_radius) ||
            options->smooth_radius < 0 || options->smooth_radius > 10 || !isfinite(options->background_fraction) ||
            options->background_fraction < 0 || options->background_fraction > 1 || !isfinite(options->background_blend) ||
            options->background_blend < 0 || options->background_blend > 1))) {
        if (error && capacity) snprintf(error, capacity, "Invalid multipoint options, input sequence or analysis path");
        goto cleanup;
    }
    for (int layer = 0; layer < seq->nb_layers; layer++) if (layer_has_distortion(seq, layer)) {
        if (error && capacity) snprintf(error, capacity, "Multipoint input with existing distortion is not supported");
        goto cleanup;
    }
    image = g_try_new0(SirilImage, 1);
    if (!image) goto cleanup;
    struct embedded_multipoint_args args = {.seq = seq, .sidecar = sidecar, .image = image,
        .input = input, .points = points, .point_count = count};
    mpp_config_defaults(&args.config);
    if (options) {
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
    }
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
SirilImage *siril_sequence_multipoint_stack(const char *directory, const char *name,
        const char *sidecar, const SirilMultipointOptions *options, SirilMultipointInfo *info,
        char *error, size_t capacity) {
    return embedded_multipoint_process(directory, name, NULL, NULL, -1, sidecar, options, info, error, capacity);
}
SirilImage *siril_sequence_multipoint_resume(const char *directory, const char *name,
        const char *input, const SirilMultipointPoint *points, int count,
        const char *sidecar, SirilMultipointInfo *info, char *error, size_t capacity) {
    if (!input) return NULL;
    return embedded_multipoint_process(directory, name, input, points, count, sidecar, NULL, info, error, capacity);
}
