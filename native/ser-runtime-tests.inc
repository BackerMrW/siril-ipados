// SPDX-License-Identifier: GPL-3.0-or-later
static int ser_reference_checks(const char *directory) {
    const char *names[] = {"ser-mono8", "ser-cfa16", "ser-rgb8", "ser-bgr16be", "ser-truncated"};
    char source[4096], copy[4096], output[4096], error[512];
    for (int k = 0; k < 5; k++) {
        snprintf(source, sizeof source, "%s/%s.ser", getenv("SIRIL_FORMAT_FIXTURES"), names[k]);
        snprintf(copy, sizeof copy, "%s/%s.ser", directory, names[k]);
        gchar *bytes = NULL; gsize length = 0;
        CHECK(g_file_get_contents(source, &bytes, &length, NULL));
        CHECK(g_file_set_contents(copy, bytes, length, NULL)); g_free(bytes);
        SirilSER *session = siril_ser_open(copy, error, sizeof error); CHECK(session);
        CHECK(siril_ser_complete(session) == (k != 4));
        CHECK(siril_ser_count(session) == 3 && !siril_ser_read(session, 3, error, sizeof error));
        if (k == 4) {
            SirilImage *first = siril_ser_read(session, 0, error, sizeof error); CHECK(first); siril_image_free(first);
            CHECK(!siril_ser_read(session, 2, error, sizeof error)); siril_ser_close(session); continue;
        }
        for (uint32_t frame = 0; frame < 3; frame++) {
            SirilImage *image = siril_ser_read(session, frame, error, sizeof error); CHECK(image);
            SirilImageInfo info; CHECK(siril_image_info(image, &info));
            int channels = k >= 2 ? 3 : 1;
            CHECK(info.width == 8 && info.height == 6 && info.channels == channels);
            CHECK(fabs(info.exposure - 1) < 1e-9);
            if (k == 1) CHECK(strcmp(info.bayer, "RGGB") == 0); // sensor pattern with bottom-up FITS storage
            for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) {
                float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == channels);
                for (int c = 0; c < channels; c++) {
                    double expected = (k == 0 || k == 2) ? (10 + c * 40 + frame * 10 + y * 3 + x) / 255. : (1000 + c * 100 + frame * 20 + y * 8 + x) / 65535.;
                    CHECK(fabs(pixel[c] - expected) < 1e-7);
                }
            }
            snprintf(output, sizeof output, "%s/%s-%u.fits", directory, names[k], frame);
            CHECK(siril_image_write(image, output)); siril_image_free(image);
            image = siril_image_read(output, error, sizeof error); CHECK(image);
            float pixel[3]; CHECK(siril_image_pixel(image, 3, 4, pixel) == channels);
            for (int c = 0; c < channels; c++) {
                double expected = (k == 0 || k == 2) ? (25 + c * 40 + frame * 10) / 255. : (1035 + c * 100 + frame * 20) / 65535.;
                CHECK(fabs(pixel[c] - expected) < 1e-7);
            }
            size_t required = siril_image_copy_header(image, NULL, 0); char *header = malloc(required); CHECK(header);
            CHECK(siril_image_copy_header(image, header, required) == required);
            CHECK(strstr(header, "Independent observer") && strstr(header, "2020-01-01T00:00:0"));
            free(header); siril_image_free(image);
        }
        siril_ser_close(session);
    }
    puts("PASS: original SER decoder retained all independent mono/CFA/RGB/BGR frames, 8/16-bit samples, both endian orders, orientation, timestamps and metadata through FITS; invalid indices and truncated frames rejected");
    return 0;
}
