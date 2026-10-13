// SPDX-License-Identifier: GPL-3.0-or-later
static int display_icc_reference(const char *directory) {
    char path[4096], wide[4096], script[18000], error[1024];
    snprintf(path, sizeof path, "%s/icc-assigned-3.fits", directory);
    snprintf(wide, sizeof wide, "%s/icc-wide.fits", directory);
    snprintf(script, sizeof script, "load %s\nicc_assign rec2020linear\nsave %s\nclose\n", path, wide);
    CHECK(siril_run_commands(directory, script, error, sizeof error));
    for (int variant = 0; variant < 3; variant++) {
        int channels = variant == 0 ? 1 : 3;
        if (variant == 2) snprintf(path, sizeof path, "%s", wide);
        else snprintf(path, sizeof path, "%s/icc-assigned-%d.fits", directory, channels);
        fits reference = {0}; CHECK(!readfits(path, &reference, NULL, TRUE));
        SirilImage *image = siril_image_read(path, error, sizeof error); CHECK(image);
        cmsHPROFILE monitor = srgb_trc(); CHECK(monitor);
        for (int mode = 0; mode < 7; mode++) {
            SirilDisplayOptions settings = {.mode = mode, .low = .01, .high = .9, .icc = 1, .rendering_intent = 1, .proofing_intent = 1};
            SirilPreview managed, raw;
            CHECK(siril_image_preview_mode(image, 8, -1, &settings, &managed));
            settings.icc = 0; CHECK(siril_image_preview_mode(image, 8, -1, &settings, &raw)); settings.icc = 1;
            CHECK(managed.width == 8 && managed.height == 6);
            if (mode == 6 || (mode == 5 && channels == 1)) CHECK(!memcmp(managed.rgba, raw.rgba, 8 * 6 * 4));
            else {
                int floating = mode < 5 && variant == 1;
                cmsHPROFILE synthetic = NULL, source_profile = reference.icc_profile;
                if (mode == 5 && channels == 3) {
                    synthetic = cmsCreateProfilePlaceholder(NULL); CHECK(synthetic);
                    cmsSetProfileVersion(synthetic, 4.3); cmsSetDeviceClass(synthetic, cmsSigDisplayClass);
                    cmsSetColorSpace(synthetic, cmsSigRgbData); cmsSetPCS(synthetic, cmsSigXYZData);
                    CHECK(cmsWriteTag(synthetic, cmsSigMediaWhitePointTag, cmsReadTag(source_profile, cmsSigMediaWhitePointTag)));
                    cmsTagSignature colorants[] = {cmsSigRedColorantTag, cmsSigGreenColorantTag, cmsSigBlueColorantTag};
                    cmsTagSignature trcs[] = {cmsSigRedTRCTag, cmsSigGreenTRCTag, cmsSigBlueTRCTag};
                    for (int c = 0; c < 3; c++) {
                        CHECK(cmsWriteTag(synthetic, colorants[c], cmsReadTag(source_profile, colorants[c])));
                        CHECK(cmsWriteTag(synthetic, trcs[c], cmsReadTag(monitor, trcs[c])));
                    }
                    source_profile = synthetic;
                }
                cmsUInt32Number kind = floating ? TYPE_RGB_FLT_PLANAR : channels == 1 ? TYPE_GRAY_8 : TYPE_RGB_8_PLANAR;
                cmsUInt32Number flags = cmsFLAGS_SOFTPROOFING;
                if (!synthetic && fit_icc_is_linear(&reference)) flags |= cmsFLAGS_NOOPTIMIZE;
                cmsHTRANSFORM transform = cmsCreateProofingTransform(source_profile, kind, monitor, TYPE_RGB_8_PLANAR, monitor,
                    settings.rendering_intent, settings.proofing_intent, flags); CHECK(transform);
                float input_float[144]; BYTE input_byte[144], expected[144];
                for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < channels; c++) {
                    int i = y * 8 + x;
                    input_byte[c * 48 + i] = raw.rgba[i * 4 + c];
                    if (floating) {
                        double low = lround(settings.low * 65535), delta = lround(settings.high * 65535) - low;
                        double value = fmax(0, lroundf(reference.fpdata[c][(5 - y) * 8 + x] * 65535) - low), expected_value = 0;
                        switch (mode) {
                            case 0: expected_value = value / delta; break;
                            case 1: expected_value = value < 10 ? 0 : log(value / 10) / fabs(log(delta / 10)); break;
                            case 2: expected_value = sqrt(value / delta); break;
                            case 3: expected_value = (value / delta) * (value / delta); break;
                            case 4: expected_value = asinh(value / 1000) / asinh(delta / 1000); break;
                        }
                        input_float[c * 48 + i] = fmin(1, fmax(0, expected_value));
                    }
                }
                size_t input_size = floating ? sizeof(float) : 1;
                cmsDoTransformLineStride(transform, floating ? (void *)input_float : (void *)input_byte, expected, 8, 6,
                    8 * input_size, 8, 48 * input_size, 48);
                for (int i = 0; i < 48; i++) for (int c = 0; c < 3; c++) CHECK(abs(managed.rgba[i * 4 + c] - expected[(channels == 1 ? 0 : c) * 48 + i]) <= 1);
                cmsDeleteTransform(transform); if (synthetic) cmsCloseProfile(synthetic);
            }
            if (mode == 5 && channels == 3) {
                siril_preview_free(&managed); siril_preview_free(&raw);
                settings.icc = 1;
                CHECK(siril_image_preview_mode(image, 8, 1, &settings, &managed));
                settings.icc = 0; CHECK(siril_image_preview_mode(image, 8, 1, &settings, &raw));
                CHECK(!memcmp(managed.rgba, raw.rgba, 8 * 6 * 4));
                siril_preview_free(&managed); siril_preview_free(&raw);
                settings.unlinked = 1;
                settings.icc = 1;
                CHECK(siril_image_preview_mode(image, 8, -1, &settings, &managed));
                settings.icc = 0; CHECK(siril_image_preview_mode(image, 8, -1, &settings, &raw));
                CHECK(!memcmp(managed.rgba, raw.rgba, 8 * 6 * 4));
            }
            siril_preview_free(&managed); siril_preview_free(&raw);
        }
        cmsCloseProfile(monitor); siril_image_free(image); clearfits(&reference);
    }
    siril_release_workspace();
    puts("PASS: original ICC display transforms matched independent LittleCMS for every mono/sRGB/Rec2020 preview pixel, five modes and linked STF; float LUT avoided linear-source quantization, independent STF and histogram skipped ICC exactly");
    return 0;
}
