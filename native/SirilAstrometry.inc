// SPDX-License-Identifier: GPL-3.0-or-later
#include "algos/PSF.h"
#include "algos/photometry.h"
#include "algos/star_finder.h"
#include "algos/siril_wcs.h"

const char *siril_psf_error_message(int code) { return code >= 0 && code < PSF_ERR_MAX_VALUE ? psf_error_to_string((psf_error)code) : "Sequence worker did not retain the per-frame error code"; }

static int native_star_settings(const SirilStarFinder *input, fits *fit, star_finder_params *sf) {
    if (!input || !fit || input->channel < 0 || input->channel >= fit->naxes[2] ||
        input->profile < 0 || input->profile > 1 || input->convergence < 1 || input->convergence > 3 ||
        input->radius < 3 || input->radius > 50 || input->maximum < 1 || input->maximum > 10000) return 0;
    const double values[] = {input->sigma, input->minimum_roundness, input->maximum_roundness,
        input->minimum_beta, input->minimum_amplitude, input->maximum_amplitude, input->focal_length, input->pixel_size};
    for (size_t i = 0; i < G_N_ELEMENTS(values); i++) if (!isfinite(values[i])) return 0;
    if (input->sigma < .01 || input->sigma > 15 || input->minimum_roundness < 0 || input->minimum_roundness > .95 ||
        input->maximum_roundness < input->minimum_roundness || input->maximum_roundness > 1 ||
        input->minimum_beta < 0 || input->minimum_beta > 10 || input->minimum_amplitude < 0 || input->minimum_amplitude >= 1 ||
        input->maximum_amplitude < 0 || input->maximum_amplitude > 1 ||
        (input->maximum_amplitude != 0 && input->minimum_amplitude >= input->maximum_amplitude) ||
        input->focal_length < 0 || input->pixel_size < 0) return 0;
    *sf = com.pref.starfinder_conf;
    sf->radius = input->radius; sf->sigma = input->sigma;
    sf->roundness = input->minimum_roundness; sf->max_r = input->maximum_roundness;
    sf->min_beta = input->minimum_beta; sf->min_A = input->minimum_amplitude; sf->max_A = input->maximum_amplitude;
    sf->convergence = input->convergence; sf->relax_checks = !!input->relax;
    sf->profile = input->profile; sf->focal_length = input->focal_length; sf->pixel_size_x = input->pixel_size;
    return 1;
}
static void native_star_measurement(fits *fit, psf_star *star, SirilStarMeasurement *out, int phot_error) {
    fwhm_to_arcsec_if_needed(fit, star);
    double ra = 9.99E9, dec = 9.99E9;
    if (has_wcs(fit)) {
        double x, y;
        display_to_siril(star->xpos, star->ypos, &x, &y, fit->ry);
        pix2wcs2(fit->keywords.wcslib, x, y, &ra, &dec);
    }
    *out = (SirilStarMeasurement){ .channel = star->layer, .profile = star->profile,
        .saturated = star->has_saturated, .photometry_valid = star->phot_is_valid,
        .photometry_error = phot_error, .x = star->xpos,
        .y = fit->top_down ? fit->ry - star->ypos : star->ypos,
        .background = star->B, .amplitude = star->A, .fwhm_x = star->fwhmx, .fwhm_y = star->fwhmy,
        .angular_x = star->fwhmx_arcsec, .angular_y = star->fwhmy_arcsec, .angle = -star->angle,
        .beta = star->beta, .rmse = star->rmse, .magnitude = star->mag,
        .magnitude_error = star->s_mag, .snr = star->SNR, .ra = ra, .dec = dec };
}
static int native_phot_configure(const SirilPhotometry *photometry) {
        const double p[] = {photometry->gain, photometry->inner, photometry->outer, photometry->aperture,
            photometry->aperture_factor, photometry->minimum, photometry->maximum};
        for (size_t i = 0; i < G_N_ELEMENTS(p); i++) if (!isfinite(p[i])) return 0;
        if (photometry->gain <= 0 || photometry->gain > 10 || photometry->inner < 2 || photometry->inner > 100 ||
            photometry->outer <= photometry->inner || photometry->outer > 200 ||
            photometry->aperture < 1 || photometry->aperture > 100 ||
            (photometry->force_radius && photometry->aperture >= photometry->inner) ||
            photometry->aperture_factor < 1 || photometry->aperture_factor > 5 ||
            photometry->minimum < -65536 || photometry->maximum > 65535 || photometry->maximum <= photometry->minimum) return 0;
        com.pref.phot_set.gain = photometry->gain; com.pref.phot_set.inner = photometry->inner;
        com.pref.phot_set.outer = photometry->outer; com.pref.phot_set.aperture = photometry->aperture;
        com.pref.phot_set.auto_aperture_factor = photometry->aperture_factor;
        com.pref.phot_set.force_radius = !!photometry->force_radius;
        com.pref.phot_set.minval = photometry->minimum; com.pref.phot_set.maxval = photometry->maximum;
    return 1;
}

