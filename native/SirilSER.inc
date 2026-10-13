// SPDX-License-Identifier: GPL-3.0-or-later
#include "io/ser.h"
struct SirilSER { struct ser_struct file; };
SirilSER *siril_ser_open(const char *path, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!path) return NULL;
    g_mutex_lock(&engine_mutex); initialize();
    SirilSER *session = g_try_new0(SirilSER, 1);
    gboolean previous_debayer = com.pref.debayer.open_debayer;
    com.pref.debayer.open_debayer = FALSE;
    int failed = !session || ser_open_file(path, &session->file) != SER_OK;
    com.pref.debayer.open_debayer = previous_debayer;
    if (!failed) {
        const struct ser_struct *file = &session->file;
        double bytes = (double)file->image_width * file->image_height * file->number_of_planes * 16;
        failed = !file->frame_count || file->frame_count > INT_MAX ||
            file->image_width > MAX_IMAGE_DIM || file->image_height > MAX_IMAGE_DIM ||
            bytes > (double)get_available_memory() * .8;
    }
    if (failed) {
        if (session) { if (session->file.file) ser_close_file(&session->file); g_free(session); }
        session = NULL;
        if (error && capacity) snprintf(error, capacity, "Cannot open SER or a frame exceeds the available memory budget");
    }
    g_mutex_unlock(&engine_mutex); return session;
}
uint32_t siril_ser_count(const SirilSER *session) {
    return session ? session->file.frame_count : 0;
}
SirilImage *siril_ser_read(SirilSER *session, uint32_t index, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!session || index >= session->file.frame_count) {
        if (error && capacity) snprintf(error, capacity, "SER frame index is outside the sequence");
        return NULL;
    }
    g_mutex_lock(&engine_mutex);
    SirilImage *image = g_try_new0(SirilImage, 1);
    int failed = !image || ser_read_frame(&session->file, (int)index, &image->fit, TRUE, FALSE) != SER_OK;
    if (!failed) {
        import_metadata_from_serfile(&session->file, &image->fit);
        // The upstream reader has flipped the top-down SER raster to FITS
        // storage. Describe that buffer consistently to this displayed-pixel ABI.
        image->fit.top_down = FALSE;
        g_strlcpy(image->fit.keywords.row_order, "BOTTOM-UP", FLEN_VALUE);
    } else {
        if (image) { clearfits(&image->fit); g_free(image); }
        image = NULL;
        if (error && capacity) snprintf(error, capacity, "Original Siril could not decode this SER frame");
    }
    g_mutex_unlock(&engine_mutex); return image;
}
void siril_ser_close(SirilSER *session) {
    if (!session) return;
    g_mutex_lock(&engine_mutex); ser_close_file(&session->file); g_free(session); g_mutex_unlock(&engine_mutex);
}
