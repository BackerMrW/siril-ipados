// SPDX-License-Identifier: GPL-3.0-or-later
static int keyword_reference_checks(SirilImage *original, const char *directory) {
    char error[512], output[4096];
    size_t length = siril_image_copy_header(original, NULL, 0);
    char *before = malloc(length), *after = malloc(length); CHECK(before && after);
    CHECK(siril_image_copy_header(original, before, length) == length);
    SirilImage *edited = siril_image_edit_keyword(original, 0, "OBJECT", "O'Brien target", "Known target", 1, error, sizeof error); CHECK(edited);
    SirilImage *next = siril_image_edit_keyword(edited, 0, "EXPTIME", "42.5", "Seconds", 0, error, sizeof error); CHECK(next);
    siril_image_free(edited); edited = next;
    next = siril_image_edit_keyword(edited, 0, "TARGNUM", "17", "Reference", 0, error, sizeof error); CHECK(next);
    siril_image_free(edited); edited = next;
    next = siril_image_edit_keyword(edited, 2, "TARGNUM", "TARGID", NULL, 0, error, sizeof error); CHECK(next);
    siril_image_free(edited); edited = next;
    next = siril_image_edit_keyword(edited, 3, NULL, NULL, "Independent keyword comment", 0, error, sizeof error); CHECK(next);
    siril_image_free(edited); edited = next;
    CHECK(!siril_image_edit_keyword(edited, 0, "BITPIX", "16", NULL, 0, error, sizeof error));
    CHECK(!siril_image_edit_keyword(edited, 0, "CRVAL1", "120", NULL, 0, error, sizeof error));
    CHECK(!siril_image_edit_keyword(edited, 2, "TARGID", "NAXIS1", NULL, 0, error, sizeof error));
    CHECK(!siril_image_edit_keyword(edited, 1, "NOEXIST", NULL, NULL, 0, error, sizeof error));
    CHECK(!siril_image_edit_keyword(edited, 0, "BAD KEY", "1", NULL, 0, error, sizeof error));
    CHECK(!siril_image_edit_keyword(edited, 0, "TEST", "line\nbreak", NULL, 1, error, sizeof error));
    CHECK(siril_image_copy_header(original, after, length) == length && !memcmp(before, after, length));
    free(before); free(after);
    SirilImageInfo info; CHECK(siril_image_info(edited, &info));
    CHECK(fabs(info.exposure - 42.5) < 1e-9 && !strcmp(info.object, "O'Brien target"));
    for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
        float a[3], b[3]; CHECK(siril_image_pixel(original, x, y, a) == 1 && siril_image_pixel(edited, x, y, b) == 1);
        CHECK(a[0] == b[0]);
    }
    snprintf(output, sizeof output, "%s/keywords-edited.fits", directory); CHECK(siril_image_write(edited, output));
    fitsfile *file = NULL; int status = 0, identifier = 0; double exposure = 0; char text[FLEN_VALUE];
    fits_open_file(&file, output, READONLY, &status);
    fits_read_key(file, TINT, "TARGID", &identifier, NULL, &status);
    fits_read_key(file, TDOUBLE, "EXPTIME", &exposure, NULL, &status);
    fits_read_key(file, TSTRING, "OBJECT", text, NULL, &status);
    fits_close_file(file, &status);
    CHECK(!status && identifier == 17 && exposure == 42.5 && !strcmp(text, "O'Brien target"));
    next = siril_image_edit_keyword(edited, 1, "TARGID", NULL, NULL, 0, error, sizeof error); CHECK(next);
    siril_image_free(edited); edited = next;
    snprintf(output, sizeof output, "%s/keywords-deleted.fits", directory); CHECK(siril_image_write(edited, output));
    fits_open_file(&file, output, READONLY, &status); fits_read_key(file, TINT, "TARGID", &identifier, NULL, &status);
    CHECK(status == KEY_NO_EXIST); status = 0; fits_close_file(file, &status); CHECK(!status);
    siril_image_free(edited);
    puts("PASS: original FITS keyword set/rename/delete/comment preserved exact source pixels/header; independent CFITSIO verified quoted text, numeric values and known metadata; protected/invalid edits rejected");
    return 0;
}
