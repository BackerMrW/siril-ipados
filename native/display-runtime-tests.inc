// SPDX-License-Identifier: GPL-3.0-or-later
static int display_reference_checks(SirilImage *image) {
    float source[4];
    for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
        float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == 1); source[y * 2 + x] = pixel[0];
    }
    SirilDisplayOptions options = {.mode = 0, .low = .1, .high = .8};
    for (int mode = 0; mode < 5; mode++) {
        options.mode = mode; options.inverted = 0;
        SirilPreview preview; CHECK(siril_image_preview_mode(image, 2, -1, &options, &preview));
        CHECK(preview.width == 2 && preview.height == 2);
        unsigned low = lround(.1 * 65535), high = lround(.8 * 65535); double delta = high - low;
        for (int i = 0; i < 4; i++) {
            double value = fmax(0, lroundf(source[i] * 65535) - (double)low), expected = 0;
            switch (mode) {
                case 0: expected = value / delta; break;
                case 1: expected = value < 10 ? 0 : log(value / 10) / fabs(log(delta / 10)); break;
                case 2: expected = sqrt(value / delta); break;
                case 3: expected = (value / delta) * (value / delta); break;
                case 4: expected = asinh(value / 1000) / asinh(delta / 1000); break;
            }
            int byte = lround(fmin(1, fmax(0, expected)) * 255);
            for (int c = 0; c < 3; c++) CHECK(abs(preview.rgba[i * 4 + c] - byte) <= 1);
            CHECK(preview.rgba[i * 4 + 3] == 255);
        }
        options.inverted = 1;
        SirilPreview inverted; CHECK(siril_image_preview_mode(image, 2, 0, &options, &inverted));
        for (int i = 0; i < 4; i++) for (int c = 0; c < 3; c++) CHECK(inverted.rgba[i * 4 + c] == 255 - preview.rgba[i * 4 + c]);
        siril_preview_free(&inverted); siril_preview_free(&preview);
    }
    options = (SirilDisplayOptions){.mode = 5, .low = 0, .high = 1};
    SirilPreview modern, original;
    CHECK(siril_image_preview_mode(image, 2, -1, &options, &modern));
    CHECK(siril_image_preview_display(image, 2, -1, 1, &original));
    CHECK(!memcmp(modern.rgba, original.rgba, 16));
    siril_preview_free(&modern); siril_preview_free(&original);
    options.mode = 6; CHECK(siril_image_preview_mode(image, 2, -1, &options, &modern));
    for (int i = 0; i < 4; i++) {
        int below = 0;
        for (int j = 0; j < 4; j++) if (source[j] <= source[i]) below++;
        int expected = lround(below / 4.0 * 255);
        CHECK(abs(modern.rgba[i * 4] - expected) <= 1);
    }
    siril_preview_free(&modern);
    options.low = options.high; CHECK(!siril_image_preview_mode(image, 2, -1, &options, &modern));
    options.low = NAN; CHECK(!siril_image_preview_mode(image, 2, -1, &options, &modern));
    options.low = 0; CHECK(!siril_image_preview_mode(image, 0, -1, &options, &modern));
    for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
        float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == 1 && pixel[0] == source[y * 2 + x]);
    }
    puts("PASS: extracted original display LUT matched independent five-mode formulas and bounds; STF matched original preview, histogram equalization matched exact rank, inversion and source preservation verified");
    return 0;
}
static int display_rgb_reference(const char *directory) {
    char path[4096], error[512]; snprintf(path, sizeof path, "%s/display-rgb.fits", directory);
    float pixels[3 * 64];
    for (int c = 0; c < 3; c++) for (int i = 0; i < 64; i++) pixels[c * 64 + i] = .04f + c * .13f + .0003f * i + (i == 30 ? .25f : 0);
    fitsfile *file = NULL; int status = 0; long axes[] = {8, 8, 3};
    fits_create_file(&file, path, &status); fits_create_img(file, FLOAT_IMG, 3, axes, &status);
    fits_write_img(file, TFLOAT, 1, 3 * 64, pixels, &status); fits_close_file(file, &status); CHECK(!status);
    SirilImage *image = siril_image_read(path, error, sizeof error); CHECK(image);
    fits reference = {0}; CHECK(readfits(path, &reference, NULL, TRUE) == 0);
    struct mtf_params parameters[3]; CHECK(find_unlinked_midtones_balance_default(&reference, parameters) == 0);
    SirilDisplayOptions options = {.mode = 5, .low = 0, .high = 1, .unlinked = 1};
    SirilPreview preview; CHECK(siril_image_preview_mode(image, 8, -1, &options, &preview));
    for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < 3; c++) {
        float value = pixels[c * 64 + (7 - y) * 8 + x];
        int expected = roundf_to_BYTE(MTFp(value, parameters[c]) * 255);
        CHECK(preview.rgba[(y * 8 + x) * 4 + c] == expected);
    }
    siril_preview_free(&preview);
    CHECK(siril_image_preview_mode(image, 8, 1, &options, &preview));
    for (int i = 0; i < 64; i++) CHECK(preview.rgba[i * 4] == preview.rgba[i * 4 + 1] && preview.rgba[i * 4 + 1] == preview.rgba[i * 4 + 2]);
    siril_preview_free(&preview); clearfits(&reference); siril_image_free(image);
    puts("PASS: independent original unlinked STF parameters matched every RGB preview byte and selected-channel grayscale with FITS row orientation");
    return 0;
}
