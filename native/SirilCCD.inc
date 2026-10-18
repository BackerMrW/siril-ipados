// SPDX-License-Identifier: GPL-3.0-or-later
#include "algos/ccd-inspector.h"
extern int siril_ipados_tilt_values(fits *, int, psf_star **, float[7], sensor_tilt *);
int siril_image_sensor_tilt(SirilImage *source, const SirilStarFinder *finder,
        SirilSensorTilt *result, char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    if (result) memset(result, 0, sizeof *result);
    if (!source || !finder || !result) return 0;
    g_mutex_lock(&engine_mutex); initialize();
    int ok = 0, n = 0; fits green = {0}; psf_star **stars = NULL;
    const char *reason = "Tilt analysis needs valid stars in every quadrant, the central 25% radius and the outer 75% radius";
    fits *fit = &source->fit; star_finder_params sf;
    star_finder_params previous = com.pref.starfinder_conf;
    if (!native_star_settings(finder, fit, &sf)) { reason = "Invalid star detection parameters"; goto done; }
    if ((double)fit->rx * fit->ry * sizeof(float) * 4 > (double)get_available_memory() * .8) {
        reason = "Frame exceeds the available analysis memory budget"; goto done;
    }
    com.pref.starfinder_conf = sf;
    fits *input = fit;
    if (fit_is_cfa(fit)) {
        if (copyfits(fit, &green, CP_ALLOC | CP_COPYA | CP_FORMAT, -1)) goto done;
        interpolate_nongreen(&green); input = &green;
    }
    image im = {.fit = input};
    stars = peaker(&im, finder->channel, &sf, &n, NULL, FALSE, TRUE, finder->maximum, sf.profile, 1);
    if (!stars || !n) goto done;
    // Original PSF coordinates follow row orientation; report displayed zones.
    if (fit->top_down) for (int i = 0; i < n; i++) stars[i]->ypos = fit->ry - stars[i]->ypos;
    float values[7]; sensor_tilt polygon;
    if (!siril_ipados_tilt_values(fit, n, stars, values, &polygon)) goto done;
    result->stars = n; result->channel = finder->channel; result->width = fit->rx; result->height = fit->ry;
    result->mean = values[0]; result->centre = values[5]; result->outer = values[6];
    float best = values[1], worst = values[1];
    float reference = (values[1] + values[2] + values[3] + values[4]) / 4.f;
    for (int i = 0; i < 4; i++) {
        result->quadrant[i] = values[i + 1];
        best = fminf(best, values[i + 1]); worst = fmaxf(worst, values[i + 1]);
        result->x[i] = polygon.pt[i].x; result->y[i] = polygon.pt[i].y;
    }
    if (!(reference > 0)) goto done;
    result->difference = worst - best; result->percent = roundf((worst - best) / reference * 100.f);
    result->off_axis = values[6] - values[5]; ok = 1;
done:
    if (stars) free_fitted_stars(stars);
    clearfits(&green); com.pref.starfinder_conf = previous;
    if (!ok && error && capacity) snprintf(error, capacity, "%s", reason);
    g_mutex_unlock(&engine_mutex); return ok;
}
