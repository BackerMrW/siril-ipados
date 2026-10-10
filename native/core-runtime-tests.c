// SPDX-License-Identifier: GPL-3.0-or-later
/* Executes against the real upstream engine on an Apple iPad simulator. */
#include "SirilCore.h"
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
static int star_fixture(const char *path, int dx, int dy) {
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
        .protect_amount = 0.5, .simplified = 1, .auto_degree = 1, .downsample = 2
    };
    for (int method = 0; method < 4; method++) {
        bg_options.method = method == 3;
        bg_options.interpolation = method == 1 ? 0 : 1;
        bg_options.correction = method == 2 ? 1 : 0;
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
        CHECK(fabs(left_mean - right_mean) / (224 * 32) < 0.03);
        CHECK(aligned[128 * 256 + 128] > aligned[128 * 256 + 100] + 0.2f);
        for (int i = 0; i < 256 * 256; i++) CHECK(isfinite(aligned[i]));
    }
    CHECK(siril_background_remove(background, 0));
    CHECK(!siril_background_preview(background, 1, -1, 1, &preview));
    bg_options.method = 0; bg_options.degree = 4;
    CHECK(!siril_background_compute(background, &bg_options, error, sizeof error));
    siril_background_free(background);
    puts("PASS: interactive samples, selected coordinates/medians, invalidation and protected export; original polynomial/RBF/automatic models and subtract/divide preserved a star and removed gradients");
    return 0;
}
