// SPDX-License-Identifier: GPL-3.0-or-later
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include "core/icc_profile.h"
static int jxl_channel_checks(const char *directory, int channels) {
    const size_t pixel_count = 8 * 6 * channels, pixel_bytes = pixel_count * sizeof(float);
    float pixels[8 * 6 * 3];
    for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < channels; c++)
        pixels[(y * 8 + x) * channels + c] = (c + 1) * .1f + y * .01f + x * .001f;
    // Independent libjxl public encoder setup, bypassing Siril's writer.
    JxlEncoder *encoder = JxlEncoderCreate(NULL); CHECK(encoder);
    JxlBasicInfo basic; JxlEncoderInitBasicInfo(&basic);
    basic.xsize = 8; basic.ysize = 6; basic.num_color_channels = channels;
    basic.bits_per_sample = 32; basic.exponent_bits_per_sample = 8; basic.uses_original_profile = JXL_TRUE;
    CHECK(JxlEncoderSetBasicInfo(encoder, &basic) == JXL_ENC_SUCCESS);
    JxlColorEncoding color; JxlColorEncodingSetToLinearSRGB(&color, channels == 1);
    CHECK(JxlEncoderSetColorEncoding(encoder, &color) == JXL_ENC_SUCCESS);
    JxlEncoderFrameSettings *settings = JxlEncoderFrameSettingsCreate(encoder, NULL); CHECK(settings);
    CHECK(JxlEncoderSetFrameLossless(settings, JXL_TRUE) == JXL_ENC_SUCCESS);
    CHECK(JxlEncoderSetFrameDistance(settings, 0) == JXL_ENC_SUCCESS);
    CHECK(JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 1) == JXL_ENC_SUCCESS);
    JxlPixelFormat format = {(uint32_t)channels, JXL_TYPE_FLOAT, JXL_NATIVE_ENDIAN, 0};
    CHECK(JxlEncoderAddImageFrame(settings, &format, pixels, pixel_bytes) == JXL_ENC_SUCCESS);
    JxlEncoderCloseInput(encoder);
    size_t capacity = 4096, used = 0; uint8_t *encoded = malloc(capacity); CHECK(encoded);
    for (;;) {
        uint8_t *next = encoded + used; size_t remaining = capacity - used;
        JxlEncoderStatus status = JxlEncoderProcessOutput(encoder, &next, &remaining);
        used = capacity - remaining;
        if (status == JXL_ENC_SUCCESS) break;
        CHECK(status == JXL_ENC_NEED_MORE_OUTPUT);
        capacity *= 2; encoded = realloc(encoded, capacity); CHECK(encoded);
    }
    JxlEncoderDestroy(encoder);
    char input[4096], output[4096], error[512];
    snprintf(input, sizeof input, "%s/jxl-independent-%d.jxl", directory, channels);
    CHECK(g_file_set_contents(input, (char *)encoded, used, NULL)); free(encoded);
    SirilImage *image = siril_image_read_any(input, error, sizeof error); CHECK(image);
    SirilImageInfo info; CHECK(siril_image_info(image, &info));
    CHECK(info.width == 8 && info.height == 6 && info.channels == channels);
    for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) {
        float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == channels);
        for (int c = 0; c < channels; c++) CHECK(fabs(pixel[c] - pixels[(y * 8 + x) * channels + c]) < 2e-6);
    }
    fits reference = {0}; CHECK(readjxl(input, &reference) == channels);
    int default_profile = com.pref.icc.export_16bit_method;
    CHECK(default_profile == EXPORT_WORKING && reference.icc_profile && reference.color_managed);
    for (int mode = 0; mode < 2; mode++) {
    float expected[8 * 6 * 3]; memcpy(expected, pixels, pixel_bytes);
    if (!mode && reference.icc_profile && reference.color_managed) {
        cmsHPROFILE target = channels == 1 ? com.icc.mono_standard : com.icc.working_standard;
        cmsUInt32Number kind = channels == 1 ? TYPE_GRAY_FLT : TYPE_RGB_FLT;
        cmsHTRANSFORM transform = cmsCreateTransform(reference.icc_profile, kind, target, kind, com.pref.icc.export_intent, 0);
        CHECK(transform); cmsDoTransform(transform, pixels, expected, 8 * 6); cmsDeleteTransform(transform);
    }
    snprintf(output, sizeof output, "%s/jxl-export-%d-%d.jxl", directory, channels, mode);
    CHECK(!siril_image_export_jxl(image, output, 16, 7, 100));
    CHECK(!siril_image_export_jxl(image, output, 32, 0, 100));
    CHECK(!siril_image_export_jxl(image, output, 32, 7, NAN));
    CHECK(mode ? siril_image_export_jxl_profile(image, output, 32, 1, 100, 2) : siril_image_export_jxl(image, output, 32, 1, 100));
    CHECK(com.pref.icc.export_16bit_method == default_profile);
    CHECK(!siril_image_export_jxl(image, output, 32, 1, 100));
    gchar *data = NULL; gsize length = 0; CHECK(g_file_get_contents(output, &data, &length, NULL));
    JxlDecoder *decoder = JxlDecoderCreate(NULL); CHECK(decoder);
    CHECK(JxlDecoderSubscribeEvents(decoder, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) == JXL_DEC_SUCCESS);
    CHECK(JxlDecoderSetInput(decoder, (uint8_t *)data, length) == JXL_DEC_SUCCESS); JxlDecoderCloseInput(decoder);
    float decoded[8 * 6 * 3];
    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(decoder);
        if (status == JXL_DEC_SUCCESS) break;
        if (status == JXL_DEC_BASIC_INFO) {
            CHECK(JxlDecoderGetBasicInfo(decoder, &basic) == JXL_DEC_SUCCESS);
            CHECK(basic.xsize == 8 && basic.ysize == 6 && basic.bits_per_sample == 32 && basic.num_color_channels == channels);
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            size_t required; CHECK(JxlDecoderImageOutBufferSize(decoder, &format, &required) == JXL_DEC_SUCCESS);
            CHECK(required == pixel_bytes);
            CHECK(JxlDecoderSetImageOutBuffer(decoder, &format, decoded, pixel_bytes) == JXL_DEC_SUCCESS);
        } else CHECK(status == JXL_DEC_FULL_IMAGE);
    }
    for (size_t i = 0; i < pixel_count; i++) {
        if (fabs(decoded[i] - expected[i]) >= 2e-5) fprintf(stderr, "JPEG XL c=%d mode=%d sample=%zu actual=%.9g expected=%.9g\n", channels, mode, i, decoded[i], expected[i]);
        CHECK(fabs(decoded[i] - expected[i]) < (mode ? 2e-6 : 2e-5));
    }
    JxlDecoderDestroy(decoder); g_free(data);
    }
    clearfits(&reference);
    snprintf(output, sizeof output, "%s/missing-directory/fail.jxl", directory);
    CHECK(!siril_image_export_jxl(image, output, 32, 1, 100));
    siril_image_free(image);
    snprintf(input, sizeof input, "%s/jxl-invalid.jxl", directory);
    CHECK(g_file_set_contents(input, "not an image", -1, NULL));
    CHECK(!siril_image_read_any(input, error, sizeof error));
    puts("PASS: original JPEG XL reader matched independently encoded mono/RGB float samples; independent decoder verified original default working-space conversion and image-ICC lossless float export, orientation and precision; invalid parameters, overwrite, failed write and malformed input rejected");
    return 0;
}

static int jxl_reference_checks(const char *directory) {
    CHECK(jxl_channel_checks(directory, 1) == 0);
    CHECK(jxl_channel_checks(directory, 3) == 0);
    return 0;
}
