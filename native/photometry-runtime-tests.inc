// SPDX-License-Identifier: GPL-3.0-or-later
static int photometric_numeric_checks(void) {
    fits *fit = NULL;
    CHECK(new_fit_image(&fit, 4, 3, 3, DATA_FLOAT) == 0 && fit);
    // Three distinct backgrounds with the same object signal. After applying
    // inverse gains, each channel must carry the same signal over a neutral sky.
    const float background[] = {.02f, .04f, .06f};
    const float gain[] = {1.f, 2.f, 4.f}, correction[] = {1.f, .5f, .25f};
    for (int c = 0; c < 3; c++) for (int i = 0; i < 12; i++)
        fit->fpdata[c][i] = background[c] + gain[c] * (.01f + i * .002f);
    CHECK(apply_photometric_color_correction(fit, correction, background) == 0);
    for (int c = 0; c < 3; c++) for (int i = 0; i < 12; i++)
        CHECK(fabs(fit->fpdata[c][i] - (.05 + i * .002)) < 1e-7);
    float before[36]; memcpy(before, fit->fdata, sizeof before);
    const float invalid[] = {1.f, NAN, 1.f};
    CHECK(apply_photometric_color_correction(fit, invalid, background) != 0);
    CHECK(memcmp(before, fit->fdata, sizeof before) == 0);
    clearfits(fit); free(fit);
    puts("PASS: original PCC/SPCC correction recovered known inverse channel gains and neutral sky; invalid coefficients left every pixel unchanged");

    // Closed-form linear spectrum: interpolation and integration have an
    // independent analytic answer rather than another call to the same worker.
    double wavelengths[] = {300, 400, 500, 600, 800, 1100};
    double response[6];
    for (int i = 0; i < 6; i++) response[i] = .5 + wavelengths[i] / 1000;
    spcc_object source = {.x = wavelengths, .y = response, .n = 6};
    xpsampled sampled = init_xpsampled();
    init_xpsampled_from_library(&sampled, &source);
    for (int i = 0; i < XPSAMPLED_LEN; i++)
        CHECK(fabs(sampled.y[i] - (.5 + sampled.x[i] / 1000)) < 1e-12);
    const double lo = 410.5, hi = 691.25;
    double integral = .5 * (hi - lo) + (hi * hi - lo * lo) / 2000;
    CHECK(fabs(integrate_xpsampled(&sampled, lo, hi) - integral) < 1e-9);
    xpsampled constant = init_xpsampled(), product = init_xpsampled();
    for (int i = 0; i < XPSAMPLED_LEN; i++) constant.y[i] = 2;
    multiply_xpsampled(&product, &sampled, &constant);
    CHECK(fabs(integrate_xpsampled(&product, lo, hi) - 2 * integral) < 1e-9);
    // Equal energy flux has photon count proportional to wavelength.
    flux_to_relcount(&constant);
    CHECK(fabs(constant.y[132] / constant.y[32] - 600. / 400.) < 1e-12);
    puts("PASS: original SPCC resampling/integration matched analytic linear spectra, filter multiplication and physical photon-count ratios");
    return 0;
}

static gpointer pcc_reference_worker(gpointer data) {
    int result = photometric_cc(data);
    stop_processing_thread();
    return GINT_TO_POINTER(result);
}

