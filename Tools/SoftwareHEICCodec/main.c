#include <errno.h>
#include <inttypes.h>
#include <libheif/heif.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static const uint8_t kMagic[8] = {'L', 'M', 'R', 'G', 'B', 'A', '0', '1'};
static const uint32_t kMaximumDimension = 1920;
static const size_t kHeaderSize = 16;
static const size_t kMaximumHEICBytes = 64 * 1024 * 1024;

static void write_u32_le(uint8_t *destination, uint32_t value) {
    destination[0] = (uint8_t)(value & 0xff);
    destination[1] = (uint8_t)((value >> 8) & 0xff);
    destination[2] = (uint8_t)((value >> 16) & 0xff);
    destination[3] = (uint8_t)((value >> 24) & 0xff);
}

static uint32_t read_u32_le(const uint8_t *source) {
    return (uint32_t)source[0] | ((uint32_t)source[1] << 8) |
           ((uint32_t)source[2] << 16) | ((uint32_t)source[3] << 24);
}

static int checked_rgba_size(uint32_t width, uint32_t height, size_t *size) {
    if (width == 0 || height == 0 || width > kMaximumDimension ||
        height > kMaximumDimension) {
        return 0;
    }
    size_t pixels = (size_t)width * (size_t)height;
    if (pixels > SIZE_MAX / 4) {
        return 0;
    }
    *size = pixels * 4;
    return 1;
}

static int read_file(const char *path, size_t maximum_size, uint8_t **bytes,
                     size_t *byte_count) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return 0;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return 0;
    }
    long length = ftell(file);
    if (length < 0 || (size_t)length > maximum_size ||
        fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return 0;
    }
    uint8_t *buffer = malloc((size_t)length == 0 ? 1 : (size_t)length);
    if (buffer == NULL) {
        fclose(file);
        return 0;
    }
    size_t read_count = fread(buffer, 1, (size_t)length, file);
    int close_status = fclose(file);
    if (read_count != (size_t)length || close_status != 0) {
        free(buffer);
        return 0;
    }
    *bytes = buffer;
    *byte_count = read_count;
    return 1;
}

static int write_file(const char *path, const uint8_t *bytes,
                      size_t byte_count) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        return 0;
    }
    size_t written = fwrite(bytes, 1, byte_count, file);
    int flush_status = fflush(file);
    int close_status = fclose(file);
    return written == byte_count && flush_status == 0 && close_status == 0;
}

static int heif_ok(struct heif_error error) {
    return error.code == heif_error_Ok;
}

static int encode_rgba(const char *input_path, const char *output_path,
                       int quality) {
    uint8_t *input = NULL;
    size_t input_size = 0;
    if (!read_file(input_path, kHeaderSize + kMaximumDimension *
                                            kMaximumDimension * 4,
                   &input, &input_size) ||
        input_size < kHeaderSize || memcmp(input, kMagic, sizeof(kMagic)) != 0) {
        free(input);
        return 20;
    }
    uint32_t width = read_u32_le(input + 8);
    uint32_t height = read_u32_le(input + 12);
    size_t rgba_size = 0;
    if (!checked_rgba_size(width, height, &rgba_size) ||
        input_size != kHeaderSize + rgba_size || quality < 0 || quality > 100) {
        free(input);
        return 21;
    }

    struct heif_context *context = heif_context_alloc();
    struct heif_encoder *encoder = NULL;
    struct heif_image *image = NULL;
    struct heif_image_handle *handle = NULL;
    struct heif_color_profile_nclx *profile = NULL;
    int status = 22;
    if (context == NULL ||
        !heif_ok(heif_context_get_encoder_for_format(
            context, heif_compression_HEVC, &encoder)) ||
        !heif_ok(heif_encoder_set_lossy_quality(encoder, quality)) ||
        !heif_ok(heif_encoder_set_parameter_string(encoder, "preset", "fast")) ||
        !heif_ok(heif_image_create((int)width, (int)height,
                                   heif_colorspace_RGB,
                                   heif_chroma_interleaved_RGBA, &image)) ||
        !heif_ok(heif_image_add_plane(image, heif_channel_interleaved,
                                      (int)width, (int)height, 8))) {
        goto cleanup;
    }

    size_t stride = 0;
    uint8_t *plane = heif_image_get_plane2(image, heif_channel_interleaved, &stride);
    if (plane == NULL || stride < (size_t)width * 4) {
        goto cleanup;
    }
    const uint8_t *rgba = input + kHeaderSize;
    for (uint32_t row = 0; row < height; row++) {
        memcpy(plane + (size_t)row * (size_t)stride,
               rgba + (size_t)row * (size_t)width * 4, (size_t)width * 4);
    }

    profile = heif_nclx_color_profile_alloc();
    if (profile == NULL ||
        !heif_ok(heif_nclx_color_profile_set_color_primaries(
            profile, heif_color_primaries_ITU_R_BT_709_5)) ||
        !heif_ok(heif_nclx_color_profile_set_transfer_characteristics(
            profile, heif_transfer_characteristic_IEC_61966_2_1)) ||
        !heif_ok(heif_nclx_color_profile_set_matrix_coefficients(
            profile, heif_matrix_coefficients_ITU_R_BT_601_6))) {
        goto cleanup;
    }
    profile->full_range_flag = 1;
    if (!heif_ok(heif_image_set_nclx_color_profile(image, profile)) ||
        !heif_ok(heif_context_encode_image(context, image, encoder, NULL,
                                           &handle)) ||
        !heif_ok(heif_context_write_to_file(context, output_path))) {
        goto cleanup;
    }
    status = 0;

cleanup:
    if (profile != NULL) heif_nclx_color_profile_free(profile);
    if (handle != NULL) heif_image_handle_release(handle);
    if (image != NULL) heif_image_release(image);
    if (encoder != NULL) heif_encoder_release(encoder);
    if (context != NULL) heif_context_free(context);
    free(input);
    return status;
}

