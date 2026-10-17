// SPDX-License-Identifier: GPL-3.0-or-later
#include "algos/demosaicing.h"
static int cfa_format_color_checks(const char *directory) {
    const char *names[] = {"linear-cfa-color.dng", "xisf-colored-cfa.xisf", "ser-colored-cfa.ser"};
    char path[4096], output[4096], error[512];
    for (int k = 0; k < 3; k++) {
        snprintf(path, sizeof path, "%s/%s", getenv("SIRIL_FORMAT_FIXTURES"), names[k]);
        SirilImage *image = NULL;
        if (k == 2) {
            gchar *body = NULL; gsize length = 0; CHECK(g_file_get_contents(path, &body, &length, NULL));
            snprintf(path, sizeof path, "%s/colored-cfa.ser", directory);
            CHECK(g_file_set_contents(path, body, length, NULL)); g_free(body);
            SirilSER *session = siril_ser_open(path, error, sizeof error); CHECK(session);
            image = siril_ser_read(session, 0, error, sizeof error); siril_ser_close(session);
        } else image = siril_image_read_any(path, error, sizeof error);
        CHECK(image);
        if (k == 2) {
            SirilChannelStatistics direct[3];
            CHECK(siril_image_statistics(image, NULL, 1, direct) == 3);
            const double expected[] = {10000. / 65535, 20000. / 65535, 40000. / 65535};
            for (int c = 0; c < 3; c++) CHECK(fabs(direct[c].mean - expected[c]) < 1e-6);
        }
        snprintf(output, sizeof output, "%s/colored-cfa-%d.fits", directory, k);
        CHECK(siril_image_write(image, output)); siril_image_free(image);
        fits fit = {0}; CHECK(readfits(output, &fit, NULL, TRUE) == 0);
        CHECK(debayer_if_needed(TYPEFITS, &fit, TRUE) == 0 && fit.naxes[2] == 3);
        for (int c = 0; c < 3; c++) {
            const double expected[] = {10000. / 65535, 20000. / 65535, 40000. / 65535};
            CHECK(fabs(fit.fpdata[c][(fit.ry / 2) * fit.rx + fit.rx / 2] - expected[c]) < 2e-5);
        }
        clearfits(&fit);
    }
    puts("PASS: independent colored RGGB DNG/XISF/SER fixtures retained correct red/green/blue levels through original import, FITS metadata and original demosaicing");
    return 0;
}
