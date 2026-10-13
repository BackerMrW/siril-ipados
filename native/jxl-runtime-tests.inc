// SPDX-License-Identifier: GPL-3.0-or-later
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
static int jxl_reference_checks(const char *directory) {
    float pixels[8 * 6 * 3];
    for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < 3; c++)
        pixels[(y * 8 + x) * 3 + c] = (c + 1) * .1f + y * .01f + x * .001f;
    // Independent libjxl public encoder setup, bypassing Siril's writer.
    JxlEncoder *encoder = JxlEncoderCreate(NULL); CHECK(encoder);
    JxlBasicInfo basic; JxlEncoderInitBasicInfo(&basic);
    basic.xsize = 8; basic.ysize = 6; basic.num_color_channels = 3;
    basic.bits_per_sample = 32; basic.exponent_bits_per_sample = 8; basic.uses_original_profile = JXL_TRUE;
    CHECK(JxlEncoderSetBasicInfo(encoder, &basic) == JXL_ENC_SUCCESS);
    JxlColorEncoding color; JxlColorEncodingSetToLinearSRGB(&color, JXL_FALSE);
    CHECK(JxlEncoderSetColorEncoding(encoder, &color) == JXL_ENC_SUCCESS);
    JxlEncoderFrameSettings *settings = JxlEncoderFrameSettingsCreate(encoder, NULL); CHECK(settings);
    CHECK(JxlEncoderSetFrameLossless(settings, JXL_TRUE) == JXL_ENC_SUCCESS);
    CHECK(JxlEncoderSetFrameDistance(settings, 0) == JXL_ENC_SUCCESS);
    CHECK(JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 1) == JXL_ENC_SUCCESS);
    JxlPixelFormat format = {3, JXL_TYPE_FLOAT, JXL_NATIVE_ENDIAN, 0};
    CHECK(JxlEncoderAddImageFrame(settings, &format, pixels, sizeof pixels) == JXL_ENC_SUCCESS);
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
    snprintf(input, sizeof input, "%s/jxl-independent.jxl", directory);
    CHECK(g_file_set_contents(input, (char *)encoded, used, NULL)); free(encoded);
    SirilImage *image = siril_image_read_any(input, error, sizeof error); CHECK(image);
    SirilImageInfo info; CHECK(siril_image_info(image, &info));
    CHECK(info.width == 8 && info.height == 6 && info.channels == 3);
    for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++) {
        float pixel[3]; CHECK(siril_image_pixel(image, x, y, pixel) == 3);
        for (int c = 0; c < 3; c++) CHECK(fabs(pixel[c] - pixels[(y * 8 + x) * 3 + c]) < 2e-6);
    }
    snprintf(output, sizeof output, "%s/jxl-export.jxl", directory);
    CHECK(!siril_image_export_jxl(image, output, 16, 7, 100));
    CHECK(!siril_image_export_jxl(image, output, 32, 0, 100));
    CHECK(!siril_image_export_jxl(image, output, 32, 7, NAN));
    CHECK(siril_image_export_jxl(image, output, 32, 1, 100));
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
            CHECK(basic.xsize == 8 && basic.ysize == 6 && basic.bits_per_sample == 32 && basic.num_color_channels == 3);
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            size_t required; CHECK(JxlDecoderImageOutBufferSize(decoder, &format, &required) == JXL_DEC_SUCCESS);
            CHECK(required == sizeof decoded);
            CHECK(JxlDecoderSetImageOutBuffer(decoder, &format, decoded, sizeof decoded) == JXL_DEC_SUCCESS);
        } else CHECK(status == JXL_DEC_FULL_IMAGE);
    }
    for (int i = 0; i < 8 * 6 * 3; i++) CHECK(fabs(decoded[i] - pixels[i]) < 2e-6);
    JxlDecoderDestroy(decoder); g_free(data);
    snprintf(output, sizeof output, "%s/missing-directory/fail.jxl", directory);
    CHECK(!siril_image_export_jxl(image, output, 32, 1, 100));
    siril_image_free(image);
    snprintf(input, sizeof input, "%s/jxl-invalid.jxl", directory);
    CHECK(g_file_set_contents(input, "not an image", -1, NULL));
    CHECK(!siril_image_read_any(input, error, sizeof error));
    puts("PASS: original JPEG XL reader matched independently encoded RGB float samples; independent decoder verified original lossless float export, orientation and precision; invalid parameters, overwrite, failed write and malformed input rejected");
    return 0;
}
