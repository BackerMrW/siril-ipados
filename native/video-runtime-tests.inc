// SPDX-License-Identifier: GPL-3.0-or-later
#include "io/films.h"
static int video_cancellation_checks(const char *directory) {
    char source[4096], path[4096], index[4096], output[4096], error[512];
    snprintf(source, sizeof source, "%s/video-rgb.avi", getenv("SIRIL_FORMAT_FIXTURES"));
    snprintf(path, sizeof path, "%s/video-cancel.avi", directory);
    snprintf(index, sizeof index, "%s.idx", path);
    snprintf(output, sizeof output, "%s/video-conversion", directory);
    gchar *bytes = NULL; gsize size = 0;
    CHECK(g_file_get_contents(source, &bytes, &size, NULL));
    CHECK(g_file_set_contents(path, bytes, size, NULL));
    siril_cancel_processing();
    struct film_struct film = {0};
    CHECK(film_open_file(path, &film) != FILM_SUCCESS);
    film_close_file(&film);
    CHECK(!g_file_test(index, G_FILE_TEST_EXISTS));
    CHECK(g_mkdir_with_parents(output, 0700) == 0);
    CHECK(siril_video_convert(output, path, 0, error, sizeof error) == 3);
    gchar *after = NULL; gsize after_size = 0;
    CHECK(g_file_get_contents(path, &after, &after_size, NULL));
    CHECK(after_size == size && memcmp(bytes, after, size) == 0);
    g_free(bytes); g_free(after);
    snprintf(path, sizeof path, "%s/capture.ser", output);
    SirilSER *session = siril_ser_open(path, error, sizeof error); CHECK(session);
    CHECK(siril_ser_complete(session) && siril_ser_count(session) == 3);
    siril_ser_close(session);
    puts("PASS: original FFMS indexing honored cancellation without publishing an index; subsequent native video conversion succeeded and preserved its source");
    return 0;
}