static double power_band_flux(double center, double exponent) {
    return (pow(center + 5, exponent + 1) - pow(center - 5, exponent + 1)) / (exponent + 1);
}
static int pcc_star_field(const char *path, const double gain[3], int spectral) {
    const int side = 256;
    float *pixels = calloc((size_t)side * side * 3, sizeof(float)); CHECK(pixels);
    for (int c = 0; c < 3; c++) for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) {
        double signal = .00003 * sin(x * 1.3 + y * .7);
        for (int i = 0; i < 25; i++) {
            double dx = x - (36 + (i % 5) * 45), dy = y - (36 + (i / 5) * 45);
            const double center[] = {650, 550, 450};
            double color = spectral ? power_band_flux(center[c], -.8 + i * .08) / power_band_flux(550, -.8 + i * .08) : 1;
            signal += color * (.08 + .003 * i) * exp(-(dx * dx + dy * dy) / (2 * 1.8 * 1.8));
        }
        pixels[(size_t)c * side * side + y * side + x] = .02 * (c + 1) + gain[c] * signal;
    }
    fitsfile *file = NULL; int status = 0; long axes[] = {side, side, 3};
    fits_create_file(&file, path, &status); fits_create_img(file, FLOAT_IMG, 3, axes, &status);
    fits_update_key(file, TSTRING, "CTYPE1", "RA---TAN", NULL, &status);
    fits_update_key(file, TSTRING, "CTYPE2", "DEC--TAN", NULL, &status);
    const char *keys[] = {"CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CDELT1", "CDELT2"};
    double values[] = {120, 20, 128, 128, -2. / 3600, 2. / 3600};
    for (int i = 0; i < 6; i++) fits_update_key(file, TDOUBLE, keys[i], &values[i], NULL, &status);
    fits_write_img(file, TFLOAT, 1, (long)side * side * 3, pixels, &status);
    fits_close_file(file, &status); free(pixels); CHECK(status == 0);
    return 0;
}

static int pcc_worker_reference(const char *directory) {
    double colors[2][25][3];
    const double gains[2][3] = {{1, 1, 1}, {.5, 1, 1.5}};
    for (int run = 0; run < 2; run++) {
        char path[4096]; snprintf(path, sizeof path, "%s/pcc-reference-%d.fits", directory, run);
        CHECK(pcc_star_field(path, gains[run], 0) == 0);
        fits fit = {0}; CHECK(readfits(path, &fit, NULL, TRUE) == 0 && has_wcs(&fit));
        struct photometric_cc_data args = {.fit = &fit, .bg_auto = TRUE, .nb_stars = 25,
            .fwhm = 4.238676f, .t0 = -2.8f, .t1 = 2.f};
        args.ref_stars = siril_catalog_new(CAT_SHOW); CHECK(args.ref_stars);
        args.ref_stars->nbitems = 25;
        args.ref_stars->cat_items = calloc(25, sizeof(cat_item)); CHECK(args.ref_stars->cat_items);
        for (int i = 0; i < 25; i++) {
            cat_item *star = &args.ref_stars->cat_items[i];
            star->x = 37 + (i % 5) * 45; star->y = 37 + (i / 5) * 45;
            star->teff = 5000 + i * 80; star->included = TRUE;
        }
        waiting_for_thread(); CHECK(start_in_new_thread(pcc_reference_worker, &args));
        CHECK(GPOINTER_TO_INT(waiting_for_thread()) == 0);
        float sky[3];
        for (int c = 0; c < 3; c++) sky[c] = fit.fpdata[c][10 * 256 + 10];
        CHECK(fabs(sky[0] - sky[1]) < 1e-4 && fabs(sky[2] - sky[1]) < 1e-4);
        for (int i = 0; i < 25; i++) {
            int x = 36 + (i % 5) * 45, y = 36 + (i / 5) * 45;
            double green = fit.fpdata[1][y * 256 + x] - sky[1]; CHECK(green > .01);
            for (int c = 0; c < 3; c++) colors[run][i][c] = (fit.fpdata[c][y * 256 + x] - sky[c]) / green;
        }
        siril_catalog_free(args.ref_stars); clearfits(&fit);
    }
    for (int i = 0; i < 25; i++) for (int c = 0; c < 3; c++)
        CHECK(fabs(colors[0][i][c] - colors[1][i][c]) < .002);
    puts("PASS: complete original PCC aperture-photometry worker recovered the same 25-star colors under independent channel gains and neutralized all backgrounds");
    return 0;
}

