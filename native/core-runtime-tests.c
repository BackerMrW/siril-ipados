// SPDX-License-Identifier: GPL-3.0-or-later
/* Executes against the real upstream engine on an Apple iPad simulator. */
#include "SirilCore.h"
#include "core/siril.h"
#include "core/proto.h"
#include "io/sequence.h"
#include "io/single_image.h"
#include "algos/statistics.h"
#include "io/image_format_fits.h"
#include <fitsio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; } } while (0)
static int fixture(const char *path, const void *pixels, int image_type, int pixel_type) {
    fitsfile *file = NULL;
    int status = 0;
    long axes[] = {2, 2};
    double exposure = 120;
    fits_create_file(&file, path, &status);
    if (status) return status;
    fits_create_img(file, image_type, 2, axes, &status);
    fits_update_key(file, TDOUBLE, "EXPTIME", &exposure, NULL, &status);
    fits_write_img(file, pixel_type, 1, 4, (void *)pixels, &status);
    fits_close_file(file, &status);
    return status;
}
static int read_pixels(const char *path, float *pixels, long count) {
    fitsfile *file = NULL;
    int status = 0, any_null = 0;
    fits_open_file(&file, path, READONLY, &status);
    if (status) return status;
    fits_read_img(file, TFLOAT, 1, count, NULL, pixels, &any_null, &status);
    fits_close_file(file, &status);
    return status;
}
static int star_fixture(const char *path, double dx, double dy) {
    const int side = 256;
    float *pixels = calloc(side * side, sizeof(float));
    if (!pixels) return 1;
    unsigned state = 987321;
    double sx[30], sy[30], amplitude[30];
    for (int i = 0; i < 30; i++) {
        state = state * 1664525u + 1013904223u;
        sx[i] = 25 + (i % 6) * 40 + (state % 13);
        state = state * 1664525u + 1013904223u;
        sy[i] = 25 + (i / 6) * 44 + (state % 13);
        amplitude[i] = 0.15 + (i % 7) * 0.025;
    }
    sx[0] = 30; sy[0] = 31; amplitude[0] = 0.7;
    for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) {
        double value = 0.02 + 0.0001 * sin(x * 1.3 + y * 0.7);
        for (int i = 0; i < 30; i++) {
            double xx = x - sx[i] - dx, yy = y - sy[i] - dy;
            value += amplitude[i] * exp(-(xx * xx + yy * yy) / (2 * 1.8 * 1.8));
        }
        pixels[y * side + x] = value;
    }
    fitsfile *file = NULL;
    int status = 0;
    long axes[] = {side, side};
    double exposure = 120;
    fits_create_file(&file, path, &status);
    fits_create_img(file, FLOAT_IMG, 2, axes, &status);
    fits_update_key(file, TDOUBLE, "EXPTIME", &exposure, NULL, &status);
    fits_write_img(file, TFLOAT, 1, side * side, pixels, &status);
    fits_close_file(file, &status);
    free(pixels);
    return status;
}
static int drizzle_fixture(const char *path, double dx, double dy, int bayer) {
    if (star_fixture(path, dx, dy)) return 1;
    float pixels[256 * 256];
    if (read_pixels(path, pixels, 256 * 256)) return 1;
    for (int y = 0; y < 256; y++) for (int x = 0; x < 256; x++) {
        float color = !bayer ? 1.f : (!(y % 2) && !(x % 2)) ? 1.f : (y % 2 && x % 2) ? 0.25f : 0.5f;
        pixels[y * 256 + x] *= 0.2f * color;
    }
    fitsfile *file = NULL;
    int status = 0;
    fits_open_file(&file, path, READWRITE, &status);
    if (bayer) fits_update_key(file, TSTRING, "BAYERPAT", "RGGB", NULL, &status);
    fits_update_key(file, TSTRING, "ROWORDER", "TOP-DOWN", NULL, &status);
    fits_write_img(file, TFLOAT, 1, 256 * 256, pixels, &status);
    fits_close_file(file, &status);
    return status;
}
static int drizzle_checks(const char *root) {
    char source[4096], process[4096], path[4096], script[4096], error[512];
    const double dx[] = {0, 0.7, 1.5, -0.4}, dy[] = {0, 1.1, -0.6, 1.6};
    const char *kernels[] = {"point", "turbo", "square", "gaussian", "lanczos2", "lanczos3"};
    for (int bayer = 0; bayer < 2; bayer++) {
        snprintf(source, sizeof source, "%s/drizzle%d", root, bayer);
        snprintf(process, sizeof process, "%s/drizzleprocess%d", root, bayer);
        CHECK(mkdir(source, 0700) == 0 && mkdir(process, 0700) == 0);
        for (int i = 0; i < 4; i++) {
            snprintf(path, sizeof path, "%s/frame%d.fits", source, i);
            CHECK(drizzle_fixture(path, dx[i], dy[i], bayer) == 0);
        }
        CHECK(siril_run_commands(source, bayer ? "convert drizzle -out=../drizzleprocess1\n" : "convert drizzle -out=../drizzleprocess0\n", error, sizeof error));
        CHECK(siril_run_commands(process, "setref drizzle 1\nregister drizzle -2pass -transf=shift -minpairs=4 -maxstars=100 -layer=0\n", error, sizeof error));
        CHECK(siril_run_commands(process, "set gui_registration.drizz_weight_match_bitpix=false\n", error, sizeof error));
        for (int k = 0; k < (bayer ? 1 : 8); k++) {
            const int side = 512, channels = bayer ? 3 : 1;
            const size_t count = (size_t)side * side * channels;
            // Bayer uses Square; the six mono cases cover all native kernels.
            if (k == 7) CHECK(siril_run_commands(process, "set gui_registration.drizz_weight_match_bitpix=true\n", error, sizeof error));
            snprintf(script, sizeof script,
                "seqapplyreg drizzle -drizzle -scale=2 -pixfrac=%s -kernel=%s -framing=current -prefix=d%d_\n"
                "stack d%d_drizzle mean none 3 3 -nonorm -32b -out=drizzle%d.fits\n", k == 6 ? "0.5" : "1", bayer || k >= 6 ? "square" : kernels[k], k, k, k);
            CHECK(siril_run_commands(process, script, error, sizeof error));
            snprintf(path, sizeof path, "%s/drizzle%d.fits", process, k);
            SirilImage *image = siril_image_read(path, error, sizeof error);
            SirilImageInfo info;
            CHECK(image && siril_image_info(image, &info) && info.width == side && info.height == side && info.channels == channels);
            siril_image_free(image);
            float *result = malloc(count * sizeof(float)), *input = malloc(count * sizeof(float)), *weight = malloc(count * sizeof(float));
            double *numerator = calloc(count, sizeof(double)), *denominator = calloc(count, sizeof(double));
            CHECK(result && input && weight && numerator && denominator && read_pixels(path, result, count) == 0);
            for (int frame = 1; frame <= 4; frame++) {
                snprintf(path, sizeof path, "%s/d%d_drizzle_%05d.fit", process, k, frame);
                CHECK(read_pixels(path, input, count) == 0);
                snprintf(path, sizeof path, "%s/drizztmp/d%d_drizzle_%05d.fit", process, k, frame);
                CHECK(read_pixels(path, weight, count) == 0);
                for (size_t p = 0; p < count; p++) if (input[p] != 0 && weight[p] != 0) {
                    numerator[p] += input[p] * (double)weight[p];
                    denominator[p] += weight[p];
                }
            }
            int checked = 0;
            float peak = 0;
            for (size_t p = 0; p < count; p++) {
                CHECK(isfinite(result[p]));
                if (result[p] > peak) peak = result[p];
                if (denominator[p] > 0) {
                    CHECK(fabs(result[p] - numerator[p] / denominator[p]) < 2e-5);
                    checked++;
                }
            }
            CHECK(checked > side * side / 2 && peak > 0.25f);
            if (k == 0) {
                CHECK(siril_run_commands(process, "stack d0_drizzle sum -32b -out=drizzlesum.fits\n", error, sizeof error));
                snprintf(path, sizeof path, "%s/drizzlesum.fits", process);
                CHECK(read_pixels(path, input, count) == 0);
                for (size_t p = 0; p < count; p++) if (denominator[p] > 0) CHECK(fabs(input[p] - numerator[p] / denominator[p]) < 2e-5);
            }
            if (k == 6) {
                snprintf(path, sizeof path, "%s/drizztmp/d2_drizzle_00001.fit", process);
                CHECK(read_pixels(path, input, count) == 0);
                snprintf(path, sizeof path, "%s/drizztmp/d6_drizzle_00001.fit", process);
                CHECK(read_pixels(path, weight, count) == 0);
                int changed = 0;
                for (size_t p = 0; p < count; p++) if (input[p] != weight[p]) changed++;
                CHECK(changed > side * side / 4);
            }
            if (bayer) {
                double total[3] = {0}; int used[3] = {0};
                for (int c = 0; c < 3; c++) for (int y = 24; y < 40; y++) for (int x = 24; x < 40; x++) {
                    float value = result[c * side * side + y * side + x];
                    if (value > 0) { total[c] += value; used[c]++; }
                }
                for (int c = 0; c < 3; c++) CHECK(used[c] > 64 && fabs(total[c] / used[c] - 0.016 * (c == 0 ? 1 : c == 1 ? 0.5 : 0.25)) < 0.0001);
            }
            free(result); free(input); free(weight); free(numerator); free(denominator);
        }
    }
    puts("PASS: real subpixel-dither Drizzle with six kernels and two-pass application; pixel-fraction changes alter weight maps; 2x dimensions, finite pixels, preserved star and independent mean/sum per-pixel weight arithmetic; Bayer RGB background levels preserved");
    return 0;
}
static int gradient_fixture(const char *path) {
    float pixels[256 * 256];
    unsigned state = 321;
    for (int y = 0; y < 256; y++) for (int x = 0; x < 256; x++) {
        state = state * 1664525u + 1013904223u;
        double noise = ((state >> 8) / 16777215.0 - 0.5) * 0.006;
        double xx = x - 128, yy = y - 128;
        pixels[y * 256 + x] = 0.1 + 0.15 * x / 255 + 0.08 * y / 255 + noise +
            0.5 * exp(-(xx * xx + yy * yy) / 18);
    }
    fitsfile *file = NULL;
    int status = 0;
    long axes[] = {256, 256};
    fits_create_file(&file, path, &status);
    fits_create_img(file, FLOAT_IMG, 2, axes, &status);
    fits_write_img(file, TFLOAT, 1, 256 * 256, pixels, &status);
    fits_close_file(file, &status);
    return status;
}
// RGGB sensor data with distinct color levels: verifies pattern and row handling.
static int cfa_fixture(const char *path) {
    const int side = 64;
    unsigned short pixels[64 * 64];
    for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) {
        double base = (y % 2 == 0 && x % 2 == 0) ? 0.6 : ((y % 2 && x % 2) ? 0.1 : 0.3);
        pixels[y * side + x] = (unsigned short)((base + 0.02 * x / side) * 65535);
    }
    fitsfile *file = NULL;
    int status = 0;
    long axes[] = {side, side};
    fits_create_file(&file, path, &status);
    fits_create_img(file, USHORT_IMG, 2, axes, &status);
    fits_update_key(file, TSTRING, "BAYERPAT", "RGGB", NULL, &status);
    fits_update_key(file, TSTRING, "ROWORDER", "TOP-DOWN", NULL, &status);
    fits_write_img(file, TUSHORT, 1, side * side, pixels, &status);
    fits_close_file(file, &status);
    return status;
}
static int analysis_reference(const char *path, const SirilRegion *region, int cfa) {
    char error[512];
    SirilImage *image = siril_image_read(path, error, sizeof error);
    CHECK(image);
    fits original = {0};
    CHECK(readfits(path, &original, NULL, TRUE) == 0);
    rectangle area = {0};
    if (region) {
        area.x = region->x; area.w = region->width; area.h = region->height;
        area.y = original.top_down ? original.ry - region->y - region->height : region->y;
    }
    SirilChannelStatistics values[3];
    int channels = siril_image_statistics(image, region, cfa, values);
    int use_cfa = cfa && original.naxes[2] == 1 && original.keywords.bayer_pattern[0] &&
        (!region || (region->width >= 2 && region->height >= 2));
    CHECK(channels == (use_cfa ? 3 : original.naxes[2]));
    for (int c = 0; c < channels; c++) {
        imstats *reference = statistics(NULL, -1, &original, use_cfa ? -c - 1 : c, &area, STATS_MAIN, MULTI_THREADED);
        CHECK(reference && values[c].total == reference->total && values[c].good == reference->ngoodpix);
        double actual[] = {values[c].mean, values[c].median, values[c].sigma, values[c].average_deviation,
            values[c].mad, values[c].sqrt_bwmv, values[c].minimum, values[c].maximum, values[c].norm};
        double expected[] = {reference->mean, reference->median, reference->sigma, reference->avgDev,
            reference->mad, reference->sqrtbwmv, reference->min, reference->max, reference->normValue};
        for (int i = 0; i < 9; i++) CHECK((isnan(actual[i]) && isnan(expected[i])) || fabs(actual[i] - expected[i]) < 1e-10);
        free_stats(reference);
    }
    for (int c = 0; c < original.naxes[2]; c++) {
        double bins[512];
        CHECK(siril_image_histogram(image, region, c, bins, 512));
        gsl_histogram *reference = region ? computeHisto_Selection(&original, c, &area) : computeHisto(&original, c);
        CHECK(reference);
        double expected[512] = {0};
        for (size_t i = 0; i < reference->n; i++) expected[i * 512 / reference->n] += gsl_histogram_get(reference, i);
        for (int i = 0; i < 512; i++) CHECK(bins[i] == expected[i]);
        gsl_histogram_free(reference);
    }
    for (int y = 0; y < original.ry; y += original.ry > 2 ? original.ry / 2 : 1) {
        float pixel[3];
        int x = y % original.rx;
        CHECK(siril_image_pixel(image, x, y, pixel) == original.naxes[2]);
        int row = original.top_down ? y : original.ry - 1 - y;
        for (int c = 0; c < original.naxes[2]; c++) CHECK(pixel[c] == original.fpdata[c][row * original.rx + x]);
    }
    CHECK(!siril_image_pixel(image, -1, 0, (float[3]){0}));
    CHECK(!siril_image_pixel(image, original.rx, 0, (float[3]){0}));
    SirilRegion bad = {original.rx - 1, 0, 2, 1};
    CHECK(!siril_image_statistics(image, &bad, 0, values));
    CHECK(!siril_image_histogram(image, &bad, 0, (double[512]){0}, 512));
    CHECK(!siril_image_histogram(image, NULL, original.naxes[2], (double[512]){0}, 512));
    CHECK(!siril_image_histogram(image, NULL, 0, (double[512]){0}, 511));
    size_t size = siril_image_copy_header(image, NULL, 0);
    CHECK(size > 1);
    char *header = malloc(size);
    CHECK(header && siril_image_copy_header(image, header, size) == size);
    CHECK(strstr(header, "BITPIX") && strlen(header) + 1 == size && strcmp(header, original.header) == 0);
    char short_buffer[] = "unchanged";
    CHECK(siril_image_copy_header(image, short_buffer, sizeof short_buffer) == size && !strcmp(short_buffer, "unchanged"));
    free(header);
    clearfits(&original);
    siril_image_free(image);
    return 0;
}
static int sequence_checks(const char *registered, const char *combinations) {
    char error[512], path[4096];
    SirilSequenceInfo info;
    SirilSequenceFrame frames[3];
    CHECK(siril_sequence_inspect(registered, "stars_.seq", 0, &info, frames, 3, error, sizeof error) == 3);
    CHECK(info.count == 3 && info.included == 3 && info.reference == 0 && info.width == 256 && info.height == 256 && info.layers == 1);
    // Independent original read confirms ABI forwards measured values unchanged.
    sequence *original = readseqfile("stars_.seq");
    CHECK(original && seq_check_basic_data(original, FALSE) >= 0 && original->regparam[0]);
    for (int i = 0; i < 3; i++) {
        regdata *reg = &original->regparam[0][i];
        CHECK(frames[i].index == i && frames[i].file_number == original->imgparam[i].filenum && frames[i].has_registration);
        CHECK(frames[i].fwhm > 0 && frames[i].stars > 0 && frames[i].fwhm == reg->fwhm && frames[i].weighted_fwhm == reg->weighted_fwhm);
        CHECK(frames[i].roundness == reg->roundness && frames[i].background == reg->background_lvl && frames[i].stars == reg->number_of_stars);
        CHECK(frames[i].translation_x == reg->H.h02 && frames[i].translation_y == reg->H.h12);
    }
    free_sequence(original, TRUE);
    SirilImage *image = siril_sequence_frame(registered, "stars_.seq", 1, error, sizeof error);
    SirilImageInfo metadata;
    CHECK(image && siril_image_info(image, &metadata) && metadata.width == 256 && metadata.channels == 1);
    float values[3], direct[256 * 256];
    snprintf(path, sizeof path, "%s/stars_00002.fit", registered);
    CHECK(read_pixels(path, direct, 256 * 256) == 0);
    // Displayed pixel y=0 is the last stored row for this bottom-up FITS.
    CHECK(siril_image_pixel(image, 40, 40, values) == 1);
    CHECK(fabs(values[0] - direct[(255 - 40) * 256 + 40]) < 1e-7);
    siril_release_workspace();
    CHECK(siril_image_pixel(image, 40, 40, values) == 1);
    siril_image_free(image);
    CHECK(!siril_sequence_frame(registered, "stars_.seq", -1, error, sizeof error));
    CHECK(siril_sequence_inspect(registered, "stars_.seq", 2, &info, frames, 3, error, sizeof error) == -1);
    CHECK(siril_sequence_inspect(registered, "stars_.seq", 0, &info, frames, 2, error, sizeof error) == -1);
    CHECK(siril_sequence_inspect(registered, "../stars_.seq", 0, &info, NULL, 0, error, sizeof error) == -1);
    uint8_t flags[] = {1, 1, 0};
    CHECK(!siril_sequence_select(combinations, "combination_.seq", flags, 3, 2, error, sizeof error));
    CHECK(siril_sequence_select(combinations, "combination_.seq", flags, 3, 0, error, sizeof error));
    CHECK(siril_sequence_inspect(combinations, "combination_.seq", 0, &info, frames, 3, error, sizeof error) == 3);
    CHECK(info.included == 2 && info.reference == 0 && !frames[2].included);
    CHECK(siril_run_commands(combinations, "stack combination mean none 3 3 -nonorm -filter-included -32b -out=subset.fits\nseqstat combination sequence-statistics.csv main\n", error, sizeof error));
    float pixels[4];
    snprintf(path, sizeof path, "%s/subset.fits", combinations);
    CHECK(read_pixels(path, pixels, 4) == 0);
    for (int i = 0; i < 4; i++) CHECK(fabs(pixels[i] - (0.15 + i * 0.01)) < 2e-5);
    CHECK(siril_sequence_inspect(combinations, "combination_.seq", 0, &info, frames, 3, error, sizeof error) == 3);
    for (int i = 0; i < 2; i++) CHECK(frames[i].has_statistics && fabs(frames[i].mean - (0.115 + i * 0.1)) < 2e-5);
    snprintf(path, sizeof path, "%s/combination_00003.fit", combinations);
    CHECK(read_pixels(path, pixels, 4) == 0);
    for (int i = 0; i < 4; i++) CHECK(fabs(pixels[i] - (0.9 + i * 0.01)) < 2e-5);
    flags[2] = 1;
    CHECK(siril_sequence_select(combinations, "combination_.seq", flags, 3, -1, error, sizeof error));
    CHECK(siril_run_commands(combinations, "stack combination mean none 3 3 -nonorm -filter-included -32b -out=restored.fits\n", error, sizeof error));
    snprintf(path, sizeof path, "%s/restored.fits", combinations);
    CHECK(read_pixels(path, pixels, 4) == 0);
    for (int i = 0; i < 4; i++) CHECK(fabs(pixels[i] - (0.4 + i * 0.01)) < 2e-5);
    puts("PASS: original sequence frame reads and measured registration values, invalid paths/layers/indices, preserved independent image handles; exclusion changed exact stacked pixels without altering source frames, reference validation and restored inclusion; original normalized sequence statistics");
    return 0;
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    char light[4096], dark[4096], output[4096], missing[4096];
    snprintf(light, sizeof light, "%s/light.fits", argv[1]);
    snprintf(dark, sizeof dark, "%s/dark.fits", argv[1]);
    snprintf(output, sizeof output, "%s/result.fits", argv[1]);
    snprintf(missing, sizeof missing, "%s/missing.fits", argv[1]);
    const float a[] = {0.2f, 0.3f, 0.4f, 0.5f}, b[] = {0.1f, 0.1f, 0.1f, 0.1f};
    CHECK(fixture(light, a, FLOAT_IMG, TFLOAT) == 0 && fixture(dark, b, FLOAT_IMG, TFLOAT) == 0);
    char error[512];
    CHECK(siril_image_read(missing, error, sizeof error) == NULL && error[0]);
    SirilImage *image = siril_image_read(light, error, sizeof error);
    SirilImage *calibration = siril_image_read(dark, error, sizeof error);
    CHECK(image && calibration);
    SirilImageInfo info;
    CHECK(siril_image_info(image, &info));
    CHECK(info.width == 2 && info.height == 2 && info.channels == 1);
    CHECK(info.working_bitpix == FLOAT_IMG && fabs(info.exposure - 120) < 1e-8);
    CHECK(analysis_reference(light, NULL, 0) == 0);
    SirilRegion upper_row = {0, 0, 2, 1};
    CHECK(analysis_reference(light, &upper_row, 0) == 0);
    SirilChannelStatistics simple_stats[3];
    CHECK(siril_image_statistics(image, NULL, 0, simple_stats) == 1);
    /* Original findMinMaxPercentile uses four histogram bins for four samples;
     * its interpolated median is 0.4 here, not the exact order-statistic 0.35.
     * Preserve this desktop behavior. All eight fields are also compared with
     * independent upstream calls above, to avoid replacing its approximation. */
    printf("Original tiny-image stats: mean=%.9g median=%.9g MAD=%.9g\n",
        simple_stats[0].mean, simple_stats[0].median, simple_stats[0].mad);
    CHECK(fabs(simple_stats[0].mean - 0.35) < 1e-7 && fabs(simple_stats[0].median - 0.4) < 1e-7);
    CHECK(fabs(simple_stats[0].mad - 0.1) < 1e-7 && fabs(simple_stats[0].average_deviation - 0.1) < 1e-7);
    CHECK(siril_image_statistics(image, &upper_row, 0, simple_stats) == 1 && fabs(simple_stats[0].mean - 0.45) < 1e-7);
    printf("PASS: original eight statistics, selected displayed row, pixel orientation, histogram bins and complete FITS header\n");
    CHECK(siril_image_subtract(image, calibration));
    CHECK(siril_image_add(image, calibration));
    CHECK(!siril_image_divide_scalar(image, 0));
    CHECK(siril_image_divide_scalar(image, 2));
    CHECK(siril_image_write(image, output));
    CHECK(!siril_image_write(image, output));
    fitsfile *file = NULL;
    int status = 0, any_null = 0;
    float actual[4];
    fits_open_file(&file, output, READONLY, &status);
    CHECK(status == 0);
    fits_read_img(file, TFLOAT, 1, 4, NULL, actual, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    for (int i = 0; i < 4; i++) CHECK(fabsf(actual[i] - a[i] / 2) < 1e-6f);
    SirilPreview preview;
    CHECK(siril_image_preview(image, 64, &preview));
    CHECK(preview.width == 2 && preview.height == 2 && preview.rgba);
    for (int i = 0; i < 4; i++) CHECK(preview.rgba[i * 4 + 3] == 255);
    CHECK(memcmp(preview.rgba, preview.rgba + 4, 3) != 0);
    siril_preview_free(&preview);
    siril_image_free(image);
    // Exercise real command parsing, threaded conversion, sequence calibration
    // and stacking, not only the direct image arithmetic wrapper.
    char frames[4096], process[4096], path[4096], script[8192];
    snprintf(frames, sizeof frames, "%s/frames", argv[1]);
    snprintf(process, sizeof process, "%s/process", argv[1]);
    CHECK(mkdir(frames, 0700) == 0 && mkdir(process, 0700) == 0);
    for (int i = 0; i < 3; i++) {
        snprintf(path, sizeof path, "%s/light%d.fits", frames, i);
        CHECK(fixture(path, a, FLOAT_IMG, TFLOAT) == 0);
    }
    snprintf(script, sizeof script,
        "# Native synchronous Siril batch\nset32bits\nconvert light -out=../process\n"
        "cd ../process\ncalibrate light -dark=%s -prefix=pp_\n"
        "stack pp_light median -nonorm -out=calibrated.fits\n", dark);
    CHECK(siril_run_commands(frames, script, error, sizeof error));
    snprintf(path, sizeof path, "%s/calibrated.fits", process);
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    CHECK(status == 0);
    fits_read_img(file, TFLOAT, 1, 4, NULL, actual, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    for (int i = 0; i < 4; i++) CHECK(fabsf(actual[i] - (a[i] - b[i])) < 1e-6f);
    // A nonuniform corrected master flat must preserve calibrated photometry.
    char flat[4096];
    const float flat_pixels[] = {0.4f, 0.5f, 0.6f, 0.7f};
    snprintf(flat, sizeof flat, "%s/master-flat.fits", argv[1]);
    CHECK(fixture(flat, flat_pixels, FLOAT_IMG, TFLOAT) == 0);
    snprintf(script, sizeof script,
        "calibrate light -dark=%s -flat=%s -prefix=pf_\n"
        "stack pf_light median -nonorm -out=flat-calibrated.fits\n", dark, flat);
    CHECK(siril_run_commands(process, script, error, sizeof error));
    snprintf(path, sizeof path, "%s/flat-calibrated.fits", process);
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    CHECK(status == 0);
    fits_read_img(file, TFLOAT, 1, 4, NULL, actual, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    for (int i = 0; i < 4; i++) CHECK(fabsf(actual[i] - (a[i] - b[i]) * 0.55f / flat_pixels[i]) < 1e-6f);
    CHECK(!siril_run_commands(frames, "not_a_siril_command\nconvert should_not_exist\n", error, sizeof error));
    CHECK(strstr(error, "Line 1") != NULL);
    CHECK(!siril_run_commands(frames, "'exit'\n", error, sizeof error));
    CHECK(!siril_run_commands(frames, "''\n", error, sizeof error));
    CHECK(!siril_run_commands(frames, "@detached.ssf\n", error, sizeof error));
    char logs[4096];
    siril_copy_processing_log(logs, sizeof logs);
    CHECK(logs[0]);
    puts("PASS: original Siril command engine converted three FITS, calibrated with a master dark, median-stacked exact expected pixels, stopped on errors, and rejected desktop exit/detached scripts");
    // Known photometric values distinguish all five stacking methods. The
    // upstream sum operation deliberately scales its largest pixel to one.
    char combinations[4096], combo_process[4096];
    snprintf(combinations, sizeof combinations, "%s/combinations", argv[1]);
    snprintf(combo_process, sizeof combo_process, "%s/combo-process", argv[1]);
    CHECK(mkdir(combinations, 0700) == 0 && mkdir(combo_process, 0700) == 0);
    const float offsets[] = {0.1f, 0.2f, 0.9f};
    for (int frame = 0; frame < 3; frame++) {
        float values[4];
        for (int p = 0; p < 4; p++) values[p] = offsets[frame] + p * 0.01f;
        snprintf(path, sizeof path, "%s/frame%d.fits", combinations, frame);
        CHECK(fixture(path, values, FLOAT_IMG, TFLOAT) == 0);
    }
    CHECK(siril_run_commands(combinations, "set32bits\nconvert combination -out=../combo-process\n", error, sizeof error));
    const char *methods[] = {"mean none 3 3 -nonorm", "median -nonorm", "min", "max", "sum"};
    const float bases[] = {0.4f, 0.2f, 0.1f, 0.9f};
    for (int method = 0; method < 5; method++) {
        snprintf(script, sizeof script, "stack combination %s -32b -out=method%d.fits\n", methods[method], method);
        CHECK(siril_run_commands(combo_process, script, error, sizeof error));
        snprintf(path, sizeof path, "%s/method%d.fits", combo_process, method);
        image = siril_image_read(path, error, sizeof error);
        CHECK(image && read_pixels(path, actual, 4) == 0);
        for (int p = 0; p < 4; p++) {
            // Direct buffers use the same raw row order as CFITSIO fixtures.
            float expected = method == 4 ? (1.2f + p * 0.03f) / 1.29f : bases[method] + p * 0.01f;
            CHECK(fabsf(actual[p] - expected) < 2e-5f);
        }
        siril_image_free(image);
    }
    // Distinct single-frame high outlier among eleven near-identical values:
    // all seven original rejection algorithms must reduce its contribution.
    char rejection_frames[4096], rejection_process[4096];
    snprintf(rejection_frames, sizeof rejection_frames, "%s/rejection-frames", argv[1]);
    snprintf(rejection_process, sizeof rejection_process, "%s/rejection-process", argv[1]);
    CHECK(mkdir(rejection_frames, 0700) == 0 && mkdir(rejection_process, 0700) == 0);
    for (int frame = 0; frame < 11; frame++) {
        float values[4];
        for (int p = 0; p < 4; p++) values[p] = (frame == 10 ? 0.9f : 0.1f + frame * 0.002f) + p * 0.01f;
        snprintf(path, sizeof path, "%s/frame%02d.fits", rejection_frames, frame);
        CHECK(fixture(path, values, FLOAT_IMG, TFLOAT) == 0);
    }
    CHECK(siril_run_commands(rejection_frames, "convert rejection -out=../rejection-process\n", error, sizeof error));
    const char *rejections[] = {"winsorized 3 3", "sigma 2 2", "mad 3 3", "median 3 3", "linear 3 3", "generalized 0.3 0.05", "percentile 0.2 0.1"};
    for (int algorithm = 0; algorithm < 7; algorithm++) {
        snprintf(script, sizeof script, "stack rejection mean %s -nonorm -rejmaps -32b -out=reject%d.fits\n", rejections[algorithm], algorithm);
        CHECK(siril_run_commands(rejection_process, script, error, sizeof error));
        snprintf(path, sizeof path, "%s/reject%d.fits", rejection_process, algorithm);
        image = siril_image_read(path, error, sizeof error);
        CHECK(image && read_pixels(path, actual, 4) == 0);
        for (int p = 0; p < 4; p++) CHECK(isfinite(actual[p]) && actual[p] >= 0.09f && actual[p] < 0.17f);
        siril_image_free(image);
    }
    puts("PASS: all five upstream stacking methods matched expected pixels; all seven rejection algorithms reduced a known outlier");
    // Global star registration must actually align translated star fields.
    char stars[4096], registered[4096];
    snprintf(stars, sizeof stars, "%s/stars", argv[1]);
    snprintf(registered, sizeof registered, "%s/registered", argv[1]);
    CHECK(mkdir(stars, 0700) == 0 && mkdir(registered, 0700) == 0);
    const int dx[] = {0, 8, -5}, dy[] = {0, -5, 7};
    for (int i = 0; i < 3; i++) {
        snprintf(path, sizeof path, "%s/frame%d.fits", stars, i);
        CHECK(star_fixture(path, dx[i], dy[i]) == 0);
    }
    CHECK(siril_run_commands(stars,
        "convert stars -out=../registered\ncd ../registered\nsetref stars 1\n"
        "register stars\nstack r_stars rej w 3 3 -norm=addscale -output_norm -out=aligned.fits\n", error, sizeof error));
    snprintf(path, sizeof path, "%s/aligned.fits", registered);
    float aligned[256 * 256];
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    CHECK(status == 0);
    fits_read_img(file, TFLOAT, 1, 256 * 256, NULL, aligned, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    // Without registration the median suppresses this displaced bright star.
    CHECK(aligned[31 * 256 + 30] > 0.6f);
    CHECK(aligned[31 * 256 + 30] > aligned[26 * 256 + 38] + 0.5f);
    CHECK(strstr(siril_command_catalog(), "calibrate\t") && strstr(siril_command_catalog(), "register\t"));
    puts("PASS: upstream global star registration aligned translated synthetic star fields and preserved the reference star in the default Winsorized stack");
    const char *transforms[] = {"homography", "affine", "similarity", "shift"};
    const char *interpolations[] = {"lanczos4", "cubic", "linear", "nearest", "area", "none"};
    for (int pass = 0; pass < 6; pass++) {
        const char *transform = pass < 4 ? transforms[pass] : "shift";
        snprintf(script, sizeof script,
            "setref stars 1\nregister stars -2pass -transf=%s -minpairs=4 -maxstars=100 -layer=0\n"
            "seqapplyreg stars -prefix=a%d_ -interp=%s -noclamp -scale=1 -framing=current -layer=0\n"
            "stack a%d_stars mean none 3 3 -norm=addscale -weight=nbstars -filter-fwhm=100%% -32b -out=advanced%d.fits\n",
            transform, pass, interpolations[pass], pass, pass);
        CHECK(siril_run_commands(registered, script, error, sizeof error));
        snprintf(path, sizeof path, "%s/advanced%d.fits", registered, pass);
        image = siril_image_read(path, error, sizeof error);
        CHECK(image && siril_image_info(image, &info) && info.width == 256 && info.height == 256);
        CHECK(read_pixels(path, aligned, 256 * 256) == 0);
        CHECK(aligned[31 * 256 + 30] > 0.65f && aligned[26 * 256 + 38] < 0.1f);
        siril_image_free(image);
    }
    // Actual transformed output size, not just acceptance of the scale flag.
    CHECK(siril_run_commands(registered,
        "register stars -transf=similarity -minpairs=4 -maxstars=100 -interp=linear -scale=0.5 -prefix=half_\n"
        "stack half_stars median -nonorm -32b -out=half.fits\n", error, sizeof error));
    snprintf(path, sizeof path, "%s/half.fits", registered);
    image = siril_image_read(path, error, sizeof error);
    CHECK(image && siril_image_info(image, &info) && info.width == 128 && info.height == 128);
    siril_image_free(image);
    // Original normalization/weights/filter parser must execute with real
    // per-frame registration and background statistics.
    const char *norms[] = {"add", "addscale", "mul", "mulscale"};
    const char *weights[] = {"noise", "nbstars", "wfwhm", "nbstack"};
    for (int i = 0; i < 4; i++) {
        snprintf(script, sizeof script,
            "stack r_stars mean none 3 3 -norm=%s -fastnorm -weight=%s "
            "-filter-fwhm=100%% -filter-wfwhm=100%% -filter-round=100%% -filter-bkg=100%% -filter-nbstars=100%% -32b -out=norm%d.fits\n",
            norms[i], weights[i], i);
        CHECK(siril_run_commands(registered, script, error, sizeof error));
        snprintf(path, sizeof path, "%s/norm%d.fits", registered, i);
        image = siril_image_read(path, error, sizeof error);
        CHECK(image && read_pixels(path, aligned, 256 * 256) == 0);
        CHECK(isfinite(aligned[31 * 256 + 30]) && aligned[31 * 256 + 30] > 0.6f);
        siril_image_free(image);
    }
    puts("PASS: real two-pass registration/application, four transforms, six interpolators, output scaling, four normalizations/weights and five quality filters preserved translated star photometry");
    CHECK(sequence_checks(registered, combo_process) == 0);
    CHECK(drizzle_checks(argv[1]) == 0);
    snprintf(path, sizeof path, "%s/postprocessed.fits", argv[1]);
    snprintf(script, sizeof script, "load %s\nautostretch -linked\nsave %s\nclose\n", light, path);
    CHECK(siril_run_commands(frames, script, error, sizeof error));
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    CHECK(status == 0);
    fits_read_img(file, TFLOAT, 1, 4, NULL, actual, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    CHECK(fabsf(actual[0] - a[0]) > 0.01f);
    for (int i = 0; i < 4; i++) {
        CHECK(isfinite(actual[i]) && actual[i] >= 0 && actual[i] <= 1);
        if (i) CHECK(actual[i] > actual[i - 1]);
    }
    puts("PASS: original load/autostretch/save commands applied and exported monotonic finite MTF pixels");
    siril_image_free(calibration);
    // ASIAIR camera FITS commonly use unsigned 16-bit samples. Verify Siril's
    // full-range normalization and float export rather than only float inputs.
    char raw_path[4096], raw_output[4096];
    snprintf(raw_path, sizeof raw_path, "%s/raw16.fits", argv[1]);
    snprintf(raw_output, sizeof raw_output, "%s/raw16-export.fits", argv[1]);
    const unsigned short raw[] = {0, 12345, 32768, 65535};
    CHECK(fixture(raw_path, raw, USHORT_IMG, TUSHORT) == 0);
    image = siril_image_read(raw_path, error, sizeof error);
    CHECK(image && siril_image_info(image, &info));
    CHECK(info.working_bitpix == FLOAT_IMG);
    CHECK(siril_image_write(image, raw_output));
    status = 0;
    fits_open_file(&file, raw_output, READONLY, &status);
    CHECK(status == 0);
    fits_read_img(file, TFLOAT, 1, 4, NULL, actual, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    for (int i = 0; i < 4; i++) CHECK(fabsf(actual[i] - raw[i] / 65535.f) < 1e-6f);
    siril_image_free(image);
    puts("PASS: upstream Siril FITS metadata, missing-file handling, subtraction/addition, scalar division, float FITS round-trip, unsigned 16-bit normalization, overwrite refusal, and automatic MTF preview");
    char cfa[4096], color_output[4096];
    snprintf(cfa, sizeof cfa, "%s/cfa", argv[1]);
    CHECK(mkdir(cfa, 0700) == 0);
    for (int i = 0; i < 3; i++) {
        snprintf(path, sizeof path, "%s/frame%d.fits", cfa, i);
        CHECK(cfa_fixture(path) == 0);
        if (!i) {
            CHECK(analysis_reference(path, NULL, 1) == 0);
            SirilRegion cfa_region = {1, 3, 7, 9};
            CHECK(analysis_reference(path, &cfa_region, 1) == 0);
            CHECK(analysis_reference(path, &cfa_region, 0) == 0);
            SirilImage *raw_image = siril_image_read(path, error, sizeof error);
            CHECK(raw_image && siril_image_statistics(raw_image, &cfa_region, 1, simple_stats) == 3);
            CHECK(simple_stats[0].mean > 0.6 && simple_stats[0].mean < 0.61);
            CHECK(simple_stats[1].mean > 0.3 && simple_stats[1].mean < 0.31);
            CHECK(simple_stats[2].mean > 0.1 && simple_stats[2].mean < 0.11);
            siril_image_free(raw_image);
            puts("PASS: top-down unsigned CFA and odd-origin selected CFA statistics match original R/G/B filters");
        }
    }
    CHECK(siril_run_commands(cfa,
        "set32bits\nconvert cfa -out=../process\ncd ../process\n"
        "calibrate cfa -cfa -debayer -prefix=pp_\n"
        "stack pp_cfa median -nonorm -out=color.fits\n", error, sizeof error));
    snprintf(color_output, sizeof color_output, "%s/color.fits", process);
    float color[64 * 64 * 3];
    long color_axes[3] = {0};
    status = 0;
    fits_open_file(&file, color_output, READONLY, &status);
    fits_get_img_size(file, 3, color_axes, &status);
    fits_read_img(file, TFLOAT, 1, 64 * 64 * 3, NULL, color, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0 && color_axes[0] == 64 && color_axes[1] == 64 && color_axes[2] == 3);
    const int center = 32 * 64 + 32;
    CHECK(fabsf(color[center] - 0.61f) < 0.015f);
    CHECK(fabsf(color[64 * 64 + center] - 0.31f) < 0.015f);
    CHECK(fabsf(color[2 * 64 * 64 + center] - 0.11f) < 0.015f);
    image = siril_image_read(color_output, error, sizeof error);
    CHECK(analysis_reference(color_output, NULL, 0) == 0);
    SirilRegion rgb_region = {3, 7, 19, 15};
    CHECK(analysis_reference(color_output, &rgb_region, 0) == 0);
    CHECK(image && siril_image_info(image, &info) && info.channels == 3);
    CHECK(siril_image_preview(image, 64, &preview));
    CHECK(preview.rgba && preview.width == 64 && preview.height == 64);
    siril_preview_free(&preview);
    snprintf(path, sizeof path, "%s/color-roundtrip.fits", argv[1]);
    CHECK(siril_image_write(image, path));
    siril_image_free(image);
    float roundtrip[64 * 64 * 3];
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    fits_read_img(file, TFLOAT, 1, 64 * 64 * 3, NULL, roundtrip, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    for (int i = 0; i < 64 * 64 * 3; i++) CHECK(fabsf(roundtrip[i] - color[i]) < 1e-6f);
    puts("PASS: original CFA calibration/debayer/stack pipeline reconstructed RGGB colors from unsigned 16-bit FITS, previewed RGB and preserved all RGB planes on export");
    // New native controls must execute real transforms and retain RGB channels.
    snprintf(path, sizeof path, "%s/color-tools.fits", argv[1]);
    snprintf(script, sizeof script,
        "load %s\ncrop 8 8 32 24\nasinh 5 0\nmtf 0 0.25 1\nsatu 0.2 0\nrotate 90 -nocrop\nsave %s\nclose\n", color_output, path);
    CHECK(siril_run_commands(process, script, error, sizeof error));
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    fits_get_img_size(file, 3, color_axes, &status);
    fits_close_file(file, &status);
    CHECK(status == 0 && color_axes[0] == 24 && color_axes[1] == 32 && color_axes[2] == 3);
    image = siril_image_read(path, error, sizeof error);
    CHECK(image && siril_image_preview(image, 64, &preview));
    siril_preview_free(&preview);
    siril_image_free(image);
    puts("PASS: upstream crop, Asinh, manual MTF, saturation and rotation commands processed and exported an RGB image");
    char gradient[4096];
    snprintf(gradient, sizeof gradient, "%s/gradient.fits", argv[1]);
    CHECK(gradient_fixture(gradient) == 0);
    snprintf(path, sizeof path, "%s/gradient-processed.fits", argv[1]);
    snprintf(script, sizeof script, "load %s\nsubsky 1 -samples=10 -tolerance=3\ndenoise\nsave %s\nclose\n", gradient, path);
    CHECK(siril_run_commands(process, script, error, sizeof error));
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    fits_read_img(file, TFLOAT, 1, 256 * 256, NULL, aligned, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    double left_mean = 0, right_mean = 0;
    for (int y = 16; y < 240; y++) for (int x = 16; x < 48; x++) {
        left_mean += aligned[y * 256 + x];
        right_mean += aligned[y * 256 + x + 192];
    }
    CHECK(fabs(left_mean - right_mean) / (224 * 32) < 0.02);
    CHECK(aligned[128 * 256 + 128] > aligned[128 * 256 + 100] + 0.25f);
    for (int i = 0; i < 256 * 256; i++) CHECK(isfinite(aligned[i]));
    puts("PASS: original polynomial background extraction and denoising removed a synthetic gradient while retaining its bright star");
    SirilBackground *background = siril_background_open(gradient, error, sizeof error);
    CHECK(background);
    CHECK(siril_background_generate(background, 8, 3, 0, 0, 5, 1, error, sizeof error));
    size_t generated_count = siril_background_samples(background, NULL, 0);
    CHECK(generated_count > 6);
    CHECK(siril_background_remove(background, 0));
    CHECK(siril_background_samples(background, NULL, 0) == generated_count - 1);
    CHECK(!siril_background_add(background, 0, 0, 0));
    siril_background_clear(background);
    CHECK(siril_background_samples(background, NULL, 0) == 0);
    for (int y = 32; y <= 224; y += 96) for (int x = 32; x <= 224; x += 96) {
        if (x == 128 && y == 128) continue;
        CHECK(siril_background_add(background, x, y, 0));
    }
    CHECK(!siril_background_add(background, 32, 32, 0));
    SirilBackgroundSample samples[8];
    CHECK(siril_background_samples(background, samples, 8) == 8);
    CHECK(samples[0].x == 32 && samples[0].y == 32 && samples[0].size == 25);
    CHECK(siril_background_preview(background, 0, -1, 0, &preview));
    size_t sample_pixel = (32 * preview.width + 32) * 4;
    CHECK(fabs(samples[0].median[0] - preview.rgba[sample_pixel] / 255.0) < 0.01);
    siril_preview_free(&preview);
    SirilBackgroundOptions bg_options = {
        .method = 0, .interpolation = 1, .degree = 1, .correction = 0, .smoothing = 0.5,
        .scale = 5, .smoothness = 1, .protect = 1, .protect_threshold = 0.05,
        .protect_amount = 0.5, .simplified = 0, .auto_degree = 1, .downsample = 4
    };
    for (int method = 0; method < 5; method++) {
        bg_options.method = method >= 3;
        bg_options.interpolation = method == 1 ? 0 : 1;
        bg_options.correction = method == 2 ? 1 : 0;
        bg_options.simplified = method == 4;
        CHECK(siril_background_compute(background, &bg_options, error, sizeof error));
        CHECK(siril_background_preview(background, 1, -1, 1, &preview));
        siril_preview_free(&preview);
        CHECK(siril_background_preview(background, 2, -1, 1, &preview));
        siril_preview_free(&preview);
        snprintf(path, sizeof path, "%s/interactive-background-%d.fits", argv[1], method);
        CHECK(siril_background_write(background, path));
        CHECK(!siril_background_write(background, path));
        status = 0;
        fits_open_file(&file, path, READONLY, &status);
        fits_read_img(file, TFLOAT, 1, 256 * 256, NULL, aligned, &any_null, &status);
        fits_close_file(file, &status);
        CHECK(status == 0);
        left_mean = right_mean = 0;
        for (int y = 16; y < 240; y++) for (int x = 16; x < 48; x++) {
            left_mean += aligned[y * 256 + x]; right_mean += aligned[y * 256 + x + 192];
        }
        double residual_gradient = fabs(left_mean - right_mean) / (224 * 32);
        printf("Background variant %d residual left/right difference: %.6f\n", method, residual_gradient);
        if (method != 3) CHECK(residual_gradient < 0.03);
        CHECK(aligned[128 * 256 + 128] > aligned[128 * 256 + 100] + 0.2f);
        for (int i = 0; i < 256 * 256; i++) CHECK(isfinite(aligned[i]));
        if (method >= 3) {
            // Default automatic modelling need not perfectly fit this fixture's
            // plane. Its contract is fidelity to the original command, including
            // that residual; the optional simplified plane removes it explicitly.
            char reference[4096];
            snprintf(reference, sizeof reference, "%s/upstream-auto-%d.fits", argv[1], method);
            snprintf(script, sizeof script, "load %s\nsubsky -auto -scale=5 -smoothness=1 -protect_threshold=0.05 -protect_amount=0.5 -degree=1 -downsample=4 -mode=subtract%s\nsave %s\nclose\n",
                     gradient, method == 4 ? " -simplified" : "", reference);
            CHECK(siril_run_commands(process, script, error, sizeof error));
            float *comparison = malloc(256 * 256 * sizeof(float));
            CHECK(comparison);
            status = 0;
            fits_open_file(&file, reference, READONLY, &status);
            fits_read_img(file, TFLOAT, 1, 256 * 256, NULL, comparison, &any_null, &status);
            fits_close_file(file, &status);
            CHECK(status == 0);
            for (int i = 0; i < 256 * 256; i++) CHECK(fabsf(aligned[i] - comparison[i]) < 1e-6f);
            free(comparison);
        }
    }
    CHECK(siril_background_remove(background, 0));
    CHECK(!siril_background_preview(background, 1, -1, 1, &preview));
    bg_options.method = 0; bg_options.degree = 4;
    CHECK(!siril_background_compute(background, &bg_options, error, sizeof error));
    siril_background_free(background);
    puts("PASS: interactive samples, coordinate/median mapping, invalidation and protected export; polynomial/RBF/subtract/divide and simplified automatic model removed gradients while preserving a star; both automatic modes matched original commands pixel-for-pixel");
    snprintf(script, sizeof script, "load %s\n", light);
    CHECK(siril_run_commands(process, script, error, sizeof error));
    CHECK(gfit->data || gfit->fdata);
    image = siril_image_read(light, error, sizeof error);
    CHECK(image);
    float saved_pixel[3], retained_pixel[3];
    CHECK(siril_image_pixel(image, 0, 0, saved_pixel));
    siril_release_workspace();
    CHECK(!gfit->data && !gfit->fdata && !sequence_is_loaded() && !single_image_is_loaded());
    CHECK(siril_image_pixel(image, 0, 0, retained_pixel));
    CHECK(saved_pixel[0] == retained_pixel[0]);
    siril_release_workspace(); // idempotent
    CHECK(siril_run_commands(process, script, error, sizeof error));
    CHECK(gfit->data || gfit->fdata);
    siril_release_workspace();
    siril_image_free(image);
    puts("PASS: native workspace release freed command image/sequence state, preserved independent image sessions, and allowed subsequent commands");
    return 0;
}
