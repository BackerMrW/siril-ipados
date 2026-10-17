// SPDX-License-Identifier: GPL-3.0-or-later
#include "registration/registration.h"
#include "opencv/opencv.h"

static int comet_valid_matrix(Homography h) {
    double values[] = {h.h00, h.h01, h.h02, h.h10, h.h11, h.h12, h.h20, h.h21, h.h22};
    for (int i = 0; i < 9; i++) if (!isfinite(values[i])) return 0;
    double determinant = h.h00 * (h.h11 * h.h22 - h.h12 * h.h21) -
        h.h01 * (h.h10 * h.h22 - h.h12 * h.h20) + h.h02 * (h.h10 * h.h21 - h.h11 * h.h20);
    return isfinite(determinant) && determinant != 0;
}

static gpointer embedded_comet_thread(gpointer pointer) {
    struct registration_args *args = pointer;
    // register_thread_func also rewrites the input .seq. This worker only
    // generates the original comet output and leaves its source untouched.
    int result = register_comet(args);
    if (!args->new_seq_name) {
        if (args->imgparam) for (int i = 0; i < args->seq->number; i++)
            if (args->imgparam[i].date_obs) g_date_time_unref(args->imgparam[i].date_obs);
        free(args->imgparam);
        free(args->regparam);
    }
    if (args->reference_date) g_date_time_unref(args->reference_date);
    g_free(args->prefix); g_free(args->new_seq_name);
    stop_processing_thread();
    free_sequence(args->seq, TRUE); free(args);
    return GINT_TO_POINTER(result);
}

int siril_sequence_comet_register(const char *directory, const char *name,
        const char *prefix, const SirilCometOptions *options, double *velocity,
        char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    g_mutex_lock(&engine_mutex); initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
    int ok = 0;
    sequence *seq = NULL;
    GDateTime *times[2] = {NULL, NULL};
    if (!options || !prefix || !g_str_has_prefix(prefix, "r_") || strlen(prefix) > 48) goto done;
    for (const char *p = prefix; *p; p++) if (!g_ascii_isalnum(*p) && *p != '_') goto done;
    seq = embedded_sequence(directory, name, error, capacity);
    if (!seq) goto done;
    int layer = options->layer;
    if (layer < 0 || layer >= seq->nb_layers || seq->selnum < 2 || seq->is_variable || seq->is_drizzle ||
            (seq->type != SEQ_REGULAR && seq->type != SEQ_FITSEQ && seq->type != SEQ_SER) || layer_has_distortion(seq, layer) ||
            options->first < 0 || options->first >= seq->number || options->second < 0 || options->second >= seq->number ||
            options->first == options->second || !isfinite(options->x1) || !isfinite(options->y1) ||
            !isfinite(options->x2) || !isfinite(options->y2) || options->x1 < 0 || options->x1 >= seq->rx ||
            options->x2 < 0 || options->x2 >= seq->rx || options->y1 < 0 || options->y1 >= seq->ry ||
            options->y2 < 0 || options->y2 >= seq->ry || strlen(prefix) + strlen(seq->seqname) > 230) {
        if (error && capacity) snprintf(error, capacity, "Comet registration needs two distinct valid frames/positions and a FITS/FITSEQ/SER sequence without Drizzle or distortion");
        goto done;
    }
    GDir *dir = g_dir_open(directory, 0, NULL);
    if (!dir) goto done;
    const char *entry; gboolean collision = FALSE;
    while ((entry = g_dir_read_name(dir))) if (g_str_has_prefix(entry, prefix)) { collision = TRUE; break; }
    g_dir_close(dir);
    if (collision) goto done;
    if (seq->reference_image < 0) seq->reference_image = get_first_selected(seq);
    int reference = seq->reference_image;
    if (reference < 0 || reference >= seq->number || !seq->imgparam[reference].incl) goto done;
    gboolean registered = layer_has_registration(seq, layer);
    for (int i = 0; i < seq->number; i++) {
        if (!seq->imgparam[i].incl && i != options->first && i != options->second) continue;
        fits metadata = {0};
        int valid = !seq_read_frame_metadata(seq, i, &metadata) && metadata.keywords.date_obs;
        if (valid && registered) valid = comet_valid_matrix(seq->regparam[layer][i].H);
        if (valid && i == options->first) times[0] = g_date_time_ref(metadata.keywords.date_obs);
        if (valid && i == options->second) times[1] = g_date_time_ref(metadata.keywords.date_obs);
        clearfits(&metadata);
        if (!valid) {
            if (error && capacity) snprintf(error, capacity, "Frame %d is missing DATE-OBS or existing registration", i + 1);
            goto done;
        }
    }
    if (!times[0] || !times[1] || !g_date_time_difference(times[1], times[0])) {
        if (error && capacity) snprintf(error, capacity, "Comet anchor timestamps must be present and different");
        goto done;
    }
    point first = {options->x1, options->y1}, second = {options->x2, options->y2};
    if (registered) {
        cvTransfPoint(&first.x, &first.y, seq->regparam[layer][options->first].H, seq->regparam[layer][reference].H, 1.0);
        cvTransfPoint(&second.x, &second.y, seq->regparam[layer][options->second].H, seq->regparam[layer][reference].H, 1.0);
    }
    pointf speed = compute_velocity(times[0], times[1], first, second);
    if (!isfinite(speed.x) || !isfinite(speed.y)) goto done;
    if (velocity) { velocity[0] = speed.x; velocity[1] = speed.y; }
    struct registration_args *args = calloc(1, sizeof *args);
    if (!args) goto done;
    args->seq = seq; args->layer = layer; args->reference_image = reference;
    args->velocity = speed; args->prefix = g_strdup(prefix); args->filters.filter_included = TRUE;
    args->run_in_thread = TRUE;
    waiting_for_thread();
    if (!start_in_new_thread(embedded_comet_thread, args)) { g_free(args->prefix); free(args); goto done; }
    seq = NULL; // The synchronous worker now owns the sequence and arguments.
    ok = GPOINTER_TO_INT(waiting_for_thread()) == 0 && !g_atomic_int_get(&cancel_requested);
done:
    for (int i = 0; i < 2; i++) if (times[i]) g_date_time_unref(times[i]);
    if (seq) free_sequence(seq, TRUE);
    if (!ok && error && capacity && !*error) snprintf(error, capacity, "Comet registration failed or cancelled; inspect processing log");
    g_mutex_unlock(&engine_mutex);
    return ok;
}
