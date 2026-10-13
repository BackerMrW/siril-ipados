// SPDX-License-Identifier: GPL-3.0-or-later
#include <malloc/malloc.h>
#include "core/masks.h"
static void independent_rainbow(BYTE value, BYTE rgb[3]) {
    double hue = 5.0 * (1 - value / 255.0), fraction = hue - floor(hue);
    double q = 1 - fraction, t = fraction, components[3];
    switch ((int)floor(hue) % 6) {
        case 0: components[0] = 1; components[1] = t; components[2] = 0; break;
        case 1: components[0] = q; components[1] = 1; components[2] = 0; break;
        case 2: components[0] = 0; components[1] = 1; components[2] = t; break;
        case 3: components[0] = 0; components[1] = q; components[2] = 1; break;
        case 4: components[0] = t; components[1] = 0; components[2] = 1; break;
        default: components[0] = 1; components[1] = 0; components[2] = q; break;
    }
    for (int c = 0; c < 3; c++) rgb[c] = lround(components[c] * 255);
}
static int display_overlay_reference(const char *directory) {
    char path[4096], script[18000], saved[4096], error[512];
    snprintf(path, sizeof path, "%s/display-palette.fits", directory);
    float ramp[256]; for (int i = 0; i < 256; i++) ramp[i] = i / 255.f;
    fitsfile *file = NULL; int status = 0; long axes[] = {32, 8};
    fits_create_file(&file, path, &status); fits_create_img(file, FLOAT_IMG, 2, axes, &status);
    fits_write_img(file, TFLOAT, 1, 256, ramp, &status); fits_close_file(file, &status); CHECK(!status);
    SirilImage *palette_image = siril_image_read(path, error, sizeof error); CHECK(palette_image);
    SirilDisplayOptions palette_options = {.mode = 0, .low = 0, .high = 1, .rainbow = 1};
    SirilPreview palette_preview; CHECK(siril_image_preview_mode(palette_image, 32, -1, &palette_options, &palette_preview));
    for (int y = 0; y < 8; y++) for (int x = 0; x < 32; x++) {
        BYTE expected[3]; independent_rainbow((7 - y) * 32 + x, expected);
        for (int c = 0; c < 3; c++) CHECK(abs(palette_preview.rgba[(y * 32 + x) * 4 + c] - expected[c]) <= 1);
    }
    siril_preview_free(&palette_preview); siril_image_free(palette_image);
    snprintf(path, sizeof path, "%s/icc-source-3.fits", directory);
    fits original = {0}; CHECK(!readfits(path, &original, NULL, TRUE));
    for (int depth = 8; depth <= 32; depth *= 2) {
        CHECK(!mask_create_from_channel(&original, &original, 0, depth));
        size_t required = (size_t)original.rx * original.ry * depth / 8;
        CHECK(malloc_size(original.mask->data) >= required && malloc_size(original.mask->data) < required * 2);
        snprintf(script, sizeof script, "set32bits\nload %s\nmask_from_channel -channel=0 -bitdepth=%d\n", path, depth);
        SirilImage *image = siril_tool_compute(directory, script, error, sizeof error); CHECK(image);
        SirilImage *mask = siril_image_mask_copy(image); CHECK(mask);
        for (int mode = 0; mode < 7; mode++) for (int selected = -1; selected <= 1; selected += 2) for (int rainbow = 0; rainbow <= 1; rainbow++) {
            SirilDisplayOptions options = {.mode = mode, .low = 0, .high = 1, .rainbow = rainbow};
            SirilPreview plain, overlay; CHECK(siril_image_preview_mode(image, 8, selected, &options, &plain));
            options.mask_overlay = 1; CHECK(siril_image_preview_mode(image, 8, selected, &options, &overlay));
            for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) {
                float weight[3]; CHECK(siril_image_pixel(mask, x, y, weight) == 1);
                unsigned value = depth == 8 ? lroundf(weight[0] * 255) : depth == 16 ? ((unsigned)lroundf(weight[0] * 65535) >> 8) : (unsigned)(fminf(1, fmaxf(0, weight[0])) * 255);
                int i = (y * 8 + x) * 4;
                unsigned expected[3] = {plain.rgba[i] + 255 - value, (plain.rgba[i + 1] * value) >> 8, (plain.rgba[i + 2] * value) >> 8};
                if (expected[0] > 255) expected[0] = 255;
                for (int c = 0; c < 3; c++) CHECK(overlay.rgba[i + c] == expected[c]);
                CHECK(overlay.rgba[i + 3] == 255);
            }
            siril_preview_free(&plain); siril_preview_free(&overlay);
        }
        SirilDisplayOptions options = {.mode = 0, .low = 0, .high = 1};
        SirilPreview gray, rainbow; CHECK(siril_image_preview_mode(image, 8, 1, &options, &gray));
        options.rainbow = 1; CHECK(siril_image_preview_mode(image, 8, 1, &options, &rainbow));
        for (int i = 0; i < 48; i++) {
            BYTE expected[3]; independent_rainbow(gray.rgba[i * 4], expected);
            for (int c = 0; c < 3; c++) CHECK(abs(rainbow.rgba[i * 4 + c] - expected[c]) <= 1);
        }
        siril_preview_free(&gray); siril_preview_free(&rainbow);
        snprintf(saved, sizeof saved, "%s/display-mask-%d.fits", directory, depth);
        CHECK(siril_image_write(mask, saved));
        SirilImage *restored = siril_image_read(path, error, sizeof error); CHECK(restored);
        CHECK(siril_image_load_mask(restored, saved));
        CHECK(!siril_image_load_mask(restored, path)); // RGB companion is invalid.
        options = (SirilDisplayOptions){.mode = 0, .low = 0, .high = 1, .mask_overlay = 1};
        CHECK(siril_image_preview_mode(restored, 8, -1, &options, &gray));
        siril_preview_free(&gray);
        for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) {
            float original_pixel[3], restored_pixel[3];
            CHECK(siril_image_pixel(image, x, y, original_pixel) == 3 && siril_image_pixel(restored, x, y, restored_pixel) == 3);
            CHECK(!memcmp(original_pixel, restored_pixel, sizeof original_pixel));
        }
        siril_image_free(restored); siril_image_free(mask); siril_image_free(image);
    }
    clearfits(&original);
    puts("PASS: original rainbow palette matched independent HSV; all seven modes and RGB/selected-channel mask overlays matched exact 8/16/32-bit arithmetic, saved masks reopened without pixel changes and allocations used bytes rather than bits");
    return 0;
}