int siril_image_fit_star(SirilImage *image, const SirilRegion *region, const SirilStarFinder *finder,
        const SirilPhotometry *photometry, SirilStarMeasurement *result, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!image || !region || !result || !photometry) return 0;
    int ok = 0; psf_star *star = NULL; struct phot_config *phot = NULL;
    g_mutex_lock(&engine_mutex); initialize();
    fits *fit = &image->fit; rectangle area; star_finder_params sf;
    star_finder_params old_finder = com.pref.starfinder_conf;
    struct phot_config old_phot = com.pref.phot_set;
    if (!native_star_settings(finder, fit, &sf) || !displayed_region(fit, region, &area) || area.w < 5 || area.h < 5) goto end;
    // GSL allocates several double matrices; reject before entering its original allocator.
    if ((double)area.w * area.h * 8 * 12 > (double)get_available_memory() * .8) goto end;
    com.pref.starfinder_conf = sf;
    if (photometry->enabled) {
        if (!native_phot_configure(photometry)) goto end;
        phot = phot_set_adjusted_for_image(fit);
        if (!phot) goto end;
    }
    psf_error code = PSF_NO_ERR;
    star = psf_get_minimisation(fit, finder->channel, &area, !!photometry->enabled, FALSE, phot, TRUE, sf.profile, &code);
    if (!star || code == PSF_ERR_DIVERGED) {
        if (error && capacity) snprintf(error, capacity, "%s", psf_error_to_string(code));
        goto end;
    }
    // Same coordinates as format_psf_result; fitter uses pixel centres, not indices.
    star->xpos = area.x + star->x0; star->ypos = area.y + area.h - star->y0;
    star->has_saturated = star->A + star->B >= (fit->type == DATA_FLOAT ? 1 : 65535);
    native_star_measurement(fit, star, result, code); ok = 1;
end:
    free(phot); if (star) free_psf(star);
    com.pref.starfinder_conf = old_finder; com.pref.phot_set = old_phot;
    if (!ok && error && capacity && !error[0]) snprintf(error, capacity, "Invalid PSF region, parameters or insufficient memory");
    g_mutex_unlock(&engine_mutex); return ok;
}
int siril_image_find_stars(SirilImage *source, const SirilRegion *region, const SirilStarFinder *finder,
        SirilStarMeasurement *results, size_t capacity, char *error, size_t error_size) {
    if (error && error_size) error[0] = 0;
    if (!source || !results || !finder || capacity < (size_t)finder->maximum) return -1;
    g_mutex_lock(&engine_mutex); initialize();
    int count = -1; fits green = {0}; psf_star **stars = NULL;
    fits *fit = &source->fit; rectangle area; star_finder_params sf;
    star_finder_params old = com.pref.starfinder_conf;
    if (!native_star_settings(finder, fit, &sf) || !displayed_region(fit, region, &area)) goto end;
    if ((double)fit->rx * fit->ry * sizeof(float) * 4 > (double)get_available_memory() * .8) goto end;
    com.pref.starfinder_conf = sf;
    fits *input = fit;
    if (fit_is_cfa(fit)) {
        if (copyfits(fit, &green, CP_ALLOC | CP_COPYA | CP_FORMAT, -1)) goto end;
        interpolate_nongreen(&green); input = &green;
    }
    image im = {.fit = input}; int n = 0;
    stars = peaker(&im, finder->channel, &sf, &n, region ? &area : NULL, FALSE, TRUE, finder->maximum, sf.profile, 1);
    count = n;
    for (int i = 0; stars && i < n; i++) native_star_measurement(fit, stars[i], &results[i], 0);
end:
    if (stars) free_fitted_stars(stars); clearfits(&green); com.pref.starfinder_conf = old;
    if (count < 0 && error && error_size) snprintf(error, error_size, "Invalid star detection parameters or insufficient memory");
    g_mutex_unlock(&engine_mutex); return count;
}
int siril_image_save_stars(SirilImage *image, const char *path, int fits_table, const SirilStarFinder *finder,
        const SirilStarMeasurement *results, size_t count, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!image || !path || !results || count < 1 || count > 10000 || g_file_test(path, G_FILE_TEST_EXISTS)) return 0;
    g_mutex_lock(&engine_mutex); initialize();
    int ok = 0; star_finder_params sf; psf_star **stars = NULL;
    if (!native_star_settings(finder, &image->fit, &sf)) goto end;
    stars = new_fitted_stars(count); if (!stars) goto end;
    memset(stars, 0, (count + 1) * sizeof(*stars));
    for (size_t i = 0; i < count; i++) {
        const SirilStarMeasurement *r = &results[i]; psf_star *s = new_psf_star();
        if (!s) goto end; stars[i] = s;
        s->layer = r->channel; s->profile = r->profile; s->B = r->background; s->A = r->amplitude;
        s->xpos = r->x; s->ypos = image->fit.top_down ? image->fit.ry - r->y : r->y;
        s->fwhmx = r->fwhm_x; s->fwhmy = r->fwhm_y; s->fwhmx_arcsec = r->angular_x; s->fwhmy_arcsec = r->angular_y;
        s->angle = -r->angle; s->beta = r->beta; s->rmse = r->rmse; s->mag = r->magnitude;
        s->has_saturated = r->saturated; s->ra = r->ra; s->dec = r->dec;
    }
    // Upstream .lst adds global calibration offset; native state stores instrumental magnitudes.
    double old_offset = com.magOffset; com.magOffset = 0;
    ok = fits_table ? !save_list_as_FITS_table(path, stars, (int)count, image->fit.rx, image->fit.ry) :
        !save_list((gchar *)path, finder->maximum, stars, (int)count, &sf, finder->channel, TRUE);
    com.magOffset = old_offset;
