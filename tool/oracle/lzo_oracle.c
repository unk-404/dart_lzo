/*
 * lzo_oracle -- a tiny command line front end for liblzo2's LZO1X codec.
 *
 * It exists to validate this package's pure-Dart implementation against the
 * reference implementation: the Dart differential runner compresses with the
 * oracle and decompresses with Dart, and vice versa.
 *
 * Usage:
 *   lzo_oracle compress   <algo> <level> <in> <out>
 *   lzo_oracle decompress <algo> <in> <out> <outlen>
 *   lzo_oracle version
 *
 * <algo> is currently only "lzo1x". <level> is one of 1, 11, 12, 15 or 999
 * and selects the matching liblzo2 compressor. <outlen> is the exact expected
 * decompressed size: raw LZO1X blocks do not carry it.
 *
 * Exit status: 0 success, 1 I/O or usage error, 2 LZO library error.
 *
 * Build with the Makefile in this directory; liblzo2 2.10 is expected.
 */

#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lzo/lzo1x.h>

#define ORACLE_EXIT_USAGE 1
#define ORACLE_EXIT_IO 1
#define ORACLE_EXIT_LZO 2

static void usage(FILE *stream) {
  fputs(
      "usage: lzo_oracle compress   <algo> <level> <in> <out>\n"
      "       lzo_oracle decompress <algo> <in> <out> <outlen>\n"
      "       lzo_oracle version\n"
      "\n"
      "<algo>   lzo1x\n"
      "<level>  1, 11, 12, 15 or 999\n"
      "version  print the liblzo2 version used by this binary\n",
      stream);
}

static int parse_level(const char *text, unsigned *level) {
  char *end = NULL;
  errno = 0;
  const long value = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value <= 0 || value > 999) {
    return 0;
  }
  *level = (unsigned)value;
  return 1;
}

static int parse_size(const char *text, size_t *size) {
  char *end = NULL;
  errno = 0;
  const unsigned long long value = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0') {
    return 0;
  }
  if (value > (unsigned long long)SIZE_MAX) {
    return 0;
  }
  *size = (size_t)value;
  return 1;
}

static int read_file(const char *path, unsigned char **data, size_t *length) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    fprintf(stderr, "lzo_oracle: cannot open '%s' for reading: %s\n", path,
            strerror(errno));
    return 0;
  }
  if (fseek(file, 0, SEEK_END) != 0) {
    fprintf(stderr, "lzo_oracle: cannot seek '%s': %s\n", path,
            strerror(errno));
    fclose(file);
    return 0;
  }
  const long end = ftell(file);
  if (end < 0) {
    fprintf(stderr, "lzo_oracle: cannot determine the size of '%s': %s\n",
            path, strerror(errno));
    fclose(file);
    return 0;
  }
  if (fseek(file, 0, SEEK_SET) != 0) {
    fprintf(stderr, "lzo_oracle: cannot rewind '%s': %s\n", path,
            strerror(errno));
    fclose(file);
    return 0;
  }

  const size_t size = (size_t)end;
  /* Room for a trailing byte so a zero-length input still has a valid
   * (non-NULL) pointer for liblzo2. */
  unsigned char *buffer = (unsigned char *)malloc(size == 0 ? 1 : size);
  if (buffer == NULL) {
    fprintf(stderr, "lzo_oracle: out of memory reading '%s' (%zu bytes)\n",
            path, size);
    fclose(file);
    return 0;
  }
  if (size != 0 && fread(buffer, 1, size, file) != size) {
    fprintf(stderr, "lzo_oracle: short read on '%s'\n", path);
    free(buffer);
    fclose(file);
    return 0;
  }
  if (fclose(file) != 0) {
    fprintf(stderr, "lzo_oracle: cannot close '%s': %s\n", path,
            strerror(errno));
    free(buffer);
    return 0;
  }

  *data = buffer;
  *length = size;
  return 1;
}

static int write_file(const char *path, const unsigned char *data,
                      size_t length) {
  FILE *file = fopen(path, "wb");
  if (file == NULL) {
    fprintf(stderr, "lzo_oracle: cannot open '%s' for writing: %s\n", path,
            strerror(errno));
    return 0;
  }
  if (length != 0 && fwrite(data, 1, length, file) != length) {
    fprintf(stderr, "lzo_oracle: short write on '%s'\n", path);
    fclose(file);
    return 0;
  }
  if (fclose(file) != 0) {
    fprintf(stderr, "lzo_oracle: cannot close '%s': %s\n", path,
            strerror(errno));
    return 0;
  }
  return 1;
}

