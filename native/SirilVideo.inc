// SPDX-License-Identifier: GPL-3.0-or-later
#include "io/films.h"
#include "io/conversion.h"

#ifdef HAVE_FFMS2
static int32_t embedded_video_count(const char *path, char *error, size_t capacity) {
    int32_t count = -1;
    struct film_struct film = {0};
    fits first = {0};
    if (path && !film_open_file(path, &film) && film.frame_count > 0 &&
            film.width > 0 && film.height > 0 && film.width <= MAX_IMAGE_DIM && film.height <= MAX_IMAGE_DIM &&
            (double)film.width * film.height * 3 * 16 <= (double)get_available_memory() * .8 &&
            !film_read_frame(&film, 0, &first)) count = film.frame_count;
    if (count < 0 && error && capacity)
        snprintf(error, capacity, "Cannot decode video within the frame memory budget: %s", film.errmsg ? film.errmsg : "unsupported file");
    clearfits(&first);
    film_close_file(&film);
    return count;
}
#endif

int32_t siril_video_convert(const char *directory, const char *path, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    int32_t count = -1;
    g_mutex_lock(&engine_mutex); initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex);
    if (processing_log) g_string_truncate(processing_log, 0);
    g_mutex_unlock(&log_mutex);
#ifdef HAVE_FFMS2
    gchar *message = NULL;
    if (!directory || !path || !g_path_is_absolute(path) || siril_change_dir(directory, &message) ||
            g_file_test("capture.ser", G_FILE_TEST_EXISTS) || g_file_test("capture.seq", G_FILE_TEST_EXISTS)) goto done;
    count = embedded_video_count(path, error, capacity);
    if (count < 2 || g_atomic_int_get(&cancel_requested)) { count = -1; goto done; }
    struct _convert_data *args = calloc(1, sizeof *args);
    if (!args) { count = -1; goto done; }
    args->list = g_new0(gchar *, 2);
    args->list[0] = g_strdup(path); args->total = 1; args->start = 1;
    args->destroot = g_strdup("capture.ser"); args->output_type = SEQ_SER;
    args->input_has_a_seq = TRUE; args->input_has_a_film = TRUE;
    gettimeofday(&args->t_start, NULL);
    waiting_for_thread();
    if (!start_in_new_thread(convert_thread_worker, args)) {
        g_strfreev(args->list); g_free(args->destroot); free(args); count = -1; goto done;
    }
    int result = GPOINTER_TO_INT(waiting_for_thread()); // Worker owns args and writer.
    if (result || g_atomic_int_get(&cancel_requested) || !g_file_test("capture.ser", G_FILE_TEST_EXISTS)) count = -1;
done: // message is borrowed from the original log.
#endif
    if (count < 0 && error && capacity && !*error)
        snprintf(error, capacity, "Video conversion needs at least two decodable frames and a new output directory");
    g_mutex_unlock(&engine_mutex);
    return count;
}
