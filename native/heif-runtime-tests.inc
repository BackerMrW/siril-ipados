// SPDX-License-Identifier: GPL-3.0-or-later
#include <libheif/heif.h>
static int heif_reference_checks(const char *directory) {
    CHECK(heif_init(NULL).code == heif_error_Ok);
    CHECK(heif_have_decoder_for_format(heif_compression_HEVC));
    CHECK(heif_have_decoder_for_format(heif_compression_AV1));
    const char *names[] = {"heif-padded.heic", "heif-alpha.heic", "heif-av1.avif", "heif-16bit.heif"};
    char path[4096], output[4096], error[512];
    for (int k = 0; k < 4; k++) {
        snprintf(path, sizeof path, "%s/%s", getenv("SIRIL_FORMAT_FIXTURES"), names[k]);
        // Independent public codec API, bypassing the original Siril reader.
        struct heif_context *context = heif_context_alloc(); CHECK(context);
        CHECK(heif_context_read_from_file(context, path, NULL).code == heif_error_Ok);
        struct heif_image_handle *handle = NULL;
        CHECK(heif_context_get_primary_image_handle(context, &handle).code == heif_error_Ok);
        int bits = heif_image_handle_get_luma_bits_per_pixel(handle);
        CHECK(bits >= 8 && bits <= 16);
        struct heif_image *decoded = NULL;
        CHECK(heif_decode_image(handle, &decoded, heif_colorspace_RGB,
            bits > 8 ? heif_chroma_interleaved_RRGGBB_LE : heif_chroma_interleaved_RGB, NULL).code == heif_error_Ok);
        int stride = 0;
        const uint8_t *data = heif_image_get_plane_readonly(decoded, heif_channel_interleaved, &stride); CHECK(data);
        int width = heif_image_get_width(decoded, heif_channel_interleaved), height = heif_image_get_height(decoded, heif_channel_interleaved);
        CHECK(stride >= width * 3 * (bits > 8 ? 2 : 1));
        if (!k) CHECK(width == 451 && height == 461 && stride > width * 3);
        if (k == 3) CHECK(bits == 16);
        SirilImage *image = siril_image_read_any(path, error, sizeof error); CHECK(image);
        snprintf(output, sizeof output, "%s/heif-%d.fits", directory, k);
        CHECK(siril_image_write(image, output));
        SirilImage *restored = siril_image_read(output, error, sizeof error); CHECK(restored);
        SirilImageInfo info; CHECK(siril_image_info(image, &info));
        CHECK(info.width == width && info.height == height && (info.channels == 1 || info.channels == 3));
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            float actual[3], saved[3]; CHECK(siril_image_pixel(image, x, y, actual) == info.channels);
            CHECK(siril_image_pixel(restored, x, y, saved) == info.channels);
            for (int c = 0; c < 3; c++) {
                const uint8_t *sample = data + (size_t)y * stride + (x * 3 + c) * (bits > 8 ? 2 : 1);
                unsigned value = bits > 8 ? sample[0] | ((unsigned)sample[1] << 8) : sample[0];
                double expected = value / (double)((1u << bits) - 1);
                int channel = info.channels == 1 ? 0 : c;
                CHECK(fabs(actual[channel] - expected) <= 1.1 / 65535);
                CHECK(fabs(saved[channel] - actual[channel]) < 1e-7);
            }
        }
        siril_image_free(restored); siril_image_free(image);
        heif_image_release(decoded); heif_image_handle_release(handle); heif_context_free(context);
    }
    snprintf(path, sizeof path, "%s/heif-invalid.heic", getenv("SIRIL_FORMAT_FIXTURES"));
    CHECK(!siril_image_read_any(path, error, sizeof error));
    heif_deinit();
    puts("PASS: original HEIC/AVIF/uncompressed 16-bit HEIF pixels matched independent public codec decoding across every padded row, alpha and FITS round-trip; malformed input rejected");
    return 0;
}