/* liblzo2 2.10 exports the error codes but not a message helper. */
static const char *lzo_error_message(int code) {
  switch (code) {
    case LZO_E_OK:
      return "success";
    case LZO_E_ERROR:
      return "unspecified error";
    case LZO_E_OUT_OF_MEMORY:
      return "out of memory";
    case LZO_E_NOT_COMPRESSIBLE:
      return "input is not compressible";
    case LZO_E_INPUT_OVERRUN:
      return "input overrun";
    case LZO_E_OUTPUT_OVERRUN:
      return "output overrun";
    case LZO_E_LOOKBEHIND_OVERRUN:
      return "lookbehind overrun";
    case LZO_E_EOF_NOT_FOUND:
      return "end of file not found";
    case LZO_E_INPUT_NOT_CONSUMED:
      return "input not consumed";
    case LZO_E_NOT_YET_IMPLEMENTED:
      return "not yet implemented";
    case LZO_E_INVALID_ARGUMENT:
      return "invalid argument";
    case LZO_E_INVALID_ALIGNMENT:
      return "invalid alignment";
    case LZO_E_OUTPUT_NOT_CONSUMED:
      return "output not consumed";
    case LZO_E_INTERNAL_ERROR:
      return "internal error";
    default:
      return "unknown error";
  }
}

static int lzo_failure(const char *operation, int code) {
  fprintf(stderr, "lzo_oracle: %s failed with LZO error %d (%s)\n", operation,
          code, lzo_error_message(code));
  return ORACLE_EXIT_LZO;
}

/* Worst-case compressed size, as documented by the LZO library
 * (`n + n / 16 + 64 + 3`); the extra bytes cover the end-of-stream marker and
 * any encoder-specific slack. */
static size_t compress_bound(size_t length) {
  return length + length / 16 + 64 + 3;
}

typedef int (*lzo_compress_fn)(const lzo_bytep src, lzo_uint src_len,
                               lzo_bytep dst, lzo_uintp dst_len,
                               lzo_voidp wrkmem);

static lzo_compress_fn compressor_for_level(unsigned level,
                                            size_t *workmem_size) {
  *workmem_size = LZO1X_1_MEM_COMPRESS;
  switch (level) {
    case 1:
      return lzo1x_1_compress;
    case 11:
      *workmem_size = LZO1X_1_11_MEM_COMPRESS;
      return lzo1x_1_11_compress;
    case 12:
      *workmem_size = LZO1X_1_12_MEM_COMPRESS;
      return lzo1x_1_12_compress;
    case 15:
      *workmem_size = LZO1X_1_15_MEM_COMPRESS;
      return lzo1x_1_15_compress;
    case 999:
      *workmem_size = LZO1X_999_MEM_COMPRESS;
      return lzo1x_999_compress;
    default:
      return NULL;
  }
}

static int command_compress(int argc, char **argv) {
  if (argc != 6) {
    usage(stderr);
    return ORACLE_EXIT_USAGE;
  }
  const char *algo = argv[2];
  const char *level_text = argv[3];
  const char *input_path = argv[4];
  const char *output_path = argv[5];

  if (strcmp(algo, "lzo1x") != 0) {
    fprintf(stderr, "lzo_oracle: unsupported algorithm '%s' (only lzo1x)\n",
            algo);
    return ORACLE_EXIT_USAGE;
  }
  unsigned level = 0;
  if (!parse_level(level_text, &level)) {
    fprintf(stderr, "lzo_oracle: invalid level '%s'\n", level_text);
    return ORACLE_EXIT_USAGE;
  }
  size_t workmem_size = 0;
  const lzo_compress_fn compress = compressor_for_level(level, &workmem_size);
  if (compress == NULL) {
    fprintf(stderr,
            "lzo_oracle: unsupported lzo1x level '%s' "
            "(supported: 1, 11, 12, 15, 999)\n",
            level_text);
    return ORACLE_EXIT_USAGE;
  }

  unsigned char *source = NULL;
  size_t source_length = 0;
  if (!read_file(input_path, &source, &source_length)) {
    return ORACLE_EXIT_IO;
  }

  const size_t capacity = compress_bound(source_length);
  unsigned char *destination = (unsigned char *)malloc(capacity == 0 ? 1 : capacity);
  void *workmem = malloc(workmem_size == 0 ? 1 : workmem_size);
  if (destination == NULL || workmem == NULL) {
    fprintf(stderr, "lzo_oracle: out of memory compressing %zu bytes\n",
            source_length);
    free(source);
    free(destination);
    free(workmem);
    return ORACLE_EXIT_IO;
  }

  lzo_uint destination_length = (lzo_uint)capacity;
  const int code = compress(source, (lzo_uint)source_length, destination,
                            &destination_length, workmem);
  if (code != LZO_E_OK) {
    free(source);
    free(destination);
    free(workmem);
    return lzo_failure("compress", code);
  }
  if ((size_t)destination_length > capacity) {
    fprintf(stderr,
            "lzo_oracle: compressor reported %lu bytes but only %zu were "
            "available\n",
            (unsigned long)destination_length, capacity);
    free(source);
    free(destination);
    free(workmem);
    return ORACLE_EXIT_LZO;
  }

  const int written =
      write_file(output_path, destination, (size_t)destination_length);
  free(source);
  free(destination);
  free(workmem);
  if (!written) {
    return ORACLE_EXIT_IO;
  }
  return 0;
}

