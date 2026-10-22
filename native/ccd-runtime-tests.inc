// SPDX-License-Identifier: GPL-3.0-or-later
#include "algos/ccd-inspector.h"
extern int siril_ipados_tilt_values(fits *, int, psf_star **, float[7], sensor_tilt *);
static int ccd_numeric_checks(void) {
    fits shape = {.rx = 200, .ry = 160};
    psf_star measured[32] = {0}; psf_star *stars[33] = {0};
    for (int q = 0; q < 4; q++) for (int k = 0; k < 8; k++) {
        int index = q * 8 + k; stars[index] = &measured[index];
        // Four central and four outer stars per quadrant. The low/high
        // outliers are removed by the independently calculated 25% trim.
        double dx = k < 4 ? 5 + k : 85 + k;
        double dy = k < 4 ? 5 + k : 65 + k;
        measured[index].xpos = 100 + (q % 2 ? dx : -dx);
        measured[index].ypos = 80 + (q / 2 ? dy : -dy);
        measured[index].fwhmx = measured[index].fwhmy = k == 0 ? .01 : k == 7 ? 40 : 2 + q;
    }
    float values[7]; sensor_tilt polygon;
    sensor_tilt *saved_overlay = com.tilt;
    sensor_tilt existing_overlay = {.fwhm_centre = 123};
    com.tilt = &existing_overlay;
    sensor_tilt *previous = com.tilt;
    CHECK(siril_ipados_tilt_values(&shape, 32, stars, values, &polygon));
    CHECK(com.tilt == previous);
    CHECK(fabs(values[0] - 3.5) < 1e-6);
    for (int q = 0; q < 4; q++) {
        CHECK(fabs(values[q + 1] - (2 + q)) < 1e-6);
        CHECK(fabs(polygon.fwhm[q] - (2 + q)) < 1e-6);
        double radius = hypot(200, 160) / 4 * (2 + q) / 3.5;
        const double angles[] = {7 * G_PI / 4, G_PI / 4, 5 * G_PI / 4, 3 * G_PI / 4};
        CHECK(fabs(polygon.pt[q].x - (100 + radius * sin(angles[q]))) < 1.01);
        CHECK(fabs(polygon.pt[q].y - (80 - radius * cos(angles[q]))) < 1.01);
    }
    CHECK(fabs(values[5] - 2.875) < 1e-6 && fabs(values[6] - 4.125) < 1e-6);
    CHECK(!siril_ipados_tilt_values(&shape, 8, stars, values, &polygon));
    CHECK(com.tilt == previous);
    puts("PASS: original CCD-inspector 25-percent trimmed quadrant/central/outer FWHM means and polygon matched independent outlier arithmetic; incomplete zones rejected and existing overlay preserved");
    SirilSensorTilt frames[2] = {
        {.stars=15, .channel=1, .width=200, .height=160, .mean=3.5, .quadrant={2,3,4,5}, .centre=3, .outer=4},
        {.stars=18, .channel=1, .width=200, .height=160, .mean=4.5, .quadrant={6,5,4,3}, .centre=5, .outer=6}
    }, average;
    CHECK(siril_sensor_tilt_average(frames, 2, &average));
    CHECK(average.stars == 16 && average.channel == 1 && average.mean == 4 && average.centre == 4 && average.outer == 5);
    CHECK(average.difference == 0 && average.percent == 0 && average.off_axis == 1);
    for (int q = 0; q < 4; q++) CHECK(average.quadrant[q] == 4);
    CHECK(com.tilt == previous);
    CHECK(!siril_sensor_tilt_average(frames, 0, &average));
    frames[1].width = 199; CHECK(!siril_sensor_tilt_average(frames, 2, &average)); frames[1].width = 200;
    frames[1].channel = 0; CHECK(!siril_sensor_tilt_average(frames, 2, &average)); frames[1].channel = 1;
    frames[1].quadrant[2] = NAN; CHECK(!siril_sensor_tilt_average(frames, 2, &average));
    frames[1].quadrant[2] = 0; CHECK(!siril_sensor_tilt_average(frames, 2, &average));
    CHECK(com.tilt == &existing_overlay && existing_overlay.fwhm_centre == 123);
    com.tilt = saved_overlay;
    puts("PASS: sequence tilt equal-frame float means and integer mean star count matched independent arithmetic; incomplete/nonfinite/mismatched inputs rejected and previous overlay preserved");
    return 0;
}

