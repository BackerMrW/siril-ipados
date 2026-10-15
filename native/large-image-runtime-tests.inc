// SPDX-License-Identifier: GPL-3.0-or-later
/* Synthetic full sensor dimensions and FITS layouts observed locally in
 * ASI2600MC Air RAW and RGB files. No private image data or headers are bundled. */
static unsigned short large_image_value(int channel, int x, int row) {
    return (unsigned short)(1000 + ((unsigned)x * 13 + (unsigned)row * 17 + (unsigned)channel * 257) % 60000);
}
static int large_image_reference(const char *directory) {
    enum { W = 6248, H = 4176 };
    for (int rgb = 0; rgb < 2; rgb++) {
        char path[2048], create[2050], output[2048], error[512];
        snprintf(path, sizeof path, "%s/full-sensor-%d.fits", directory, rgb);
        snprintf(create, sizeof create, "!%s", path);
        snprintf(output, sizeof output, "%s/full-sensor-result-%d.fits", directory, rgb);
        fitsfile *file = NULL; int status = 0, channels = rgb ? 3 : 1;
        long axes[] = {W, H, channels};
        fits_create_file(&file, create, &status);
        fits_create_img(file, rgb ? FLOAT_IMG : USHORT_IMG, rgb ? 3 : 2, axes, &status);
        if (rgb) fits_update_key(file, TSTRING, "ROWORDER", "BOTTOM-UP", NULL, &status);
        else fits_update_key(file, TSTRING, "BAYERPAT", "RGGB", NULL, &status);
        double exposure = 300;
        fits_update_key(file, TDOUBLE, "EXPTIME", &exposure, NULL, &status);
        unsigned short integer[W]; float floating[W];
        for (int c = 0; c < channels; c++) for (int row = 0; row < H; row++) {
            for (int x = 0; x < W; x++) {
                integer[x] = large_image_value(c, x, row);
                floating[x] = integer[x] / 65535.f;
            }
            LONGLONG offset = ((LONGLONG)c * H + row) * W + 1;
            if (rgb) fits_write_img(file, TFLOAT, offset, W, floating, &status);
            else fits_write_img(file, TUSHORT, offset, W, integer, &status);
        }
        fits_close_file(file, &status); CHECK(!status);
        SirilImage *image = siril_image_read(path, error, sizeof error); CHECK(image);
        SirilImageInfo info; CHECK(siril_image_info(image, &info));
        CHECK(info.width == W && info.height == H && info.channels == (uint32_t)channels && !info.top_down);
        CHECK(info.working_bitpix == FLOAT_IMG && fabs(info.exposure - 300) < 1e-8);
        const int points[][2] = {{0, 0}, {W - 1, H - 1}, {W / 2 + 3, H / 2 - 7}};
        for (int i = 0; i < 3; i++) {
            float actual[3]; CHECK(siril_image_pixel(image, points[i][0], points[i][1], actual) == channels);
            for (int c = 0; c < channels; c++) CHECK(fabsf(actual[c] - large_image_value(c, points[i][0], H - 1 - points[i][1]) / 65535.f) < 1e-7f);
        }
        SirilPreview preview = {0};
        CHECK(siril_image_preview_display(image, 512, -1, 0, &preview));
        CHECK(preview.rgba && preview.width == 512 && preview.height > 0 && preview.height <= 512);
        siril_preview_free(&preview);
        SirilRegion region = {91, 137, 63, 49}; SirilChannelStatistics stats[3];
        CHECK(siril_image_statistics(image, &region, 0, stats) == channels);
        for (int c = 0; c < channels; c++) {
            double sum = 0;
            for (int y = region.y; y < region.y + region.height; y++) for (int x = region.x; x < region.x + region.width; x++)
                sum += large_image_value(c, x, H - 1 - y) / 65535.f;
            CHECK(stats[c].total == (uint64_t)region.width * region.height && stats[c].norm > 0);
            CHECK(fabs(stats[c].mean / stats[c].norm - sum / (region.width * region.height)) < 2e-7);
        }
        CHECK(siril_image_divide_scalar(image, 2));
        CHECK(siril_image_write(image, output));
        siril_image_free(image);
        image = siril_image_read(output, error, sizeof error); CHECK(image);
        CHECK(siril_image_info(image, &info) && info.width == W && info.height == H && info.channels == (uint32_t)channels);
        for (int i = 0; i < 3; i++) {
            float actual[3]; CHECK(siril_image_pixel(image, points[i][0], points[i][1], actual) == channels);
            for (int c = 0; c < channels; c++) CHECK(fabsf(actual[c] - large_image_value(c, points[i][0], H - 1 - points[i][1]) / 65535.f / 2) < 1e-7f);
        }
        siril_image_free(image);
        CHECK(remove(path) == 0 && remove(output) == 0);
    }
    puts("PASS: full 6248x4176 synthetic RGGB uint16 and RGB float FITS import, orientation, preview, independent ROI statistics, original scalar operation and full-size saved/reopened pixels");
    return 0;
}
