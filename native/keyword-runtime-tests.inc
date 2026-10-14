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
    char sequence_dir[4096]; snprintf(sequence_dir, sizeof sequence_dir, "%s/keyword-sequence", directory);
    CHECK(!g_mkdir_with_parents(sequence_dir, 0700));
    for (int i = 1; i <= 3; i++) {
        snprintf(output, sizeof output, "%s/k_%05d.fts", sequence_dir, i);
        CHECK(siril_image_write(original, output));
    }
    CHECK(siril_sequence_discover(sequence_dir, error, sizeof error));
    const uint8_t flags[3] = {1, 0, 1};
    CHECK(siril_sequence_select(sequence_dir, "k_.seq", flags, 3, 2, error, sizeof error));
    CHECK(siril_sequence_edit_keyword(sequence_dir, "k_.seq", 0, "TARGNUM", "42.5", NULL, 0, error, sizeof error));
    CHECK(siril_sequence_edit_keyword(sequence_dir, "k_.seq", 2, "TARGNUM", "TARGID", NULL, 0, error, sizeof error));
    CHECK(siril_sequence_edit_keyword(sequence_dir, "k_.seq", 0, "OBJECT", "O'Brien sequence", NULL, 1, error, sizeof error));
    CHECK(siril_sequence_edit_keyword(sequence_dir, "k_.seq", 3, NULL, NULL, "Sequence keyword check", 0, error, sizeof error));
    SirilSequenceInfo sequence_info; SirilSequenceFrame frames[3];
    CHECK(siril_sequence_inspect(sequence_dir, "k_.seq", 0, &sequence_info, frames, 3, error, sizeof error) == 3);
    CHECK(sequence_info.included == 2 && sequence_info.reference == 2 && !frames[1].included);
    for (int i = 1; i <= 3; i++) {
        snprintf(output, sizeof output, "%s/k_%05d.fts", sequence_dir, i);
        status = 0; double number = 0; file = NULL;
        fits_open_file(&file, output, READONLY, &status);
        fits_read_key(file, TDOUBLE, "TARGID", &number, NULL, &status);
        if (i == 2) { CHECK(status == KEY_NO_EXIST); status = 0; }
        else { CHECK(!status && number == 42.5); fits_read_key(file, TSTRING, "OBJECT", text, NULL, &status); CHECK(!status && !strcmp(text, "O'Brien sequence")); }
        fits_close_file(file, &status); CHECK(!status);
        SirilImage *frame = siril_sequence_frame(sequence_dir, "k_.seq", i - 1, error, sizeof error); CHECK(frame);
        for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
            float a[3], b[3]; CHECK(siril_image_pixel(original, x, y, a) == 1 && siril_image_pixel(frame, x, y, b) == 1 && a[0] == b[0]);
        }
        siril_image_free(frame);
    }
    CHECK(!siril_sequence_edit_keyword(sequence_dir, "k_.seq", 0, "BITPIX", "16", NULL, 0, error, sizeof error));
    CHECK(!siril_sequence_edit_keyword(sequence_dir, "k_.seq", 1, "NOEXIST", NULL, NULL, 0, error, sizeof error));
    CHECK(siril_sequence_edit_keyword(sequence_dir, "k_.seq", 1, "TARGID", NULL, NULL, 0, error, sizeof error));
    snprintf(output, sizeof output, "%s/k_%05d.fts", sequence_dir, 1);
    status = 0; file = NULL; fits_open_file(&file, output, READONLY, &status);
    fits_read_key(file, TINT, "TARGID", &identifier, NULL, &status); CHECK(status == KEY_NO_EXIST);
    status = 0; fits_close_file(file, &status); CHECK(!status);
    file = NULL; fits_open_file(&file, output, READWRITE, &status);
    double one_only = 7;
    fits_update_key(file, TDOUBLE, "ONEONLY", &one_only, NULL, &status);
    fits_close_file(file, &status); CHECK(!status);
    CHECK(!siril_sequence_edit_keyword(sequence_dir, "k_.seq", 1, "ONEONLY", NULL, NULL, 0, error, sizeof error));
    status = 0; file = NULL; fits_open_file(&file, output, READONLY, &status);
    fits_read_key(file, TDOUBLE, "ONEONLY", &one_only, NULL, &status); CHECK(status == KEY_NO_EXIST);
    status = 0; fits_close_file(file, &status); CHECK(!status);
    CHECK(!chmod(sequence_dir, 0500));
    int write_ok = siril_sequence_edit_keyword(sequence_dir, "k_.seq", 0, "WRITECHK", "1", NULL, 0, error, sizeof error);
    CHECK(!chmod(sequence_dir, 0700));
    CHECK(!write_ok);
    puts("PASS: original selected-frame sequence keyword worker kept .fts filenames, exact pixels, excluded frames and reference; independent CFITSIO verified all operations; partial edits and failed writes returned failure");
    puts("PASS: original FITS keyword set/rename/delete/comment preserved exact source pixels/header; independent CFITSIO verified quoted text, numeric values and known metadata; protected/invalid edits rejected");
    return 0;
}
