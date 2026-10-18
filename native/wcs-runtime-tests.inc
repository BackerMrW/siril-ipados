// SPDX-License-Identifier: GPL-3.0-or-later
static void wcs_tan_reference(double x, double y, double *ra, double *dec) {
    // Independent inverse gnomonic projection, not a WCSLIB round trip.
    const double radians = G_PI / 180, dec0 = -20.4 * radians;
    double dx = x + .5 - 4, dy = 5 - y + .5 - 3;
    double xi = (-.001 * dx + .0003 * dy) * radians;
    double eta = (.0002 * dx + .0012 * dy) * radians;
    double denominator = cos(dec0) - eta * sin(dec0);
    *ra = fmod(atan2(xi, denominator) / radians + 359.9998 + 360, 360);
    *dec = atan2(sin(dec0) + eta * cos(dec0), hypot(denominator, xi)) / radians;
}
static int wcs_coordinate_checks(const char *directory) {
    for (int variant = 0; variant < 4; variant++) {
        char path[4096], error[512]; fitsfile *file = NULL; int status = 0;
        snprintf(path, sizeof path, "%s/independent-wcs-%d.fits", directory, variant);
        long axes[] = {7, 5}; unsigned short values[35];
        for (int i = 0; i < 35; i++) values[i] = 1000 + i;
        fits_create_file(&file, path, &status);
        fits_create_img(file, USHORT_IMG, 2, axes, &status);
        fits_write_img(file, TUSHORT, 1, 35, values, &status);
        fits_update_key(file, TSTRING, "ROWORDER", variant == 1 ? "TOP-DOWN" : "BOTTOM-UP", NULL, &status);
        if (variant != 3) {
            fits_update_key(file, TSTRING, "CTYPE1", variant == 2 ? "GLON-TAN" : "RA---TAN", NULL, &status);
            fits_update_key(file, TSTRING, "CTYPE2", variant == 2 ? "GLAT-TAN" : "DEC--TAN", NULL, &status);
            fits_update_key(file, TSTRING, "CUNIT1", "deg", NULL, &status);
            fits_update_key(file, TSTRING, "CUNIT2", "deg", NULL, &status);
            fits_update_key(file, TSTRING, "RADESYS", "ICRS", NULL, &status);
            const char *keys[] = {"CRPIX1", "CRPIX2", "CRVAL1", "CRVAL2", "CD1_1", "CD1_2", "CD2_1", "CD2_2"};
            double fields[] = {4, 3, 359.9998, -20.4, -.001, .0003, .0002, .0012};
            for (int i = 0; i < 8; i++) fits_update_key(file, TDOUBLE, keys[i], &fields[i], NULL, &status);
        }
        fits_close_file(file, &status); CHECK(!status);
        FILE *bytes = fopen(path, "rb"); CHECK(bytes);
        unsigned char before[5760], after[5760];
        CHECK(fread(before, 1, sizeof before, bytes) == sizeof before && fgetc(bytes) == EOF); fclose(bytes);
        SirilImage *image = siril_image_read(path, error, sizeof error); CHECK(image);
        if (variant < 2) {
            const double points[][2] = {{.5, .5}, {3.5, 2.5}, {6.5, 4.5}, {-13.25, 12.75}};
            for (int i = 0; i < 4; i++) {
                double ra, dec, expected_ra, expected_dec, x, y;
                wcs_tan_reference(points[i][0], points[i][1], &expected_ra, &expected_dec);
                CHECK(siril_image_pixel_to_sky(image, points[i][0], points[i][1], &ra, &dec));
                CHECK(fabs(remainder(ra - expected_ra, 360)) < 1e-9 && fabs(dec - expected_dec) < 1e-9);
                CHECK(ra >= 0 && ra < 360);
                CHECK(siril_image_sky_to_pixel(image, ra - 720, dec, &x, &y));
                CHECK(fabs(x - points[i][0]) < 1e-6 && fabs(y - points[i][1]) < 1e-6);
            }
            double ra, dec;
            CHECK(!siril_image_pixel_to_sky(image, NAN, 0, &ra, &dec) && isnan(ra) && isnan(dec));
            CHECK(!siril_image_sky_to_pixel(image, 0, 91, &ra, &dec) && isnan(ra) && isnan(dec));
            CHECK(!siril_image_sky_to_pixel(image, INFINITY, 0, &ra, &dec) && isnan(ra) && isnan(dec));
            CHECK(!siril_image_sky_to_pixel(image, 179.9998, 20.4, &ra, &dec) && isnan(ra) && isnan(dec));
            for (int y = 0; y < 5; y++) for (int x = 0; x < 7; x++) {
                float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == 1);
                CHECK(fabs(pixel[0] - (1000 + (4 - y) * 7 + x) / 65535.) < 1e-7);
            }
        } else {
            double a = 1, b = 1;
            CHECK(!siril_image_pixel_to_sky(image, .5, .5, &a, &b) && isnan(a) && isnan(b));
            CHECK(!siril_image_sky_to_pixel(image, 0, 0, &a, &b) && isnan(a) && isnan(b));
        }
        siril_image_free(image);
        bytes = fopen(path, "rb"); CHECK(bytes);
        CHECK(fread(after, 1, sizeof after, bytes) == sizeof after && fgetc(bytes) == EOF); fclose(bytes);
        CHECK(!memcmp(before, after, sizeof before));
    }
    puts("PASS: image WCS matched independent skewed TAN projection, pixel-centre/display row mapping, RA wrap and off-image inverse; invalid/absent/non-equatorial coordinates rejected and source bytes/pixels preserved");
    return 0;
}
