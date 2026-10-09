// SPDX-License-Identifier: GPL-3.0-or-later
/* Executes against the real upstream engine on an Apple iPad simulator. */
#include "SirilCore.h"
#include <fitsio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; } } while (0)
static int fixture(const char *path, const float *pixels) {
    fitsfile *file = NULL;
    int status = 0;
    long axes[] = {2, 2};
    double exposure = 120;
    fits_create_file(&file, path, &status);
    if (status) return status;
    fits_create_img(file, FLOAT_IMG, 2, axes, &status);
    fits_update_key(file, TDOUBLE, "EXPTIME", &exposure, NULL, &status);
    fits_write_img(file, TFLOAT, 1, 4, (void *)pixels, &status);
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
    CHECK(fixture(light, a) == 0 && fixture(dark, b) == 0);
    char error[512];
    CHECK(siril_image_read(missing, error, sizeof error) == NULL && error[0]);
    SirilImage *image = siril_image_read(light, error, sizeof error);
    SirilImage *calibration = siril_image_read(dark, error, sizeof error);
    CHECK(image && calibration);
    SirilImageInfo info;
    CHECK(siril_image_info(image, &info));
    CHECK(info.width == 2 && info.height == 2 && info.channels == 1);
    CHECK(info.source_bitpix == FLOAT_IMG && fabs(info.exposure - 120) < 1e-8);
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
    siril_image_free(calibration);
    puts("PASS: upstream Siril FITS metadata, missing-file handling, subtraction/addition, scalar division, float FITS round-trip, overwrite refusal, and automatic MTF preview");
    return 0;
}