static int command_decompress(int argc, char **argv) {
  if (argc != 6) {
    usage(stderr);
    return ORACLE_EXIT_USAGE;
  }
  const char *algo = argv[2];
  const char *input_path = argv[3];
  const char *output_path = argv[4];
  const char *expected_text = argv[5];

  if (strcmp(algo, "lzo1x") != 0) {
    fprintf(stderr, "lzo_oracle: unsupported algorithm '%s' (only lzo1x)\n",
            algo);
    return ORACLE_EXIT_USAGE;
  }
  size_t expected_length = 0;
  if (!parse_size(expected_text, &expected_length)) {
    fprintf(stderr, "lzo_oracle: invalid output length '%s'\n", expected_text);
    return ORACLE_EXIT_USAGE;
  }

  unsigned char *source = NULL;
  size_t source_length = 0;
  if (!read_file(input_path, &source, &source_length)) {
    return ORACLE_EXIT_IO;
  }

  unsigned char *destination =
      (unsigned char *)malloc(expected_length == 0 ? 1 : expected_length);
  if (destination == NULL) {
    fprintf(stderr, "lzo_oracle: out of memory decompressing %zu bytes\n",
            expected_length);
    free(source);
    return ORACLE_EXIT_IO;
  }

  lzo_uint destination_length = (lzo_uint)expected_length;
  /* lzo1x_decompress_safe verifies every overrun, which is exactly the
   * behaviour the Dart differential wants to compare against. */
  const int code = lzo1x_decompress_safe(
      source, (lzo_uint)source_length, destination, &destination_length, NULL);
  if (code != LZO_E_OK) {
    free(source);
    free(destination);
    return lzo_failure("decompress", code);
  }
  if ((size_t)destination_length != expected_length) {
    fprintf(stderr,
            "lzo_oracle: decompressed %lu bytes, expected %zu\n",
            (unsigned long)destination_length, expected_length);
    free(source);
    free(destination);
    return ORACLE_EXIT_LZO;
  }

  const int written =
      write_file(output_path, destination, expected_length);
  free(source);
  free(destination);
  if (!written) {
    return ORACLE_EXIT_IO;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    usage(stderr);
    return ORACLE_EXIT_USAGE;
  }

  const int init = lzo_init();
  if (init != LZO_E_OK) {
    return lzo_failure("lzo_init", init);
  }

  if (strcmp(argv[1], "version") == 0) {
    if (argc != 2) {
      usage(stderr);
      return ORACLE_EXIT_USAGE;
    }
    printf("lzo_oracle (liblzo2 %s)\n", LZO_VERSION_STRING);
    return 0;
  }
  if (strcmp(argv[1], "compress") == 0) {
    return command_compress(argc, argv);
  }
  if (strcmp(argv[1], "decompress") == 0) {
    return command_decompress(argc, argv);
  }
  if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
    usage(stdout);
    return 0;
  }

  fprintf(stderr, "lzo_oracle: unknown command '%s'\n", argv[1]);
  usage(stderr);
  return ORACLE_EXIT_USAGE;
}