end:
    if (stars) free_fitted_stars(stars);
    if (!ok && error && capacity) snprintf(error, capacity, "Cannot save original Siril star table");
    g_mutex_unlock(&engine_mutex); return ok;
}

struct native_sequence_photometry {
    sequence *seq;
    int layer, framing;
    const SirilRegion *regions;
    size_t stars;
};
static gpointer native_sequence_photometry_worker(gpointer opaque) {
    struct native_sequence_photometry *args = opaque;
    int status = 0;
    for (size_t i = 0; i < args->stars; i++) {
        const SirilRegion *r = &args->regions[i];
        com.selection = (rectangle){.x = r->x, .y = r->y, .w = r->width, .h = r->height};
        if (seqpsf(args->seq, args->layer, FALSE, FALSE, FALSE, args->framing, FALSE, TRUE) ||
            g_atomic_int_get(&cancel_requested)) { status = 1; break; }
    }
    stop_processing_thread(); return GINT_TO_POINTER(status);
}
int siril_sequence_photometry(const char *directory, const char *name, int current, int framing,
        const SirilRegion *regions, size_t stars, const SirilStarFinder *finder, const SirilPhotometry *photometry,
        const char *curve_path, SirilStarMeasurement *results, size_t count, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (!regions || !results || !photometry || !photometry->enabled || stars < 1 || stars > MAX_SEQPSF || framing < 0 || framing > 2 ||
        (curve_path && (stars < 2 || g_file_test(curve_path, G_FILE_TEST_EXISTS)))) return 0;
    g_mutex_lock(&engine_mutex); initialize();
    g_atomic_int_set(&cancel_requested, 0);
    g_mutex_lock(&log_mutex); if (processing_log) g_string_truncate(processing_log, 0); g_mutex_unlock(&log_mutex);
    int ok = 0; fits metadata = {0}; sequence *seq = embedded_sequence(directory, name, error, capacity);
    star_finder_params old_finder = com.pref.starfinder_conf, sf;
    struct phot_config old_phot = com.pref.phot_set;
    rectangle old_selection = com.selection;
    if (!seq) goto end;
    if (current < 0 || current >= seq->number || !seq->imgparam[current].incl ||
        count != stars * (size_t)seq->number || seq_read_frame_metadata(seq, current, &metadata) ||
        !native_star_settings(finder, &metadata, &sf) || !native_phot_configure(photometry)) goto end;
    for (size_t i = 0; i < stars; i++) {
        const SirilRegion *r = &regions[i];
        if (r->x < 0 || r->y < 0 || r->width < 5 || r->height < 5 || r->x > seq->rx - r->width || r->y > seq->ry - r->height ||
            (double)r->width * r->height * 8 * 12 > (double)get_available_memory() * .8) goto end;
    }
    memset(results, 0, count * sizeof(*results));
    seq->current = current; com.pref.starfinder_conf = sf;
    struct native_sequence_photometry args = {.seq = seq, .layer = finder->channel, .framing = framing, .regions = regions, .stars = stars};
    waiting_for_thread();
    if (!start_in_new_thread(native_sequence_photometry_worker, &args) ||
        GPOINTER_TO_INT(waiting_for_thread()) || g_atomic_int_get(&cancel_requested)) goto end;
    for (size_t s = 0; s < stars; s++) {
        if (!seq->photometry[s]) goto end;
        for (int i = 0; i < seq->number; i++) if (seq->photometry[s][i]) {
            psf_star *psf = seq->photometry[s][i];
            psf->layer = finder->channel;
            native_star_measurement(&metadata, psf, &results[s * seq->number + i], psf->phot_is_valid ? 0 : -1);
        }
    }
    if (curve_path) {
        struct light_curve_args lc = {.seq = seq, .nb = (int)stars, .layer = finder->channel,
            .target_descr = "Siril iPad", .display_graph = TRUE, .force_rad = !!photometry->force_radius};
        // Request original plot data but render with native charts; avoid desktop cairo PNG generation.
        int code = new_light_curve(curve_path, &lc);
        if (lc.spl_data) free_siril_plot_data(lc.spl_data);
        if (code) goto end;
    }
    ok = 1;
end:
    clearfits(&metadata); if (seq) free_sequence(seq, TRUE);
    com.pref.starfinder_conf = old_finder; com.pref.phot_set = old_phot; com.selection = old_selection;
    if (!ok && error && capacity && !error[0]) snprintf(error, capacity, "Original sequence PSF/light curve failed, invalid parameters or cancellation");
    g_mutex_unlock(&engine_mutex); return ok;
}
