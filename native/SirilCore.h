// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SIRIL_IPADOS_CORE_H
#define SIRIL_IPADOS_CORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SirilImage SirilImage;
typedef struct {
    uint32_t width, height, channels;
    int32_t working_bitpix, gain, offset; /* loaded representation; imports are normalized float */
    double exposure, temperature;
    char object[80], bayer[80];
} SirilImageInfo;
typedef struct {
    uint32_t width, height;
    uint8_t *rgba;
} SirilPreview;
const char *siril_core_version(void);
/* All operations are serialized because upstream Siril uses global state. */
SirilImage *siril_image_read(const char *path, char *error, size_t error_size);
void siril_image_free(SirilImage *image);
int siril_image_info(const SirilImage *image, SirilImageInfo *info);
/* Display-only RGBA using upstream Siril's linked automatic MTF stretch. */
int siril_image_preview(SirilImage *image, uint32_t max_dimension, SirilPreview *preview);
void siril_preview_free(SirilPreview *preview);
/* These call upstream Siril imoper/soper, not replacement arithmetic. */
int siril_image_add(SirilImage *destination, const SirilImage *source);
int siril_image_subtract(SirilImage *destination, const SirilImage *source);
int siril_image_divide_scalar(SirilImage *image, float divisor);
/* Export a new floating-point FITS; refuses to overwrite an existing path. */
int siril_image_write(const SirilImage *image, const char *path);
/* Execute original Siril commands synchronously, stopping at the first error.
 * Blank lines and # comments are accepted. No desktop process or GTK loop.
 * Returns 1 on success; errors identify the source line. */
int siril_run_commands(const char *directory, const char *script, char *error, size_t error_size);
/* Independent of the engine lock, so UI can read logs and cancel a running job. */
void siril_copy_processing_log(char *buffer, size_t capacity);
void siril_cancel_processing(void);
#ifdef __cplusplus
}
#endif
#endif
