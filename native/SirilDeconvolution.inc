// SPDX-License-Identifier: GPL-3.0-or-later
#include "filters/deconvolution/deconvolution.h"
#include "core/op_descriptors.h"
#include "algos/PSF.h"
static int deconv_worker(fits *fit, estk_data *data, const op_descriptor *op, int mask_aware) {
    struct generic_img_args *args = g_try_new0(struct generic_img_args, 1);
    if (!args) { free_estk_data(data); return 0; }
    args->fit = fit; args->op = op; args->user = data;
    args->command = TRUE; args->verbose = TRUE;
    args->mask_aware = mask_aware; args->max_threads = 1;
    if (!start_in_new_thread(generic_image_worker, args)) { free_generic_img_args(args); return 0; }
    return GPOINTER_TO_INT(waiting_for_thread()) == 0 && !g_atomic_int_get(&cancel_requested);
}
static int deconv_valid_kernel(void) {
    if (!com.kernel || com.kernelsize < 1 || (com.kernelchannels != 1 && com.kernelchannels != 3)) return 0;
    size_t n = (size_t)com.kernelsize * com.kernelsize;
    for (int c = 0; c < com.kernelchannels; c++) {
        double sum = 0;
        for (size_t i = 0; i < n; i++) {
            float v = com.kernel[c * n + i]; if (!isfinite(v)) return 0; sum += v;
        }
        if (!isfinite(sum) || sum <= 0) return 0;
    }
    return 1;
}
static int advanced_apply_deconv(SirilImage *image, yyjson_val *root) {
    yyjson_val *values = yyjson_obj_get(root, "values");
    estk_data *data = alloc_estk_data();
    if (!data) return 0;
    reset_conv_kernel(); reset_conv_args(data);
    data->fit = &image->fit; data->max_threads = 1;
    int ok = 0;
    double v, source, only, auto_size;
#define DC_READ(name, lo, hi) if (!advanced_number(values, name, lo, hi, &v)) goto done
#define DC_REAL(name, field, lo, hi) DC_READ(name, lo, hi); data->field = v
#define DC_INT(name, field, lo, hi) DC_READ(name, lo, hi); if (v != floor(v)) goto done; data->field = (int)v
    DC_READ("psfSource", 0, 3); source = v; if (v != floor(v)) goto done;
    DC_READ("estimateOnly", 0, 1); only = v; if (v != floor(v)) goto done;
    DC_READ("autoSize", 0, 1); auto_size = v; if (v != floor(v)) goto done;
    DC_INT("ks", ks, 3, 9999);
    DC_INT("profile", profile, 0, 3);
    DC_REAL("fwhm", psf_fwhm, 0.5, 10); DC_REAL("ratio", psf_ratio, 0.5, 2);
    DC_REAL("angle", psf_angle, 0, 360); DC_REAL("beta", psf_beta, 1.5, 10);
    DC_REAL("diameter", airy_diameter, 1, 2000); DC_REAL("focal", airy_fl, 1, 60000);
    DC_REAL("wavelength", airy_wl, 100, 30000); DC_REAL("pixelSize", airy_pixelsize, 0.1, 30);
    DC_READ("obstruction", 0, 99); data->airy_obstruction = v / 100.0;
    DC_INT("symmetric", symkern, 0, 1); data->recalc_ks = auto_size;
    DC_INT("blindMethod", blindtype, 0, 1);
    DC_READ("weight", 1, 5000); data->lambda = 1.0 / v;
    data->intermediatedeconvolutionweight = data->finaldeconvolutionweight = v;
    DC_INT("multiscale", multiscale, 0, 1); DC_REAL("gamma", gamma, 0, 100);
    DC_INT("blindIterations", iterations, 1, 50); DC_REAL("lambdaRatio", lambda_ratio, 0, 1);
    DC_REAL("lambdaMin", lambda_min, 0.0001, 0.01); DC_REAL("scaleFactor", scalefactor, 0, 1);
    DC_REAL("upBlur", upscaleblur, 0, 5); DC_REAL("downBlur", downscaleblur, 0, 5);
    DC_REAL("kernelThreshold", kernel_threshold_max, 0, 1); DC_INT("betterKernel", better_kernel, 0, 1); DC_REAL("kL1", k_l1, 0, 1);
    DC_REAL("compensation", compensationfactor, 1, 100); DC_INT("tries", ntries, 4, 128);
    DC_INT("outer", nouter, 1, 10); DC_INT("inner", ninner, 1, 500);
    DC_INT("method", nonblindtype, 0, 2); DC_READ("alpha", 1, 50000); data->alpha = 1.0 / v;
    DC_INT("iterations", finaliters, 1, 10000); DC_INT("rlMethod", rl_method, 0, 1);
    DC_INT("regularization", regtype, 0, 2); DC_INT("stopping", stopcriterion_active, 0, 1);
    DC_REAL("stop", stopcriterion, 0.00001, 0.1); DC_REAL("step", stepsize, 0.0001, 0.1);
#undef DC_READ
#undef DC_REAL
#undef DC_INT
    if (source != 3 && !(data->ks % 2)) goto done;
    if (source == 0 && data->blindtype == BLIND_L0 &&
        (data->gamma <= 0 || data->lambda_ratio <= 0 || data->lambda_ratio >= 1 ||
         (data->multiscale && (data->scalefactor <= 0 || data->scalefactor >= 1)))) goto done;
    int ks = data->ks;
    fits input = {0};
    const char *path = yyjson_get_str(yyjson_obj_get(root, "psfPath"));
    if (source == 3) {
        int valid = path && *path && !readfits(path, &input, NULL, TRUE) &&
            input.rx == input.ry && input.rx >= 1 && input.rx <= 9999 &&
            (input.naxes[2] == 1 || input.naxes[2] == 3);
        if (valid) {
            ks = input.rx % 2 ? input.rx : input.rx - 1;
            size_t n = (size_t)input.rx * input.ry * input.naxes[2];
            for (size_t i = 0; i < n; i++) if (!isfinite(input.fdata[i])) { valid = 0; break; }
        }
        clearfits(&input); if (!valid) goto done;
    }
    double pixels = (double)image->fit.rx * image->fit.ry * image->fit.naxes[2] * sizeof(float);
    double required = pixels * 5 + (double)ks * ks * 3 * sizeof(float) * 4;
    if (required > (double)get_available_memory() * 0.8) {
        capture_log("Not enough remaining iPad memory for deconvolution/PSF work buffers.\n", NULL); goto done;
    }
    if (source == 3) {
        if (load_kernel((gchar *)path, data) || !deconv_valid_kernel()) goto done;
        data->psftype = PSF_PREVIOUS; data->ks = com.kernelsize; data->kchans = com.kernelchannels;
    } else {
        data->psftype = source == 0 ? PSF_BLIND : source == 1 ? PSF_STARS : PSF_MANUAL;
        // Detection must describe this input; prior mask/findstar jobs cannot
        // silently supply another image's PSF or bypass measured parameters.
        clear_stars_list(FALSE);
        estk_data config = *data;
        estk_data *owned = data; data = NULL;
        if (!deconv_worker(&image->fit, owned, &op_desc_psf_estimate, 0) || !deconv_valid_kernel()) goto done;
        data = alloc_estk_data(); if (!data) goto done;
        *data = config; data->savepsf_filename = NULL; data->fdata = NULL;
        data->psftype = PSF_PREVIOUS; data->ks = com.kernelsize; data->kchans = com.kernelchannels;
    }
    // Save exactly the PSF being applied; every session/job owns its FITS copy.
    if (save_kernel("process/native-psf.fits", data)) goto done;
    if (only) ok = 1;
    else {
        estk_data *owned = data; data = NULL;
        ok = deconv_worker(&image->fit, owned, &op_desc_deconvolve,
            yyjson_get_bool(yyjson_obj_get(root, "maskAware")));
    }
done:
    if (data) free_estk_data(data);
    reset_conv_kernel();
    return ok && !g_atomic_int_get(&cancel_requested);
}
