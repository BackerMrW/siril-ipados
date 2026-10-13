// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SIRIL_IPADOS_CORE_H
#define SIRIL_IPADOS_CORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SirilImage SirilImage;
typedef struct SirilSER SirilSER;
/* Original SER reader. Open a private writable copy: upstream repairs files
 * whose interrupted capture left an empty frame-count field. CFA is retained. */
SirilSER *siril_ser_open(const char *path, char *error, size_t capacity);
uint32_t siril_ser_count(const SirilSER *session);
SirilImage *siril_ser_read(SirilSER *session, uint32_t index, char *error, size_t capacity);
void siril_ser_close(SirilSER *session);
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
/* Run upstream check_seq to index converted frames; existing .seq files are
 * preserved by upstream buildseqfile(force_recompute=0). */
int siril_sequence_discover(const char *directory, char *error, size_t error_size);
int siril_sequence_inspect(const char *directory, const char *name, int layer,
    SirilSequenceInfo *info, SirilSequenceFrame *frames, size_t capacity, char *error, size_t error_size);
SirilImage *siril_sequence_frame(const char *directory, const char *name, int index, char *error, size_t error_size);
/* Exact regular-sequence filenames from upstream helpers, plus existing star,
 * mask and Drizzle caches. Newline-separated relative paths; returns required
 * bytes including NUL, or -1. NULL output queries capacity. Never deletes. */
int siril_sequence_files(const char *directory, const char *name, char *output,
    size_t capacity, char *error, size_t error_size);
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
    int per_line, randomize, gradient_descent, border_percent;
    double tolerance, border;
} SirilBackgroundSampling;
/* Uses the original GUI sequence worker (including sample-based division,
 * which seqsubsky does not expose). Prefix must be new and alphanumeric.
 * Caller verifies output count: upstream permits partial frame failures. */
int siril_sequence_background(const char *directory, const char *name, const char *prefix,
    const SirilBackgroundOptions *options, const SirilBackgroundSampling *sampling,
    char *error, size_t capacity);
SirilBackground *siril_background_open_sequence(const char *directory, const char *name,
    int index, char *error, size_t capacity);
/* Preview uses the exact sequence image hook: per-frame sampling and CFA split. */
int siril_background_compute_sequence(SirilBackground *session, const SirilBackgroundOptions *options,
    const SirilBackgroundSampling *sampling, char *error, size_t capacity);
typedef struct {
    uint32_t width, height, channels;
    int32_t top_down; /* physical FITS row order, used to map displayed crop coordinates */
    int32_t working_bitpix, gain, offset; /* loaded representation; imports are normalized float */
    double exposure, temperature;
    char object[80], bayer[80];
    double focal_length, aperture, pixel_size_x, pixel_size_y;
} SirilImageInfo;
typedef struct {
    uint32_t width, height;
    uint8_t *rgba;
} SirilPreview;
typedef struct {
    int mode; /* Original order: linear, log, sqrt, squared, asinh, STF, histogram equalization. */
    double low, high; /* Normalized display bounds, used by modes 0..4. */
    int unlinked, inverted;
} SirilDisplayOptions;
typedef struct {
    int32_t x, y, width, height; /* displayed top-left coordinates; NULL = full image */
} SirilRegion;
typedef struct {
    uint64_t total, good;
    double mean, median, sigma, average_deviation, mad, sqrt_bwmv, minimum, maximum, norm;
} SirilChannelStatistics;
/* Dynamic PSF / single-image aperture photometry. Coordinates are displayed
 * pixel centres (index + .5), FWHM remains pixels, angular values are separate.
 * profile: original Gaussian=0 / Moffat beta-free=1; beta-fixed is upstream TODO.
 * finder bounds/defaults follow stars_list_window.ui and settings.c. */
typedef struct {
    int32_t channel, profile, convergence, radius, relax, maximum;
    double sigma, minimum_roundness, maximum_roundness, minimum_beta;
    double minimum_amplitude, maximum_amplitude, focal_length, pixel_size;
} SirilStarFinder;
typedef struct {
    int32_t enabled, force_radius;
    double gain, inner, outer, aperture, aperture_factor, minimum, maximum;
} SirilPhotometry;
typedef struct {
    int32_t channel, profile, saturated, photometry_valid, photometry_error;
    double x, y, background, amplitude, fwhm_x, fwhm_y, angular_x, angular_y;
    double angle, beta, rmse, magnitude, magnitude_error, snr, ra, dec;
} SirilStarMeasurement;
const char *siril_psf_error_message(int code);
int siril_image_fit_star(SirilImage *image, const SirilRegion *region,
    const SirilStarFinder *finder, const SirilPhotometry *photometry,
    SirilStarMeasurement *result, char *error, size_t capacity);
/* Returns detected count (including legitimate empty result), or -1. Results
 * are independently owned values. CFA detection uses original green interpolation. */
int siril_image_find_stars(SirilImage *image, const SirilRegion *region,
    const SirilStarFinder *finder, SirilStarMeasurement *results,
    size_t capacity, char *error, size_t error_size);
/* Original save_list / save_list_as_FITS_table, no overwrite. */
int siril_image_save_stars(SirilImage *image, const char *path, int fits_table,
    const SirilStarFinder *finder, const SirilStarMeasurement *results,
    size_t count, char *error, size_t capacity);
/* Original sequence PSF worker and original differential light-curve generator.
 * Output is star-major, frame-minor; zero FWHM denotes no fit/excluded frame.
 * framing = original 0 / follow-star 1 / registered 2. Up to 20 stars. The first
 * is the variable, subsequent stars are references. curve_path may be NULL. */
