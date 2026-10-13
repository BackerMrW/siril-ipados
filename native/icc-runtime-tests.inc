// SPDX-License-Identifier: GPL-3.0-or-later
#include "core/icc_profile.h"
static int icc_reference_checks(const char *directory) {
    char source[4096], assigned[4096], converted[4096], removed[4096], custom[4096], script[18000], error[1024];
    // A independently authored D50 RGB destination distinguishes absolute from
    // relative colorimetry. It does not reuse Siril's profile construction.
    cmsCIExyY white = {.3457, .3585, 1.0};
    cmsCIExyYTRIPLE primaries = {{.64, .33, 1}, {.30, .60, 1}, {.15, .06, 1}};
    cmsToneCurve *gamma = cmsBuildGamma(NULL, 2.2); CHECK(gamma);
    cmsToneCurve *curves[3] = {gamma, gamma, gamma};
    cmsHPROFILE destination = cmsCreateRGBProfile(&white, &primaries, curves); CHECK(destination);
    cmsFreeToneCurve(gamma);
    snprintf(custom, sizeof custom, "%s/independent-d50.icc", directory);
    CHECK(cmsSaveProfileToFile(destination, custom));
    for (int channels = 1; channels <= 3; channels += 2) {
        snprintf(source, sizeof source, "%s/icc-source-%d.fits", directory, channels);
        snprintf(assigned, sizeof assigned, "%s/icc-assigned-%d.fits", directory, channels);
        snprintf(removed, sizeof removed, "%s/icc-removed-%d.fits", directory, channels);
        float input[8 * 6 * 3];
        for (int c = 0; c < channels; c++) for (int i = 0; i < 48; i++) input[c * 48 + i] = .05f + c * .1f + i * .003f;
        fitsfile *file = NULL; int status = 0;
        long axes[3] = {8, 6, channels};
        fits_create_file(&file, source, &status);
        fits_create_img(file, FLOAT_IMG, channels == 1 ? 2 : 3, axes, &status);
        fits_write_img(file, TFLOAT, 1, 48 * channels, input, &status);
        fits_close_file(file, &status); CHECK(!status);
        snprintf(script, sizeof script, "set32bits\nload %s\nicc_assign srgblinear\nsave %s\nclose\n", source, assigned);
        CHECK(siril_run_commands(directory, script, error, sizeof error));
        fits reference = {0}; CHECK(!readfits(assigned, &reference, NULL, TRUE));
        CHECK(reference.icc_profile && reference.color_managed && reference.naxes[2] == channels);
        SirilImage *native = siril_image_read(assigned, error, sizeof error); CHECK(native);
        size_t profile_size = siril_image_copy_icc(native, NULL, 0); CHECK(profile_size >= 128);
        unsigned char *profile_bytes = malloc(profile_size); CHECK(profile_bytes);
        CHECK(siril_image_copy_icc(native, profile_bytes, profile_size) == profile_size);
        CHECK(siril_icc_validate(profile_bytes, profile_size, channels));
        CHECK(!siril_icc_validate(profile_bytes, profile_size, channels == 3 ? 1 : 3));
        CHECK(!siril_icc_validate("not an ICC", 10, channels));
        CHECK(!siril_icc_validate(profile_bytes, 16 * 1024 * 1024 + 1, channels));
        cmsHPROFILE copied = cmsOpenProfileFromMem(profile_bytes, (cmsUInt32Number)profile_size); CHECK(copied);
        CHECK(cmsGetColorSpace(copied) == cmsGetColorSpace(reference.icc_profile));
        cmsCloseProfile(copied); free(profile_bytes); siril_image_free(native);
        for (int i = 0; i < channels * 48; i++) CHECK(reference.fdata[i] == input[i]);
        cmsHPROFILE builtin = channels == 1 ? gray_srgbtrc() : srgb_trc(); CHECK(builtin);
        float intent_pixels[2][3] = {{0}};
        for (int intent = 0; intent < 4; intent++) for (int use_custom = 0; use_custom <= (channels == 3); use_custom++) {
            const char *intents[] = {"perceptual", "relative", "saturation", "absolute"};
            const char *target = use_custom ? custom : channels == 1 ? "graysrgb" : "srgb";
            snprintf(converted, sizeof converted, "%s/icc-converted-%d-%d-%d.fits", directory, channels, intent, use_custom);
            snprintf(script, sizeof script, "load %s\nicc_convert_to %s %s\nsave %s\nclose\n", assigned, target, intents[intent], converted);
            cmsUInt32Number kind = channels == 1 ? TYPE_GRAY_FLT_PLANAR : TYPE_RGB_FLT_PLANAR;
            cmsHTRANSFORM transform = cmsCreateTransform(reference.icc_profile, kind, use_custom ? destination : builtin, kind, intent, com.icc.rendering_flags); CHECK(transform);
            float expected[144];
            cmsDoTransformLineStride(transform, reference.fdata, expected, 8, 6, 8 * sizeof(float), 8 * sizeof(float), 48 * sizeof(float), 48 * sizeof(float));
            cmsDeleteTransform(transform);
            int saved_intent = com.pref.icc.export_intent;
            CHECK(siril_run_commands(directory, script, error, sizeof error));
            CHECK(com.pref.icc.export_intent == saved_intent);
            fits result = {0}; CHECK(!readfits(converted, &result, NULL, TRUE));
            CHECK(result.icc_profile && result.color_managed && result.naxes[2] == channels);
            for (int i = 0; i < 48 * channels; i++) CHECK(fabsf(result.fdata[i] - expected[i]) < 3e-6f);
            if (use_custom && (intent == 1 || intent == 3)) for (int c = 0; c < 3; c++) intent_pixels[intent == 3][c] = result.fdata[c * 48 + 20];
            clearfits(&result);
        }
        if (channels == 3) CHECK(fabsf(intent_pixels[0][0] - intent_pixels[1][0]) + fabsf(intent_pixels[0][1] - intent_pixels[1][1]) + fabsf(intent_pixels[0][2] - intent_pixels[1][2]) > .001f);
        cmsCloseProfile(builtin); clearfits(&reference);
        snprintf(script, sizeof script, "load %s\nicc_remove\nsave %s\nclose\n", assigned, removed);
        CHECK(siril_run_commands(directory, script, error, sizeof error));
        fits result = {0}; CHECK(!readfits(removed, &result, NULL, TRUE));
        CHECK(!result.icc_profile && !result.color_managed);
        for (int i = 0; i < channels * 48; i++) CHECK(result.fdata[i] == input[i]);
        clearfits(&result);
        snprintf(script, sizeof script, "load %s\nicc_remove\nicc_convert_to srgb relative\n", source);
        CHECK(!siril_run_commands(directory, script, error, sizeof error));
        fits original = {0}; CHECK(!readfits(source, &original, NULL, TRUE));
        for (int i = 0; i < channels * 48; i++) CHECK(original.fdata[i] == input[i]);
        clearfits(&original);
    }
    cmsCloseProfile(destination);
    // A syntactically valid CMYK profile must fail rather than leave the old
    // RGB profile attached and report successful conversion.
    cmsHPROFILE cmyk = cmsCreateInkLimitingDeviceLink(cmsSigCmykData, 300); CHECK(cmyk);
    snprintf(custom, sizeof custom, "%s/unsupported-cmyk.icc", directory);
    CHECK(cmsSaveProfileToFile(cmyk, custom)); cmsCloseProfile(cmyk);
    snprintf(assigned, sizeof assigned, "%s/icc-assigned-3.fits", directory);
    snprintf(script, sizeof script, "load %s\nicc_convert_to %s relative\n", assigned, custom);
    CHECK(!siril_run_commands(directory, script, error, sizeof error));
    siril_release_workspace();
    puts("PASS: original ICC assign/convert/remove preserved source and FITS profiles; independent LittleCMS verified every mono/RGB pixel and all four intents, including distinct absolute colorimetry; missing/unsupported profile conversion rejected and global intent restored");
    return 0;
}