static int spcc_worker_reference(const char *directory) {
    char json[4096]; snprintf(json, sizeof json, "%s/spcc-flat-response.json", directory);
    FILE *metadata = fopen(json, "wb"); CHECK(metadata);
    const char *body = "{\"wavelength\":{\"value\":[300,400,500,600,800,1100],\"units\":\"nm\"},\"values\":{\"value\":[1,1,1,1,1,1],\"range\":1}}";
    CHECK(fwrite(body, 1, strlen(body), metadata) == strlen(body) && fclose(metadata) == 0);
    // Isolated analytic response and white reference, loaded by the original
    // JSON reader; restore the installed camera database after the test.
    spcc_object sensor = {.filepath = json, .name = "Independent flat sensor"};
    spcc_object white = {.filepath = json, .name = "Independent flat photon white"};
    GList *saved_sensors = com.spcc_data.mono_sensors, *saved_white = com.spcc_data.wb_ref;
    com.spcc_data.mono_sensors = g_list_append(NULL, &sensor);
    com.spcc_data.wb_ref = g_list_append(NULL, &white);
    const double gains[] = {.5, 1, 1.5}, center[] = {650, 550, 450};
    char path[4096]; snprintf(path, sizeof path, "%s/spcc-reference.fits", directory);
    CHECK(pcc_star_field(path, gains, 1) == 0);
    fits fit = {0}; CHECK(readfits(path, &fit, NULL, TRUE) == 0 && has_wcs(&fit));
    struct photometric_cc_data args = {.fit = &fit, .bg_auto = TRUE, .nb_stars = 25,
        .fwhm = 4.238676f, .t0 = -2.8f, .t1 = 2.f, .spcc = TRUE, .spcc_mono_sensor = TRUE,
        .nb_mode = TRUE, .nb_center = {650, 550, 450}, .nb_bandwidth = {10, 10, 10}};
    args.ref_stars = siril_catalog_new(CAT_SHOW); CHECK(args.ref_stars);
    args.ref_stars->nbitems = 25;
    args.ref_stars->cat_items = calloc(25, sizeof(cat_item)); CHECK(args.ref_stars->cat_items);
    xpsampled grid = init_xpsampled();
    for (int i = 0; i < 25; i++) {
        cat_item *star = &args.ref_stars->cat_items[i];
        star->x = 37 + (i % 5) * 45; star->y = 37 + (i / 5) * 45; star->included = TRUE;
        star->xp_sampled = calloc(XPSAMPLED_LEN, sizeof(double)); CHECK(star->xp_sampled);
        for (int j = 0; j < XPSAMPLED_LEN; j++)
            star->xp_sampled[j] = pow(grid.x[j] / 550, -.8 + i * .08) / grid.x[j];
    }
    waiting_for_thread(); CHECK(start_in_new_thread(pcc_reference_worker, &args));
    CHECK(GPOINTER_TO_INT(waiting_for_thread()) == 0);
    float sky[3]; for (int c = 0; c < 3; c++) sky[c] = fit.fpdata[c][10 * 256 + 10];
    CHECK(fabs(sky[0] - sky[1]) < 1e-4 && fabs(sky[2] - sky[1]) < 1e-4);
    for (int i = 0; i < 25; i++) {
        int x = 36 + (i % 5) * 45, y = 36 + (i / 5) * 45;
        double green = fit.fpdata[1][y * 256 + x] - sky[1]; CHECK(green > .01);
        for (int c = 0; c < 3; c++) {
            double actual = (fit.fpdata[c][y * 256 + x] - sky[c]) / green;
            double expected = power_band_flux(center[c], -.8 + i * .08) / power_band_flux(550, -.8 + i * .08);
            CHECK(fabs(actual - expected) < .002);
        }
    }
    siril_catalog_free(args.ref_stars); clearfits(&fit);
    spcc_object_free_arrays(&sensor); spcc_object_free_arrays(&white);
    g_list_free(com.spcc_data.mono_sensors); g_list_free(com.spcc_data.wb_ref);
    com.spcc_data.mono_sensors = saved_sensors; com.spcc_data.wb_ref = saved_white;
    puts("PASS: complete original SPCC photometry/regression/white-balance worker recovered analytic 25-star power-law photon colors through three narrow bands and known channel gains");
    return 0;
}
