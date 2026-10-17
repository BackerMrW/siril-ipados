// SPDX-License-Identifier: GPL-3.0-or-later
#include "registration/mpp.h"
#include "registration/mpp/mpp_config.h"
#include "registration/mpp/mpp_ap.h"
#include "registration/mpp/mpp_shift.h"
#include "registration/mpp/mpp_sidecar.h"

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
