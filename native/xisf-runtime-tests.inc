// SPDX-License-Identifier: GPL-3.0-or-later
static int xisf_reference_checks(const char *directory) {
    const char *names[] = {"xisf-cfa", "xisf-rgb-planar", "xisf-rgb-normal"};
    char path[4096], output[4096], error[512];
    for (int i = 0; i < 3; i++) {
        snprintf(path, sizeof path, "%s/%s.xisf", getenv("SIRIL_FORMAT_FIXTURES"), names[i]);
        SirilImage *image = siril_image_read_any(path, error, sizeof error); CHECK(image);
        SirilImageInfo info; CHECK(siril_image_info(image, &info));
        CHECK(info.width == 8 && info.height == 6 && info.channels == (i ? 3 : 1));
        CHECK(fabs(info.exposure - 120) < 1e-9);
        if (!i) CHECK(strcmp(info.bayer, "RGGB") == 0);
        for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) {
            float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == info.channels);
            for (int c = 0; c < info.channels; c++) {
                double expected = i ? (c + 1) * .1 + y * .01 + x * .001 : (1000 + 16 * y + x) / 65535.;
                CHECK(fabs(pixel[c] - expected) < 1e-7);
            }
        }
        snprintf(output, sizeof output, "%s/%s.fits", directory, names[i]);
        CHECK(siril_image_write(image, output)); siril_image_free(image);
        image = siril_image_read(output, error, sizeof error); CHECK(image);
        CHECK(siril_image_info(image, &info) && info.width == 8 && info.height == 6);
        CHECK(fabs(info.exposure - 120) < 1e-9);
        if (!i) CHECK(strcmp(info.bayer, "RGGB") == 0);
        float pixel[3]; CHECK(siril_image_pixel(image, 3, 4, pixel) == info.channels);
        for (int c = 0; c < info.channels; c++) {
            double expected = i ? (c + 1) * .1 + .04 + .003 : 1067 / 65535.;
            CHECK(fabs(pixel[c] - expected) < 1e-7);
        }
        siril_image_free(image);
    }
    const char *invalid[] = {"xisf-invalid", "xisf-truncated", "xisf-corrupt-zlib", "xisf-invalid-geometry"};
    for (int i = 0; i < 4; i++) {
        snprintf(path, sizeof path, "%s/%s.xisf", getenv("SIRIL_FORMAT_FIXTURES"), invalid[i]);
        CHECK(!siril_image_read_any(path, error, sizeof error));
    }
    puts("PASS: original XISF decoder retained independent CFA, planar/interleaved RGB float pixels, shuffled zlib data, exposure and working FITS; invalid signature rejected");
    return 0;
}