static int ccd_panel_checks(const char *directory) {
    enum { width = 257, height = 193, channels = 3 };
    char path[4096], error[512];
    for (int top_down = 0; top_down < 2; top_down++) {
        snprintf(path, sizeof path, "%s/ccd-panels-%d.fits", directory, top_down);
        float *data = malloc(width * height * channels * sizeof(float)); CHECK(data);
        for (int c = 0; c < channels; c++) for (int row = 0; row < height; row++) for (int x = 0; x < width; x++) {
            int y = top_down ? row : height - 1 - row;
            data[(c * height + row) * width + x] = .02f + c * .15f + y * .001f + x * .0002f;
        }
        fitsfile *file = NULL; int status = 0; long axes[] = {width, height, channels};
        fits_create_file(&file, path, &status); fits_create_img(file, FLOAT_IMG, 3, axes, &status);
        char *order = top_down ? "TOP-DOWN" : "BOTTOM-UP";
        fits_update_key(file, TSTRING, "ROWORDER", order, NULL, &status);
        fits_write_img(file, TFLOAT, 1, width * height * channels, data, &status);
        fits_close_file(file, &status); free(data); CHECK(!status);
        gchar *before = NULL; gsize size = 0; CHECK(g_file_get_contents(path, &before, &size, NULL));
        SirilImage *image = siril_image_read(path, error, sizeof error); CHECK(image);
        for (int mode = 0; mode < 7; mode++) {
            SirilDisplayOptions options = {.mode = mode, .low = .01, .high = .75, .inverted = mode % 2, .unlinked = mode == 5};
            SirilPreview whole; CHECK(siril_image_preview_mode(image, width, -1, &options, &whole));
            CHECK(whole.width == width && whole.height == height);
            for (int large = 0; large < 2; large++) for (int index = 0; index < 9; index++) {
                SirilRegion region; SirilPreview panel;
                CHECK(siril_image_aberration_panel(image, 127, large ? 768 : 381, index, -1, &options, &region, &panel));
                const int small_x[] = {0, 65, 130}, small_y[] = {0, 33, 66};
                const int large_x[] = {0, 0, 1}, large_y[] = {0, -31, -63};
                int x0 = (large ? large_x : small_x)[index % 3], y0 = (large ? large_y : small_y)[index / 3];
                int side = large ? 256 : 127;
                CHECK(region.x == x0 && region.y == y0 && region.width == side && region.height == side);
                CHECK(panel.width == side && panel.height == side);
                for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) {
                    BYTE *actual = panel.rgba + (y * side + x) * 4;
                    if (x + x0 < 0 || x + x0 >= width || y + y0 < 0 || y + y0 >= height) {
                        CHECK(actual[0] == 0 && actual[1] == 0 && actual[2] == 0 && actual[3] == 255);
                    } else CHECK(!memcmp(actual, whole.rgba + ((y + y0) * width + x + x0) * 4, 4));
                }
                siril_preview_free(&panel);
            }
            siril_preview_free(&whole);
        }
        SirilDisplayOptions linear = {.mode = 0, .low = 0, .high = 1};
        SirilRegion region; SirilPreview detached;
        CHECK(siril_image_aberration_panel(image, 256, 381, 4, 1, &linear, &region, &detached));
        CHECK(region.x == 0 && region.y == -31 && detached.width == 256 && detached.height == 256);
        SirilPreview invalid;
        CHECK(!siril_image_aberration_panel(image, 126, 381, 0, -1, &linear, &region, &invalid) && !invalid.rgba);
        CHECK(!siril_image_aberration_panel(image, 256, 299, 0, -1, &linear, &region, &invalid) && !invalid.rgba);
        CHECK(!siril_image_aberration_panel(image, 256, 381, 9, -1, &linear, &region, &invalid) && !invalid.rgba);
        siril_image_free(image);
        // Independent native pixel in the padded centre panel, green plane.
        int displayed_y = top_down ? height - 1 - 66 : 66;
        int expected = lroundf((.02f + .15f + displayed_y * .001f + 130 * .0002f) * 255);
        for (int c = 0; c < 3; c++) CHECK(abs(detached.rgba[(97 * 256 + 130) * 4 + c] - expected) <= 1);
        siril_preview_free(&detached);
        gchar *after = NULL; gsize after_size = 0; CHECK(g_file_get_contents(path, &after, &after_size, NULL));
        CHECK(size == after_size && !memcmp(before, after, size)); g_free(before); g_free(after);
    }
    puts("PASS: original aberration panel geometry and odd-size TOP-DOWN/BOTTOM-UP RGB pixels, seven global display modes, black padding and detached ownership matched independent origins and the full-image display");
    return 0;
}
