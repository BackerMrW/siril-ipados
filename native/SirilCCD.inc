// SPDX-License-Identifier: GPL-3.0-or-later
#include "algos/ccd-inspector.h"
extern int siril_ipados_tilt_values(fits *, int, psf_star **, float[7], sensor_tilt *);
extern int siril_ipados_tilt_polygon(int, int, const float[7], sensor_tilt *);
static int native_tilt_result(int width, int height, int channel, int stars,
        const float values[7], const sensor_tilt *polygon, SirilSensorTilt *result) {
    result->stars = stars; result->channel = channel; result->width = width; result->height = height;
    result->mean = values[0]; result->centre = values[5]; result->outer = values[6];
    float best = values[1], worst = values[1];
    float reference = (values[1] + values[2] + values[3] + values[4]) / 4.f;
    for (int i = 0; i < 4; i++) {
        result->quadrant[i] = values[i + 1];
        best = fminf(best, values[i + 1]); worst = fmaxf(worst, values[i + 1]);
        result->x[i] = polygon->pt[i].x; result->y[i] = polygon->pt[i].y;
    }
    if (!(reference > 0)) return 0;
    result->difference = worst - best; result->percent = roundf((worst - best) / reference * 100.f);
    result->off_axis = values[6] - values[5]; return 1;
}
int siril_sensor_tilt_average(const SirilSensorTilt *frames, size_t count, SirilSensorTilt *result) {
    if (!frames || !result || !count || count > INT32_MAX) return 0;
    float sums[7] = {0}; int64_t stars = 0;
    for (size_t i = 0; i < count; i++) {
        const SirilSensorTilt *frame = &frames[i];
        if (frame->width <= 0 || frame->height <= 0 || frame->stars <= 0 || frame->channel < 0 || frame->channel > 2 ||
                frame->width != frames[0].width || frame->height != frames[0].height || frame->channel != frames[0].channel) return 0;
        const double values[] = {frame->mean, frame->quadrant[0], frame->quadrant[1], frame->quadrant[2], frame->quadrant[3], frame->centre, frame->outer};
        for (int k = 0; k < 7; k++) {
            if (!isfinite(values[k]) || values[k] <= 0) return 0;
            sums[k] += (float)values[k];
            if (!isfinite(sums[k])) return 0;
        }
        stars += frame->stars;
    }
    for (int k = 0; k < 7; k++) sums[k] /= (float)count;
    g_mutex_lock(&engine_mutex); initialize();
    sensor_tilt polygon; SirilSensorTilt averaged = {0};
    int ok = siril_ipados_tilt_polygon(frames[0].width, frames[0].height, sums, &polygon) &&
        native_tilt_result(frames[0].width, frames[0].height, frames[0].channel, (int)(stars / count), sums, &polygon, &averaged);
    if (ok) *result = averaged;
    g_mutex_unlock(&engine_mutex); return ok;
}
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
    ok = native_tilt_result(fit->rx, fit->ry, finder->channel, n, values, &polygon, result);
done:
    if (stars) free_fitted_stars(stars);
    clearfits(&green); com.pref.starfinder_conf = previous;
    if (!ok && error && capacity) snprintf(error, capacity, "%s", reason);
    g_mutex_unlock(&engine_mutex); return ok;
}
