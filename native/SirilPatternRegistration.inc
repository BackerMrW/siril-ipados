// SPDX-License-Identifier: GPL-3.0-or-later
#include "registration/registration.h"
#include "registration/3stars.h"
extern void siril_ipados_reset_three_stars(void);
static int displayed_region(fits *fit, const SirilRegion *input, rectangle *area);
static int embedded_register_manual_stars(struct registration_args *args) {
    int expected = args->seq->selnum;
    rectangle previous = com.selection;
    int result = register_3stars(args);
    com.selection = previous;
    if (result || args->seq->selnum != expected) return 1;
    regdata *data = args->seq->regparam[args->layer];
    for (int i = 0; i < args->seq->number; i++) {
        if (!args->seq->imgparam[i].incl) continue;
        if (!data || !isfinite(data[i].fwhm) || data[i].fwhm <= 0 || data[i].number_of_stars < 2) return 1;
        Homography h = data[i].H;
        double values[] = { h.h00, h.h01, h.h02, h.h10, h.h11, h.h12, h.h20, h.h21, h.h22 };
        for (int j = 0; j < 9; j++) if (!isfinite(values[j])) return 1;
        if (fabs(h.h00 * h.h11 - h.h01 * h.h10) < 1e-12 || h.h22 == 0) return 1;
    }
    return 0;
}
static int embedded_register_single_star(struct registration_args *args) {
    rectangle previous = com.selection;
    com.selection = args->selection;
    int result = register_shift_fwhm(args);
    com.selection = previous;
    if (!result) {
        regdata *data = args->seq->regparam[args->layer];
        for (int i = 0; i < args->seq->number; i++) {
            if (args->seq->imgparam[i].incl && (!data || !data[i].fwhm_data || !isfinite(data[i].fwhm) || data[i].fwhm <= 0)) return 1;
            // PSF registration measures FWHM, not the previous DFT/KOMBAT score.
            if (data) data[i].quality = 0;
        }
    }
    return result;
}
static int embedded_pattern_register(const char *directory, const char *name,
        int method, int layer, const SirilRegion *region, int count, double moved,
        char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    g_mutex_lock(&engine_mutex); initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    int ok = 0;
    sequence *seq = embedded_sequence(directory, name, error, capacity);
    if (!seq) goto done;
    if (!region || count < 1 || count > 3 || method < 0 || method > 7 || layer < 0 || layer >= seq->nb_layers ||
            (method < 4 && count != 1) || (method >= 4 && (count < 2 || seq->is_drizzle || layer_has_distortion(seq, layer))) ||
            seq->selnum < 2 || seq->is_variable || !isfinite(moved) || moved < 0 || moved > 1 ||
            (method == 1 && moved < .05) ||
            region->x < 0 || region->y < 0 || region->width < 8 || region->height < 8 ||
            region->width > seq->rx || region->height > seq->ry ||
            region->x > seq->rx - region->width || region->y > seq->ry - region->height ||
            (method == 0 && region->width != region->height) ||
            (double)seq->rx * seq->ry * 96 > (double)get_available_memory() * .8) {
        if (error && capacity) snprintf(error, capacity, "Invalid pattern registration selection, layer or memory budget");
        free_sequence(seq, TRUE); goto done;
    }
    for (int i = 1; i < count; i++) {
        if (region[i].x < 0 || region[i].y < 0 || region[i].width < 8 || region[i].height < 8 ||
                region[i].width > seq->rx || region[i].height > seq->ry ||
                region[i].x > seq->rx - region[i].width || region[i].y > seq->ry - region[i].height) {
            if (error && capacity) snprintf(error, capacity, "Invalid manual star selection");
            free_sequence(seq, TRUE); goto done;
        }
        for (int j = 0; j < i; j++) {
            if (region[i].x < region[j].x + region[j].width && region[j].x < region[i].x + region[i].width &&
                    region[i].y < region[j].y + region[j].height && region[j].y < region[i].y + region[i].height) {
                if (error && capacity) snprintf(error, capacity, "Manual star selections overlap");
                free_sequence(seq, TRUE); goto done;
            }
        }
    }
    if (seq->reference_image < 0) seq->reference_image = get_first_selected(seq);
    if (seq->reference_image < 0 || seq->reference_image >= seq->number || !seq->imgparam[seq->reference_image].incl) {
        if (error && capacity) snprintf(error, capacity, "Pattern registration reference is excluded");
        free_sequence(seq, TRUE); goto done;
    }
    struct registration_args *args = calloc(1, sizeof *args);
    if (!args) { free_sequence(seq, TRUE); goto done; }
    args->seq = seq;
    args->func = method >= 4 ? embedded_register_manual_stars : method == 0 ? register_shift_dft : method == 1 ? register_kombat : embedded_register_single_star;
    args->layer = layer; args->reference_image = seq->reference_image;
    args->selection = (rectangle){region->x, region->y, region->width, region->height};
    if (method >= 2) {
        fits reference = {0};
        int valid = !seq_read_frame(seq, seq->reference_image, &reference, TRUE, -1) &&
            displayed_region(&reference, region, &args->selection);
        seq->current = seq->reference_image;
        args->follow_star = method == 3 || method >= 6;
        if (method >= 4) {
            siril_ipados_reset_three_stars();
            selected_stars = count;
            for (int i = 0; i < count && valid; i++) valid = displayed_region(&reference, &region[i], &_3boxes[i]);
        }
        clearfits(&reference);
        if (!valid) { free_sequence(seq, TRUE); free(args); goto done; }
    }
    args->filters.filter_included = TRUE;
    args->run_in_thread = TRUE; args->no_output = TRUE;
    args->output_scale = 1; args->type = SHIFT_TRANSFORMATION;
    if (method >= 4 && method % 2) args->type = SIMILARITY_TRANSFORMATION;
    args->percent_moved = moved;
    waiting_for_thread();
    if (!start_in_new_thread(register_thread_func, args)) {
        free_sequence(seq, TRUE); free(args); goto done;
    }
    // Original register_thread_func owns and frees args and the loaded sequence.
    ok = GPOINTER_TO_INT(waiting_for_thread()) == 0 && !g_atomic_int_get(&cancel_requested);
done:
    if (method >= 4) siril_ipados_reset_three_stars();
    if (!ok && error && capacity && !*error) snprintf(error, capacity, "Pattern registration failed or cancelled; inspect processing log");
    g_mutex_unlock(&engine_mutex);
    return ok;
}
int siril_sequence_pattern_register(const char *directory, const char *name,
        int method, int layer, const SirilRegion *region, double moved,
        char *error, size_t capacity) {
    if (method < 0 || method > 3) return 0;
    return embedded_pattern_register(directory, name, method, layer, region, 1, moved, error, capacity);
}
int siril_sequence_manual_stars_register(const char *directory, const char *name,
        int layer, const SirilRegion *regions, int count, int rotation, int follow,
        char *error, size_t capacity) {
    return embedded_pattern_register(directory, name, 4 + !!rotation + 2 * !!follow,
        layer, regions, count, 0, error, capacity);
}
