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
    return 0;
}
