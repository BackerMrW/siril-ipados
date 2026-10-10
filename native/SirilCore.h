// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SIRIL_IPADOS_CORE_H
#define SIRIL_IPADOS_CORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SirilImage SirilImage;
typedef struct SirilBackground SirilBackground;
typedef struct {
    int32_t count, included, layers, reference, width, height, drizzle, type;
} SirilSequenceInfo;
typedef struct {
    int32_t index, file_number, included, width, height, has_registration, stars, has_statistics;
    double fwhm, weighted_fwhm, roundness, background, quality, translation_x, translation_y;
    double mean, median, sigma;
} SirilSequenceFrame;
/* Stateless reads use upstream readseqfile/seq_read_frame. name is an exact
 * .seq basename; index/reference are zero-based (-1 means automatic reference).
 * Returns frame count or -1 on error. NULL frames queries required capacity. */
int siril_sequence_inspect(const char *directory, const char *name, int layer,
    SirilSequenceInfo *info, SirilSequenceFrame *frames, size_t capacity, char *error, size_t error_size);
SirilImage *siril_sequence_frame(const char *directory, const char *name, int index, char *error, size_t error_size);
/* Original sequence flags and writer, with consistent selnum/reference. Caller
 * owns transactional backup/undo; this never deletes or changes FITS pixels. */
int siril_sequence_select(const char *directory, const char *name, const uint8_t *included,
    size_t count, int reference, char *error, size_t error_size);
typedef struct {
    double x, y, median[3]; /* displayed coordinates, origin at top left */
    uint32_t size;
} SirilBackgroundSample;
typedef struct {
    int method, interpolation, degree, correction; /* samples/auto, RBF/poly, 1..4, subtract/divide */
    double smoothing;
    int dither;
    double scale, smoothness, protect_threshold, protect_amount;
    int protect, simplified, auto_degree, downsample;
} SirilBackgroundOptions;
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
typedef struct {
    int32_t x, y, width, height; /* displayed top-left coordinates; NULL = full image */
} SirilRegion;
typedef struct {
    uint64_t total, good;
    double mean, median, sigma, average_deviation, mad, sqrt_bwmv, minimum, maximum, norm;
} SirilChannelStatistics;
/* Original STATS_MAIN and CFA channel extraction, without changing image pixels.
 * Returns 1/3 channels, or zero on failure. CFA falls back to mono for <2px regions. */
int siril_image_statistics(SirilImage *image, const SirilRegion *region, int per_cfa,
    SirilChannelStatistics results[3]);
/* Aggregates original computeHisto[_Selection] bins for display, without a new algorithm.
 * buckets must divide 65536. Zero/out-of-range behavior follows the original functions. */
int siril_image_histogram(SirilImage *image, const SirilRegion *region, int channel,
    double *counts, size_t buckets);
int siril_image_pixel(SirilImage *image, int32_t x, int32_t y, float values[3]);
/* Required UTF-8 buffer size including NUL; a short buffer is never partially filled. */
size_t siril_image_copy_header(SirilImage *image, char *buffer, size_t capacity);
const char *siril_core_version(void);
/* All operations are serialized because upstream Siril uses global state. */
SirilImage *siril_image_read(const char *path, char *error, size_t error_size);
void siril_image_free(SirilImage *image);
int siril_image_info(const SirilImage *image, SirilImageInfo *info);
/* Display-only RGBA using upstream Siril's linked automatic MTF stretch. */
int siril_image_preview(SirilImage *image, uint32_t max_dimension, SirilPreview *preview);
int siril_image_preview_display(SirilImage *image, uint32_t max_dimension, int channel, int automatic, SirilPreview *preview);
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
/* Close original command workspace and sequence caches, without changing owned
 * image/background sessions or deleting saved FITS files. Waits for any worker. */
void siril_release_workspace(void);
/* Runtime catalog from the configured upstream command table: name<TAB>usage. */
const char *siril_command_catalog(void);
/* Interactive background extraction uses the same upstream GUI image hook.
 * A session owns an unchanged original, its samples, and a computed result.
 * Invalidating/editing samples discards the preview; no import is overwritten. */
SirilBackground *siril_background_open(const char *path, char *error, size_t capacity);
void siril_background_free(SirilBackground *session);
int siril_background_generate(SirilBackground *session, int per_line, double tolerance,
    int randomize, int gradient_descent, double border, int border_percent, char *error, size_t capacity);
size_t siril_background_samples(SirilBackground *session, SirilBackgroundSample *samples, size_t capacity);
int siril_background_add(SirilBackground *session, double x, double y, int gradient_descent);
int siril_background_remove(SirilBackground *session, size_t index);
void siril_background_clear(SirilBackground *session);
int siril_background_compute(SirilBackground *session, const SirilBackgroundOptions *options, char *error, size_t capacity);
/* view: 0 original, 1 corrected, 2 background model; channel: -1 RGB or 0..2. */
int siril_background_preview(SirilBackground *session, int view, int channel, int automatic, SirilPreview *preview);
int siril_background_write(SirilBackground *session, const char *path);
#ifdef __cplusplus
}
#endif
#endif
