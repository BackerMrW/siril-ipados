// SPDX-License-Identifier: GPL-3.0-or-later
/* Independent known Gaussian noise on a smooth gradient. The gradient makes
 * ordinary sigma larger while the original robust background estimator keeps
 * the known per-channel noise. Native imports also exercise integer scaling. */
static unsigned noise_fixture_state = 0x1a2b3c4du;
static double noise_fixture_uniform(void) {
    noise_fixture_state = 1664525u * noise_fixture_state + 1013904223u;
    return ((double)noise_fixture_state + .5) / 4294967296.0;
}
static int noise_reference(const char *directory) {
    enum { W = 128, H = 128, N = W * H };
    const double sigma[3] = {.003, .01, .03};
    float *pixels = malloc(3 * N * sizeof *pixels); CHECK(pixels);
    for (int c = 0; c < 3; c++) for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        double gaussian = sqrt(-2 * log(noise_fixture_uniform())) * cos(6.283185307179586 * noise_fixture_uniform());
        pixels[c * N + y * W + x] = .15 + .001 * x + .0002 * y + sigma[c] * gaussian;
    }
    for (int mode = 0; mode < 3; mode++) {
        char path[2048], create[2050], error[512];
        snprintf(path, sizeof path, "%s/noise-reference-%d.fits", directory, mode);
        snprintf(create, sizeof create, "!%s", path);
        fitsfile *file = NULL; int status = 0;
        long axes[3] = {W, H, mode ? 1 : 3};
        fits_create_file(&file, create, &status);
        fits_create_img(file, mode == 0 ? FLOAT_IMG : mode == 1 ? USHORT_IMG : BYTE_IMG, mode == 2 ? 2 : 3, axes, &status);
        if (!mode) fits_write_img(file, TFLOAT, 1, 3 * N, pixels, &status);
        else if (mode == 1) {
            unsigned short integer[N];
            for (int i = 0; i < N; i++) integer[i] = (unsigned short)lround(pixels[i] * 65535.0);
            fits_write_img(file, TUSHORT, 1, N, integer, &status);
        } else {
            unsigned char integer[N];
            for (int i = 0; i < N; i++) integer[i] = (unsigned char)lround(pixels[2 * N + i] * 255.0);
            fits_write_img(file, TBYTE, 1, N, integer, &status);
        }
        fits_close_file(file, &status); CHECK(!status);
        SirilImage *image = siril_image_read(path, error, sizeof error); CHECK(image);
        float before[3], after[3]; int channels = mode ? 1 : 3;
        CHECK(siril_image_pixel(image, 40, 50, before) == channels);
        SirilChannelStatistics stats[3];
        CHECK(siril_image_statistics(image, NULL, 0, stats) == channels);
        for (int c = 0; c < channels; c++) {
            double expected = sigma[mode == 2 ? 2 : c];
            CHECK(stats[c].norm > 0 && isfinite(stats[c].background_noise));
            CHECK(fabs(stats[c].background_noise / stats[c].norm / expected - 1) < .08);
            CHECK(stats[c].sigma > stats[c].background_noise * 1.15);
        }
        SirilRegion area = {16, 16, 96, 96};
        CHECK(siril_image_statistics(image, &area, 0, stats) == channels);
        for (int c = 0; c < channels; c++) {
            double expected = sigma[mode == 2 ? 2 : c];
            CHECK(fabs(stats[c].background_noise / stats[c].norm / expected - 1) < .10);
        }
        CHECK(siril_image_pixel(image, 40, 50, after) == channels);
        CHECK(!memcmp(before, after, channels * sizeof(float)));
        siril_image_free(image);
    }
    free(pixels);
    puts("PASS: original robust background noise matched independent Gaussian RGB/16-bit/8-bit amplitudes, full/selected regions and source pixels");
    return 0;
}
