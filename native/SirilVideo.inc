// SPDX-License-Identifier: GPL-3.0-or-later
#include "io/films.h"

int32_t siril_video_count(const char *path, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    int32_t count = -1;
    g_mutex_lock(&engine_mutex); initialize();
#ifdef HAVE_FFMS2
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
#else
    if (error && capacity) snprintf(error, capacity, "Video decoder was not built");
#endif
    g_mutex_unlock(&engine_mutex);
    return count;
}
