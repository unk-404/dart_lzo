/*
 * lzo_oracle -- a tiny command line front end for liblzo2 2.10.
 *
 * It exists to validate this package's pure-Dart implementation against the
 * reference implementation: the Dart differential runner compresses with the
 * oracle and decompresses with Dart, and vice versa.
 *
 * Usage:
 *   lzo_oracle compress        <algo> <level> <in> <out>
 *   lzo_oracle decompress      <algo> <in> <out> <outlen>
 *   lzo_oracle compress-dict   <algo> <dict> <in> <out>
 *   lzo_oracle decompress-dict <algo> <dict> <in> <out> <outlen>
 *   lzo_oracle list
 *   lzo_oracle version
 *
 * <algo> is one of: lzo1 lzo1a lzo1b lzo1c lzo1f lzo1x lzo1y lzo1z lzo2a.
 * <level> is the liblzo2 compression level of that algorithm (see `list`).
 * <outlen> is the exact expected decompressed size: raw LZO blocks carry no
 * original length.
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

#include <lzo/lzo1.h>
#include <lzo/lzo1a.h>
#include <lzo/lzo1b.h>
#include <lzo/lzo1c.h>
#include <lzo/lzo1f.h>
#include <lzo/lzo1x.h>
#include <lzo/lzo1y.h>
#include <lzo/lzo1z.h>
#include <lzo/lzo2a.h>

#define ORACLE_EXIT_USAGE 1
#define ORACLE_EXIT_IO 1
#define ORACLE_EXIT_LZO 2

typedef int (*lzo_compress_fn)(const lzo_bytep src, lzo_uint src_len,
                               lzo_bytep dst, lzo_uintp dst_len,
                               lzo_voidp wrkmem);
typedef int (*lzo_decompress_fn)(const lzo_bytep src, lzo_uint src_len,
                                 lzo_bytep dst, lzo_uintp dst_len,
                                 lzo_voidp wrkmem);
typedef int (*lzo_compress_dict_fn)(const lzo_bytep src, lzo_uint src_len,
                                    lzo_bytep dst, lzo_uintp dst_len,
                                    lzo_voidp wrkmem, const lzo_bytep dict,
                                    lzo_uint dict_len);
typedef int (*lzo_decompress_dict_fn)(const lzo_bytep src, lzo_uint src_len,
                                      lzo_bytep dst, lzo_uintp dst_len,
                                      lzo_voidp wrkmem, const lzo_bytep dict,
                                      lzo_uint dict_len);

typedef struct {
  const char *algorithm;
  unsigned level;
  lzo_compress_fn compress;
  size_t workmem;
} compressor_entry;

typedef struct {
  const char *algorithm;
  lzo_decompress_fn decompress;
} decompressor_entry;

typedef struct {
  const char *algorithm;
  lzo_compress_dict_fn compress;
  lzo_decompress_dict_fn decompress;
  size_t workmem;
} dictionary_entry;

#define COMPRESSOR(algo, level, fn, mem) \
  { algo, level, fn, (size_t)(mem) }

#define DECOMPRESSOR(algo, fn) { algo, fn }

#define DICTIONARY(algo, cfn, dfn, mem) { algo, cfn, dfn, (size_t)(mem) }

static const compressor_entry compressors[] = {
    COMPRESSOR("lzo1", 1, lzo1_compress, LZO1_MEM_COMPRESS),
    COMPRESSOR("lzo1", 99, lzo1_99_compress, LZO1_99_MEM_COMPRESS),

    COMPRESSOR("lzo1a", 1, lzo1a_compress, LZO1A_MEM_COMPRESS),
    COMPRESSOR("lzo1a", 99, lzo1a_99_compress, LZO1A_99_MEM_COMPRESS),

    COMPRESSOR("lzo1b", 1, lzo1b_1_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 2, lzo1b_2_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 3, lzo1b_3_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 4, lzo1b_4_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 5, lzo1b_5_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 6, lzo1b_6_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 7, lzo1b_7_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 8, lzo1b_8_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 9, lzo1b_9_compress, LZO1B_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 99, lzo1b_99_compress, LZO1B_99_MEM_COMPRESS),
    COMPRESSOR("lzo1b", 999, lzo1b_999_compress, LZO1B_999_MEM_COMPRESS),

    COMPRESSOR("lzo1c", 1, lzo1c_1_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 2, lzo1c_2_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 3, lzo1c_3_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 4, lzo1c_4_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 5, lzo1c_5_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 6, lzo1c_6_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 7, lzo1c_7_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 8, lzo1c_8_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 9, lzo1c_9_compress, LZO1C_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 99, lzo1c_99_compress, LZO1C_99_MEM_COMPRESS),
    COMPRESSOR("lzo1c", 999, lzo1c_999_compress, LZO1C_999_MEM_COMPRESS),

    COMPRESSOR("lzo1f", 1, lzo1f_1_compress, LZO1F_MEM_COMPRESS),
    COMPRESSOR("lzo1f", 999, lzo1f_999_compress, LZO1F_999_MEM_COMPRESS),

    COMPRESSOR("lzo1x", 1, lzo1x_1_compress, LZO1X_1_MEM_COMPRESS),
    COMPRESSOR("lzo1x", 11, lzo1x_1_11_compress, LZO1X_1_11_MEM_COMPRESS),
    COMPRESSOR("lzo1x", 12, lzo1x_1_12_compress, LZO1X_1_12_MEM_COMPRESS),
    COMPRESSOR("lzo1x", 15, lzo1x_1_15_compress, LZO1X_1_15_MEM_COMPRESS),
    COMPRESSOR("lzo1x", 999, lzo1x_999_compress, LZO1X_999_MEM_COMPRESS),

    COMPRESSOR("lzo1y", 1, lzo1y_1_compress, LZO1Y_MEM_COMPRESS),
    COMPRESSOR("lzo1y", 999, lzo1y_999_compress, LZO1Y_999_MEM_COMPRESS),

    COMPRESSOR("lzo1z", 999, lzo1z_999_compress, LZO1Z_999_MEM_COMPRESS),

    COMPRESSOR("lzo2a", 999, lzo2a_999_compress, LZO2A_999_MEM_COMPRESS),
};

static const decompressor_entry decompressors[] = {
    DECOMPRESSOR("lzo1", lzo1_decompress),
    DECOMPRESSOR("lzo1a", lzo1a_decompress),
    DECOMPRESSOR("lzo1b", lzo1b_decompress_safe),
    DECOMPRESSOR("lzo1c", lzo1c_decompress_safe),
    DECOMPRESSOR("lzo1f", lzo1f_decompress_safe),
    DECOMPRESSOR("lzo1x", lzo1x_decompress_safe),
    DECOMPRESSOR("lzo1y", lzo1y_decompress_safe),
    DECOMPRESSOR("lzo1z", lzo1z_decompress_safe),
    DECOMPRESSOR("lzo2a", lzo2a_decompress_safe),
};

static const dictionary_entry dictionaries[] = {
    DICTIONARY("lzo1x", lzo1x_999_compress_dict, lzo1x_decompress_dict_safe,
               LZO1X_999_MEM_COMPRESS),
    DICTIONARY("lzo1y", lzo1y_999_compress_dict, lzo1y_decompress_dict_safe,
               LZO1Y_999_MEM_COMPRESS),
    DICTIONARY("lzo1z", lzo1z_999_compress_dict, lzo1z_decompress_dict_safe,
               LZO1Z_999_MEM_COMPRESS),
};

static void usage(FILE *stream) {
  fputs(
      "usage: lzo_oracle compress        <algo> <level> <in> <out>\n"
      "       lzo_oracle decompress      <algo> <in> <out> <outlen>\n"
      "       lzo_oracle compress-dict   <algo> <dict> <in> <out>\n"
      "       lzo_oracle decompress-dict <algo> <dict> <in> <out> <outlen>\n"
      "       lzo_oracle list\n"
      "       lzo_oracle version\n"
      "\n"
      "<algo> is one of: lzo1 lzo1a lzo1b lzo1c lzo1f lzo1x lzo1y lzo1z lzo2a\n"
      "run `lzo_oracle list` for the levels of each algorithm\n",
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

static const compressor_entry *find_compressor(const char *algorithm,
                                               unsigned level) {
  size_t i;
  for (i = 0; i < sizeof(compressors) / sizeof(compressors[0]); i++) {
    if (strcmp(compressors[i].algorithm, algorithm) == 0 &&
        compressors[i].level == level) {
      return &compressors[i];
    }
  }
  return NULL;
}

static const decompressor_entry *find_decompressor(const char *algorithm) {
  size_t i;
  for (i = 0; i < sizeof(decompressors) / sizeof(decompressors[0]); i++) {
    if (strcmp(decompressors[i].algorithm, algorithm) == 0) {
      return &decompressors[i];
    }
  }
  return NULL;
}

static const dictionary_entry *find_dictionary(const char *algorithm) {
  size_t i;
  for (i = 0; i < sizeof(dictionaries) / sizeof(dictionaries[0]); i++) {
    if (strcmp(dictionaries[i].algorithm, algorithm) == 0) {
      return &dictionaries[i];
    }
  }
  return NULL;
}

static int command_list(void) {
  size_t i;
  const char *last = NULL;
  for (i = 0; i < sizeof(compressors) / sizeof(compressors[0]); i++) {
    const compressor_entry *entry = &compressors[i];
    if (last == NULL || strcmp(last, entry->algorithm) != 0) {
      if (last != NULL) {
        fputc('\n', stdout);
      }
      printf("%s:", entry->algorithm);
      last = entry->algorithm;
    }
    printf(" %u", entry->level);
  }
  fputc('\n', stdout);
  return 0;
}

static int command_compress(int argc, char **argv) {
  if (argc != 6) {
    usage(stderr);
    return ORACLE_EXIT_USAGE;
  }
  const char *algorithm = argv[2];
  const char *level_text = argv[3];
  const char *input_path = argv[4];
  const char *output_path = argv[5];

  unsigned level = 0;
  if (!parse_level(level_text, &level)) {
    fprintf(stderr, "lzo_oracle: invalid level '%s'\n", level_text);
    return ORACLE_EXIT_USAGE;
  }
  const compressor_entry *entry = find_compressor(algorithm, level);
  if (entry == NULL) {
    fprintf(stderr,
            "lzo_oracle: no compressor for algorithm '%s' level '%s'; run "
            "`lzo_oracle list`\n",
            algorithm, level_text);
    return ORACLE_EXIT_USAGE;
  }

  unsigned char *source = NULL;
  size_t source_length = 0;
  if (!read_file(input_path, &source, &source_length)) {
    return ORACLE_EXIT_IO;
  }

  const size_t capacity = compress_bound(source_length);
  unsigned char *destination =
      (unsigned char *)malloc(capacity == 0 ? 1 : capacity);
  void *workmem = malloc(entry->workmem == 0 ? 1 : entry->workmem);
  if (destination == NULL || workmem == NULL) {
    fprintf(stderr, "lzo_oracle: out of memory compressing %zu bytes\n",
            source_length);
    free(source);
    free(destination);
    free(workmem);
    return ORACLE_EXIT_IO;
  }

  lzo_uint destination_length = (lzo_uint)capacity;
  const int code =
      entry->compress(source, (lzo_uint)source_length, destination,
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
  const char *algorithm = argv[2];
  const char *input_path = argv[3];
  const char *output_path = argv[4];
  const char *expected_text = argv[5];

  const decompressor_entry *entry = find_decompressor(algorithm);
  if (entry == NULL) {
    fprintf(stderr, "lzo_oracle: unknown algorithm '%s'; run `lzo_oracle list`\n",
            algorithm);
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
  const int code =
      entry->decompress(source, (lzo_uint)source_length, destination,
                        &destination_length, NULL);
  if (code != LZO_E_OK) {
    free(source);
    free(destination);
    return lzo_failure("decompress", code);
  }
  if ((size_t)destination_length != expected_length) {
    fprintf(stderr, "lzo_oracle: decompressed %lu bytes, expected %zu\n",
            (unsigned long)destination_length, expected_length);
    free(source);
    free(destination);
    return ORACLE_EXIT_LZO;
  }

  const int written = write_file(output_path, destination, expected_length);
  free(source);
  free(destination);
  if (!written) {
    return ORACLE_EXIT_IO;
  }
  return 0;
}

static int command_compress_dict(int argc, char **argv) {
  if (argc != 6) {
    usage(stderr);
    return ORACLE_EXIT_USAGE;
  }
  const char *algorithm = argv[2];
  const char *dictionary_path = argv[3];
  const char *input_path = argv[4];
  const char *output_path = argv[5];

  const dictionary_entry *entry = find_dictionary(algorithm);
  if (entry == NULL) {
    fprintf(stderr,
            "lzo_oracle: no dictionary codec for algorithm '%s' (only lzo1x, "
            "lzo1y, lzo1z)\n",
            algorithm);
    return ORACLE_EXIT_USAGE;
  }

  unsigned char *dictionary = NULL;
  size_t dictionary_length = 0;
  if (!read_file(dictionary_path, &dictionary, &dictionary_length)) {
    return ORACLE_EXIT_IO;
  }
  unsigned char *source = NULL;
  size_t source_length = 0;
  if (!read_file(input_path, &source, &source_length)) {
    free(dictionary);
    return ORACLE_EXIT_IO;
  }

  const size_t capacity = compress_bound(source_length);
  unsigned char *destination =
      (unsigned char *)malloc(capacity == 0 ? 1 : capacity);
  void *workmem = malloc(entry->workmem == 0 ? 1 : entry->workmem);
  if (destination == NULL || workmem == NULL) {
    fprintf(stderr, "lzo_oracle: out of memory compressing with a dictionary\n");
    free(dictionary);
    free(source);
    free(destination);
    free(workmem);
    return ORACLE_EXIT_IO;
  }

  lzo_uint destination_length = (lzo_uint)capacity;
  const int code = entry->compress(source, (lzo_uint)source_length, destination,
                                   &destination_length, workmem, dictionary,
                                   (lzo_uint)dictionary_length);
  free(dictionary);
  if (code != LZO_E_OK) {
    free(source);
    free(destination);
    free(workmem);
    return lzo_failure("compress-dict", code);
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

static int command_decompress_dict(int argc, char **argv) {
  if (argc != 7) {
    usage(stderr);
    return ORACLE_EXIT_USAGE;
  }
  const char *algorithm = argv[2];
  const char *dictionary_path = argv[3];
  const char *input_path = argv[4];
  const char *output_path = argv[5];
  const char *expected_text = argv[6];

  const dictionary_entry *entry = find_dictionary(algorithm);
  if (entry == NULL) {
    fprintf(stderr,
            "lzo_oracle: no dictionary codec for algorithm '%s' (only lzo1x, "
            "lzo1y, lzo1z)\n",
            algorithm);
    return ORACLE_EXIT_USAGE;
  }
  size_t expected_length = 0;
  if (!parse_size(expected_text, &expected_length)) {
    fprintf(stderr, "lzo_oracle: invalid output length '%s'\n", expected_text);
    return ORACLE_EXIT_USAGE;
  }

  unsigned char *dictionary = NULL;
  size_t dictionary_length = 0;
  if (!read_file(dictionary_path, &dictionary, &dictionary_length)) {
    return ORACLE_EXIT_IO;
  }
  unsigned char *source = NULL;
  size_t source_length = 0;
  if (!read_file(input_path, &source, &source_length)) {
    free(dictionary);
    return ORACLE_EXIT_IO;
  }

  unsigned char *destination =
      (unsigned char *)malloc(expected_length == 0 ? 1 : expected_length);
  if (destination == NULL) {
    fprintf(stderr, "lzo_oracle: out of memory decompressing with a dictionary\n");
    free(dictionary);
    free(source);
    return ORACLE_EXIT_IO;
  }

  lzo_uint destination_length = (lzo_uint)expected_length;
  const int code = entry->decompress(source, (lzo_uint)source_length,
                                     destination, &destination_length, NULL,
                                     dictionary, (lzo_uint)dictionary_length);
  free(dictionary);
  if (code != LZO_E_OK) {
    free(source);
    free(destination);
    return lzo_failure("decompress-dict", code);
  }
  if ((size_t)destination_length != expected_length) {
    fprintf(stderr, "lzo_oracle: decompressed %lu bytes, expected %zu\n",
            (unsigned long)destination_length, expected_length);
    free(source);
    free(destination);
    return ORACLE_EXIT_LZO;
  }

  const int written = write_file(output_path, destination, expected_length);
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
  if (strcmp(argv[1], "list") == 0) {
    if (argc != 2) {
      usage(stderr);
      return ORACLE_EXIT_USAGE;
    }
    return command_list();
  }
  if (strcmp(argv[1], "compress") == 0) {
    return command_compress(argc, argv);
  }
  if (strcmp(argv[1], "decompress") == 0) {
    return command_decompress(argc, argv);
  }
  if (strcmp(argv[1], "compress-dict") == 0) {
    return command_compress_dict(argc, argv);
  }
  if (strcmp(argv[1], "decompress-dict") == 0) {
    return command_decompress_dict(argc, argv);
  }
  if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
    usage(stdout);
    return 0;
  }

  fprintf(stderr, "lzo_oracle: unknown command '%s'\n", argv[1]);
  usage(stderr);
  return ORACLE_EXIT_USAGE;
}