int siril_sequence_photometry(const char *directory, const char *name, int current,
    int framing, const SirilRegion *regions, size_t stars, const SirilStarFinder *finder,
    const SirilPhotometry *photometry, const char *curve_path,
    SirilStarMeasurement *results, size_t count, char *error, size_t capacity);
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
/* Returns an independent edited image. action: 0 set, 1 delete, 2 rename,
 * 3 add comment; string_value quotes/escapes a FITS string for action 0. */
SirilImage *siril_image_edit_keyword(SirilImage *image, int action, const char *key,
    const char *value, const char *comment, int string_value, char *error, size_t error_size);
const char *siril_core_version(void);
/* All operations are serialized because upstream Siril uses global state. */
SirilImage *siril_image_read(const char *path, char *error, size_t error_size);
/* Original stat_file/any_to_fits readers; rejects sequence containers and
 * suppresses implicit CFA debayer. Current build enables PNG/JPEG/TIFF. */
SirilImage *siril_image_read_any(const char *path, char *error, size_t error_size);
void siril_image_free(SirilImage *image);
int siril_image_info(const SirilImage *image, SirilImageInfo *info);
/* Display-only RGBA using upstream Siril's linked automatic MTF stretch. */
int siril_image_preview(SirilImage *image, uint32_t max_dimension, SirilPreview *preview);
int siril_image_preview_display(SirilImage *image, uint32_t max_dimension, int channel, int automatic, SirilPreview *preview);
int siril_image_preview_mode(SirilImage *image, uint32_t max_dimension, int channel, const SirilDisplayOptions *options, SirilPreview *preview);
void siril_preview_free(SirilPreview *preview);
/* These call upstream Siril imoper/soper, not replacement arithmetic. */
int siril_image_add(SirilImage *destination, const SirilImage *source);
int siril_image_subtract(SirilImage *destination, const SirilImage *source);
int siril_image_divide_scalar(SirilImage *image, float divisor);
/* Export a new floating-point FITS; refuses to overwrite an existing path. */
int siril_image_write(const SirilImage *image, const char *path);
/* Original writers: 1 PNG, 2 JPEG, 3 TIFF, 4 JPEG XL. Exact suffix and no overwrite;
 * PNG accepts 8/16-bit, TIFF 8/16/32-bit; JPEG quality is 1..100. */
int siril_image_export(SirilImage *image, const char *path, int format, int depth, int quality);
/* Original JPEG XL settings: effort 1..9, quality 0..100 (100 = lossless),
 * depth 8 or normalized 32-bit float. Refuses overwrites and invalid settings. */
int siril_image_export_jxl(SirilImage *image, const char *path, int depth, int effort, double quality);
/* Profile: -1 upstream defaults, 0 sRGB, 1 working space, 2 image ICC. */
int siril_image_export_profile(SirilImage *image, const char *path, int format, int depth, int quality, int profile);
int siril_image_export_jxl_profile(SirilImage *image, const char *path, int depth, int effort, double quality, int profile);
/* Execute original Siril commands synchronously, stopping at the first error.
 * Blank lines and # comments are accepted. No desktop process or GTK loop.
 * Returns 1 on success; errors identify the source line. */
int siril_run_commands(const char *directory, const char *script, char *error, size_t error_size);
/* Execute a native tool script and atomically capture an owned float result
 * plus mask, then close the command workspace. Script must load its input and
 * leave its result open. Returns NULL on failure/cancellation. */
SirilImage *siril_tool_compute(const char *directory, const char *script, char *error, size_t error_size);
/* Independent float image using the original mask_to_fits conversion. */
SirilImage *siril_image_mask_copy(SirilImage *image);
/* Independent of the engine lock, so UI can read logs and cancel a running job. */
void siril_copy_processing_log(char *buffer, size_t capacity);
void siril_cancel_processing(void);
/* Close original command workspace and sequence caches, without changing owned
 * image/background sessions or deleting saved FITS files. Waits for any worker. */
void siril_release_workspace(void);
/* Runtime catalog from the configured upstream command table: name<TAB>usage. */
const char *siril_command_catalog(void);
/* JSON settings call the original curve and PixelMath kernels on an owned
 * scratch image. The imported original remains separate and unchanged.
 * range_preview renders the curve's original luminance mask, never an output
 * intended for saving. clipped receives low/high curve counts. */
int siril_image_advanced(SirilImage *image, const char *settings, int range_preview,
    int64_t *clipped, char *error, size_t capacity);
int siril_curve_plot(const char *stage, int channel, float *samples, size_t count);
float siril_curve_tone(int channel, float red, float green, float blue);
int siril_image_curve_histograms(SirilImage *image, uint64_t *counts, size_t bins);
/* Interactive background extraction uses the same upstream GUI image hook.
 * A session owns an unchanged original, its samples, and a computed result.
 * Invalidating/editing samples discards the preview; no import is overwritten. */
SirilBackground *siril_background_open(const char *path, char *error, size_t capacity);
void siril_background_free(SirilBackground *session);
int siril_background_generate(SirilBackground *session, int per_line, double tolerance,
    int randomize, int gradient_descent, double border, int border_percent, char *error, size_t capacity);
size_t siril_background_samples(SirilBackground *session, SirilBackgroundSample *samples, size_t capacity);
int siril_background_add(SirilBackground *session, double x, double y, int gradient_descent);
/* Coordinates are display coordinates. Move keeps sample ordering; restore
 * rereads original medians in one batch. Failure preserves samples and model. */
int siril_background_move(SirilBackground *session, size_t index, double x, double y);
int siril_background_restore(SirilBackground *session, const SirilBackgroundSample *samples, size_t count);
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
