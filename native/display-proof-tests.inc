// SPDX-License-Identifier: GPL-3.0-or-later
static int display_proof_reference(const char *directory) {
    char input[4096], path[4096], custom[4096], script[18000], error[512];
    snprintf(input, sizeof input, "%s/proof-input.fits", directory);
    snprintf(path, sizeof path, "%s/proof-wide.fits", directory);
    snprintf(custom, sizeof custom, "%s/independent-d50.icc", directory);
    const float colors[][3] = {{.9,.01,.01}, {.01,.9,.01}, {.01,.01,.9}, {.2,.5,.02}, {.7,.1,.4}, {.3,.4,.2}};
    float pixels[144]; for (int c = 0; c < 3; c++) for (int i = 0; i < 48; i++) pixels[c * 48 + i] = colors[i % 6][c];
    fitsfile *file = NULL; int status = 0; long axes[] = {8, 6, 3};
    fits_create_file(&file, input, &status); fits_create_img(file, FLOAT_IMG, 3, axes, &status);
    fits_write_img(file, TFLOAT, 1, 144, pixels, &status); fits_close_file(file, &status); CHECK(!status);
    snprintf(script, sizeof script, "set32bits\nload %s\nicc_assign rec2020linear\nsave %s\nclose\n", input, path);
    CHECK(siril_run_commands(directory, script, error, sizeof error));
    fits reference = {0}; CHECK(!readfits(path, &reference, NULL, TRUE));
    SirilImage *image = siril_image_read(path, error, sizeof error); CHECK(image);
    cmsHPROFILE custom_profile = cmsOpenProfileFromFile(custom, "r"); CHECK(custom_profile);
    cmsUInt32Number custom_size = 0; CHECK(cmsSaveProfileToMem(custom_profile, NULL, &custom_size));
    BYTE *custom_bytes = malloc(custom_size); CHECK(custom_bytes && cmsSaveProfileToMem(custom_profile, custom_bytes, &custom_size));
    cmsContext context = cmsCreateContext(NULL, NULL); CHECK(context);
    cmsUInt16Number alarms[16] = {65535, 0, 65535}; cmsSetAlarmCodesTHR(context, alarms);
    SirilDisplayOptions settings = {.mode = 0, .low = 0, .high = 1};
    SirilPreview raw; CHECK(siril_image_preview_mode(image, 8, -1, &settings, &raw));
    BYTE source[144]; for (int c = 0; c < 3; c++) for (int i = 0; i < 48; i++) source[c * 48 + i] = raw.rgba[i * 4 + c];
    int warnings = 0;
    for (int proof = 1; proof <= 4; proof++) {
        cmsHPROFILE target = proof == 1 ? srgb_trc() : proof == 2 ? rec2020_trc() : proof == 3 ? copyICCProfile(com.icc.working_standard) : copyICCProfile(custom_profile); CHECK(target);
        settings.icc = 1; settings.proof = proof; settings.proof_data = custom_bytes; settings.proof_size = custom_size;
        for (int rendering = 0; rendering < 4; rendering++) for (int intent = 0; intent < 4; intent++) for (int gamut = 0; gamut <= 1; gamut++) {
            settings.rendering_intent = rendering; settings.proofing_intent = intent; settings.black_point = 1; settings.gamut_check = gamut;
            cmsUInt32Number flags = cmsFLAGS_SOFTPROOFING | cmsFLAGS_NOOPTIMIZE;
            if (rendering != INTENT_ABSOLUTE_COLORIMETRIC) flags |= cmsFLAGS_BLACKPOINTCOMPENSATION;
            if (gamut) flags |= cmsFLAGS_GAMUTCHECK;
            cmsHPROFILE screen = rendering == INTENT_PERCEPTUAL ? srgb_monitor_perceptual() : srgb_trc(); CHECK(screen);
            cmsHTRANSFORM transform = cmsCreateProofingTransformTHR(context, reference.icc_profile, TYPE_RGB_8_PLANAR, screen, TYPE_RGB_8_PLANAR, target, rendering, intent, flags); CHECK(transform);
            BYTE expected[144]; cmsDoTransformLineStride(transform, source, expected, 8, 6, 8, 8, 48, 48); cmsDeleteTransform(transform);
            SirilPreview preview; CHECK(siril_image_preview_mode(image, 8, -1, &settings, &preview));
            for (int i = 0; i < 48; i++) {
                for (int c = 0; c < 3; c++) CHECK(abs(preview.rgba[i * 4 + c] - expected[c * 48 + i]) <= 1);
                if (proof == 1 && rendering == 1 && intent == 1 && gamut && preview.rgba[i * 4] == 255 && preview.rgba[i * 4 + 1] == 0 && preview.rgba[i * 4 + 2] == 255) warnings++;
                CHECK(preview.rgba[i * 4 + 3] == 255);
            }
            siril_preview_free(&preview);
            cmsCloseProfile(screen);
        }
        cmsCloseProfile(target);
    }
    CHECK(warnings > 0);
    settings.proof = 4; settings.proof_data = NULL; settings.proof_size = 0;
    SirilPreview invalid; CHECK(!siril_image_preview_mode(image, 8, -1, &settings, &invalid));
    settings.proof = 0; settings.rendering_intent = 4; CHECK(!siril_image_preview_mode(image, 8, -1, &settings, &invalid));
    for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) {
        float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == 3);
        for (int c = 0; c < 3; c++) CHECK(pixel[c] == pixels[c * 48 + (5 - y) * 8 + x]);
    }
    siril_preview_free(&raw); free(custom_bytes); cmsCloseProfile(custom_profile); cmsDeleteContext(context);
    siril_image_free(image); clearfits(&reference); siril_release_workspace();
    puts("PASS: original display soft-proofing matched independent LittleCMS for all rendering/proofing intents, built-in/custom ICC, black-point compensation and actual magenta gamut warnings; invalid settings rejected and source preserved");
    return 0;
}