static int decode_heic(const char *input_path, const char *output_path) {
    uint8_t *input = NULL;
    size_t input_size = 0;
    if (!read_file(input_path, kMaximumHEICBytes, &input, &input_size) ||
        input_size == 0) {
        free(input);
        return 30;
    }
    struct heif_context *context = heif_context_alloc();
    struct heif_image_handle *handle = NULL;
    struct heif_image *image = NULL;
    uint8_t *output = NULL;
    int status = 31;
    if (context == NULL ||
        !heif_ok(heif_context_read_from_memory_without_copy(
            context, input, input_size, NULL)) ||
        !heif_ok(heif_context_get_primary_image_handle(context, &handle))) {
        goto cleanup;
    }
    int encoded_width = heif_image_handle_get_width(handle);
    int encoded_height = heif_image_handle_get_height(handle);
    size_t encoded_rgba_size = 0;
    if (encoded_width <= 0 || encoded_height <= 0 ||
        !checked_rgba_size((uint32_t)encoded_width, (uint32_t)encoded_height,
                           &encoded_rgba_size) ||
        !heif_ok(heif_decode_image(handle, &image, heif_colorspace_RGB,
                                   heif_chroma_interleaved_RGBA, NULL))) {
        goto cleanup;
    }
    int width_value = heif_image_get_width(image, heif_channel_interleaved);
    int height_value = heif_image_get_height(image, heif_channel_interleaved);
    size_t rgba_size = 0;
    if (width_value <= 0 || height_value <= 0 ||
        !checked_rgba_size((uint32_t)width_value, (uint32_t)height_value,
                           &rgba_size)) {
        goto cleanup;
    }
    size_t stride = 0;
    const uint8_t *plane =
        heif_image_get_plane_readonly2(image, heif_channel_interleaved, &stride);
    if (plane == NULL || stride < (size_t)width_value * 4) {
        goto cleanup;
    }
    output = malloc(kHeaderSize + rgba_size);
    if (output == NULL) {
        goto cleanup;
    }
    memcpy(output, kMagic, sizeof(kMagic));
    write_u32_le(output + 8, (uint32_t)width_value);
    write_u32_le(output + 12, (uint32_t)height_value);
    for (int row = 0; row < height_value; row++) {
        memcpy(output + kHeaderSize + (size_t)row * (size_t)width_value * 4,
               plane + (size_t)row * (size_t)stride,
               (size_t)width_value * 4);
    }
    if (!write_file(output_path, output, kHeaderSize + rgba_size)) {
        goto cleanup;
    }
    status = 0;

cleanup:
    free(output);
    if (image != NULL) heif_image_release(image);
    if (handle != NULL) heif_image_handle_release(handle);
    if (context != NULL) heif_context_free(context);
    free(input);
    return status;
}

static void print_usage(void) {
    fputs("usage: lm-software-heic encode INPUT.rgba OUTPUT.heic QUALITY\n"
          "       lm-software-heic decode INPUT.heic OUTPUT.rgba\n",
          stderr);
}

int main(int argc, char **argv) {
    umask(0077);
    if (argc < 2) {
        print_usage();
        return 2;
    }
    struct heif_error init_error = heif_init(NULL);
    if (!heif_ok(init_error)) {
        return 3;
    }
    int status = 2;
    if (strcmp(argv[1], "encode") == 0 && argc == 5) {
        char *end = NULL;
        long quality = strtol(argv[4], &end, 10);
        if (end != argv[4] && *end == '\0' && quality >= 0 && quality <= 100) {
            status = encode_rgba(argv[2], argv[3], (int)quality);
        }
    } else if (strcmp(argv[1], "decode") == 0 && argc == 4) {
        status = decode_heic(argv[2], argv[3]);
    } else {
        print_usage();
    }
    heif_deinit();
    return status;
}
