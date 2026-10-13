// SPDX-License-Identifier: GPL-3.0-or-later
#include "SirilDisplayLUT.inc"
#include "SirilDisplayICC.inc"
#include "SirilDisplayRainbow.inc"
static BYTE display_mask_byte(fits *fit, size_t pixel) {
    if (fit->mask->bitpix == 8) return ((uint8_t *)fit->mask->data)[pixel];
    if (fit->mask->bitpix == 16) return ((uint16_t *)fit->mask->data)[pixel] >> 8;
    float value = ((float *)fit->mask->data)[pixel];
    return isfinite(value) ? (BYTE)(fminf(1, fmaxf(0, value)) * 255) : 0;
}
static void display_tint_pixel(BYTE rgb[3], BYTE mask) {
    unsigned red = 255 - mask + rgb[0];
    rgb[0] = red > 255 ? 255 : red;
    rgb[1] = (rgb[1] * mask) >> 8;
    rgb[2] = (rgb[2] * mask) >> 8;
}
static int preview_mode_locked(fits *fit, uint32_t maximum, int selected, const SirilDisplayOptions *options, SirilPreview *preview) {
    if (!fit || !preview || !options || !maximum || maximum > 2048 || selected < -1 || selected >= fit->naxes[2] ||
        options->mode < 0 || options->mode > 6 || !isfinite(options->low) || !isfinite(options->high) ||
        options->low < 0 || options->high > 1 || options->high <= options->low ||
        (options->unlinked != 0 && options->unlinked != 1) || (options->inverted != 0 && options->inverted != 1) ||
        (options->icc != 0 && options->icc != 1) ||
        (options->rainbow != 0 && options->rainbow != 1) || (options->mask_overlay != 0 && options->mask_overlay != 1) ||
        options->rendering_intent < 0 || options->rendering_intent > 3 || options->proofing_intent < 0 || options->proofing_intent > 3 ||
        options->proof < 0 || options->proof > 4 || (options->black_point != 0 && options->black_point != 1) ||
        (options->gamut_check != 0 && options->gamut_check != 1) ||
        fit->type != DATA_FLOAT || fit->rx <= 0 || fit->ry <= 0 || (fit->naxes[2] != 1 && fit->naxes[2] != 3)) return 0;
    memset(preview, 0, sizeof *preview);
    BYTE palette[256][3];
    int rainbow = options->rainbow && (selected >= 0 || fit->naxes[2] == 1);
    if (rainbow) make_index_for_rainbow(palette);
    int overlay = options->mask_overlay && fit->mask && fit->mask->data && fit->mask_active &&
        (fit->mask->bitpix == 8 || fit->mask->bitpix == 16 || fit->mask->bitpix == 32);
    int tint_before = overlay && options->mode == STF_DISPLAY && selected < 0 && fit->naxes[2] == 3;
    WORD low = roundf_to_WORD(options->low * 65535), high = roundf_to_WORD(options->high * 65535);
    if (high <= low) return 0;
    struct mtf_params stf[3] = {0};
    if (options->mode == STF_DISPLAY) {
        if (options->unlinked && fit->naxes[2] == 3) {
            if (find_unlinked_midtones_balance_default(fit, stf)) return 0;
        } else {
            if (find_linked_midtones_balance_default(fit, &stf[0])) return 0;
            stf[1] = stf[2] = stf[0];
        }
    }
    BYTE *luts = g_try_malloc_n((size_t)fit->naxes[2], 65536); if (!luts) return 0;
    int ok = 0, compose = 0;
    cmsHPROFILE monitor = NULL, proof = NULL; cmsHTRANSFORM transform = NULL;
    float *float_lut = NULL; BYTE *row = NULL, *converted_row = NULL;
    int manage = options->icc && fit->icc_profile && fit->color_managed && options->mode != HISTEQ_DISPLAY &&
        !(options->mode == STF_DISPLAY && (options->unlinked || selected >= 0 || fit->naxes[2] == 1));
    if (manage) {
        monitor = options->rendering_intent == INTENT_PERCEPTUAL ? srgb_monitor_perceptual() : srgb_trc(); if (!monitor) goto done;
        if (options->proof == 1) proof = srgb_trc();
        if (options->proof == 2) proof = rec2020_trc();
        if (options->proof == 3) proof = copyICCProfile(com.icc.working_standard);
        if (options->proof == 4 && options->proof_data && options->proof_size >= 128 && options->proof_size <= 16 * 1024 * 1024)
            proof = cmsOpenProfileFromMem(options->proof_data, (cmsUInt32Number)options->proof_size);
        if (options->proof && !proof) goto done;
        compose = options->mode < STF_DISPLAY && fit->naxes[2] == 3 && embedded_original_same_primaries(fit->icc_profile, monitor, proof, options->proofing_intent);
        if (compose && fit_icc_is_linear(fit)) {
            float_lut = g_try_malloc_n(3 * 65536, sizeof(float)); if (!float_lut) goto done;
        }
        if (options->mode == STF_DISPLAY) transform = embedded_original_gamut_transform(fit, monitor, proof, options);
        if (!transform) transform = embedded_original_proofing_transform(fit, monitor, float_lut != NULL, proof, options);
        if (!transform) goto done;
    }
    for (int c = 0; c < fit->naxes[2]; c++) {
        BYTE *lut = luts + (size_t)c * 65536;
        if (options->mode == HISTEQ_DISPLAY) {
            gsl_histogram *histogram = computeHisto(fit, c);
            if (!histogram || histogram->n != 65536) { if (histogram) gsl_histogram_free(histogram); goto done; }
            double sum = gsl_histogram_get(histogram, 0), count = (double)fit->rx * fit->ry;
            lut[0] = 0;
            for (size_t i = 1; i < histogram->n; i++) {
                sum += gsl_histogram_get(histogram, i);
                lut[i] = round_to_BYTE(sum / count * 255);
            }
            gsl_histogram_free(histogram);
        } else if (options->mode != STF_DISPLAY && embedded_original_display_lut(options->mode, low, high, lut, stf[c], c == 0 ? float_lut : NULL)) goto done;
    }
    if (compose) {
        if (float_lut) {
            memcpy(float_lut + 65536, float_lut, 65536 * sizeof(float));
            memcpy(float_lut + 2 * 65536, float_lut, 65536 * sizeof(float));
            cmsDoTransformLineStride(transform, float_lut, luts, 65536, 1, 3 * 65536 * sizeof(float), 3 * 65536, 65536 * sizeof(float), 65536);
        } else {
            BYTE *input = g_try_malloc(3 * 65536); if (!input) goto done;
            memcpy(input, luts, 3 * 65536);
            cmsDoTransformLineStride(transform, input, luts, 65536, 1, 3 * 65536, 3 * 65536, 65536, 65536);
            g_free(input);
        }
    }
    double scale = fmin(1, (double)maximum / fmax(fit->rx, fit->ry));
    uint32_t width = fmax(1, floor(fit->rx * scale)), height = fmax(1, floor(fit->ry * scale));
    BYTE *pixels = g_try_malloc_n((size_t)width * height, 4); if (!pixels) goto done;
    row = g_try_malloc_n(width, 3); converted_row = g_try_malloc_n(width, 3);
    if (!row || !converted_row) { g_free(pixels); goto done; }
    for (uint32_t y = 0; y < height; y++) {
      for (uint32_t x = 0; x < width; x++) {
        uint32_t source_y = (uint64_t)y * fit->ry / height;
        if (!fit->top_down) source_y = fit->ry - 1 - source_y;
        size_t source = (size_t)source_y * fit->rx + (uint64_t)x * fit->rx / width;
        for (int c = 0; c < 3; c++) {
            int channel = fit->naxes[2] == 1 ? 0 : c;
            float value = fit->fpdata[channel][source]; BYTE display = 0;
            if (isfinite(value)) {
                if (options->mode == STF_DISPLAY) display = roundf_to_BYTE(MTFp(value, stf[channel]) * 255);
                else {
                    WORD index = roundf_to_WORD(value * 65535);
                    if (options->mode != HISTEQ_DISPLAY) index = index > low ? index - low : 0;
                    display = luts[(size_t)channel * 65536 + index];
                }
            }
            row[(size_t)c * width + x] = options->inverted ? 255 - display : display;
        }
        if (tint_before) {
            BYTE rgb[3] = {row[x], row[width + x], row[2 * width + x]};
            display_tint_pixel(rgb, display_mask_byte(fit, source));
            for (int c = 0; c < 3; c++) row[(size_t)c * width + x] = rgb[c];
        }
      }
      if (transform && !compose) cmsDoTransformLineStride(transform, row, converted_row, width, 1, width * 3, width * 3, width, width);
      else memcpy(converted_row, row, width * 3);
      for (uint32_t x = 0; x < width; x++) {
        size_t target = ((size_t)y * width + x) * 4;
        for (int c = 0; c < 3; c++) {
            int channel = selected >= 0 ? selected : fit->naxes[2] == 1 ? 0 : c;
            BYTE value = converted_row[(size_t)channel * width + x];
            pixels[target + c] = rainbow ? palette[value][c] : value;
        }
        if (overlay && !tint_before) {
            uint32_t source_y = (uint64_t)y * fit->ry / height;
            if (!fit->top_down) source_y = fit->ry - 1 - source_y;
            size_t source = (size_t)source_y * fit->rx + (uint64_t)x * fit->rx / width;
            display_tint_pixel(pixels + target, display_mask_byte(fit, source));
        }
        pixels[target + 3] = 255;
      }
    }
    preview->width = width; preview->height = height; preview->rgba = pixels; ok = 1;
done:
    if (transform) cmsDeleteTransform(transform);
    if (monitor) cmsCloseProfile(monitor);
    if (proof) cmsCloseProfile(proof);
    g_free(float_lut); g_free(row); g_free(converted_row); g_free(luts); return ok;
}
int siril_image_preview_mode(SirilImage *image, uint32_t maximum, int channel, const SirilDisplayOptions *options, SirilPreview *preview) {
    if (!image) return 0;
    g_mutex_lock(&engine_mutex);
    int ok = preview_mode_locked(&image->fit, maximum, channel, options, preview);
    g_mutex_unlock(&engine_mutex); return ok;
}
