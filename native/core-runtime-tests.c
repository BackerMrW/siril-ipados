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
    CHECK(!siril_run_commands(frames, "not_a_siril_command\nconvert should_not_exist\n", error, sizeof error));
    CHECK(strstr(error, "Line 1") != NULL);
    CHECK(!siril_run_commands(frames, "'exit'\n", error, sizeof error));
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
        "register stars -transf=shift\nstack r_stars median -nonorm -out=aligned.fits\n", error, sizeof error));
    snprintf(path, sizeof path, "%s/aligned.fits", registered);
    float aligned[256 * 256];
    status = 0;
    fits_open_file(&file, path, READONLY, &status);
    CHECK(status == 0);
    fits_read_img(file, TFLOAT, 1, 256 * 256, NULL, aligned, &any_null, &status);
    fits_close_file(file, &status);
    CHECK(status == 0);
    // Without registration the median suppresses this displaced bright star.
    CHECK(aligned[31 * 256 + 30] > 0.65f);
    CHECK(aligned[31 * 256 + 30] > aligned[26 * 256 + 38] + 0.5f);
    CHECK(strstr(siril_command_catalog(), "calibrate\t") && strstr(siril_command_catalog(), "register\t"));
    puts("PASS: upstream global star registration aligned translated synthetic star fields and preserved the reference star in the median stack");
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
    return 0;
}
