/*
 * bench.c --- liblzo2 2.10 benchmark harness for lzo_neo.
 *
 * Mirrors `benchmark/dart/` exactly: the same deterministic corpus (seeded
 * xorshift32, README text, zeros, repeated pattern), the same 64 KiB / 1 MiB /
 * 8 MiB block sizes, the same operations (LZO1X-1 compress, safe decompress)
 * and the same compression-ratio rows. The output is benchcat canonical JSON
 * (`benchcat/report@1`) whose ids match the Dart side one for one, so the two
 * files can be rendered as a single comparison card.
 *
 * Build (Unix, system liblzo2 from `apt install liblzo2-dev`):
 *
 *     make -C benchmark/c
 *     ./benchmark/c/lzo_bench --text README.md --out build/bench/liblzo2-c.json
 *
 * Build (Windows, liblzo2 built from lzo-2.10.tar.gz with CMake/MSVC):
 *
 *     cmake -S benchmark/c -B build/c \
 *         -DLZO_INCLUDE_DIR=<lzo-2.10>/include \
 *         -DLZO_LIBRARY=<lzo-build>/Release/lzo2.lib
 *     cmake --build build/c --config Release
 *
 * `--text` defaults to `README.md`, so run from the repository root.
 *
 * This file is a development tool: it is never part of the published package.
 */

#if defined(_WIN32)
#define _CRT_SECURE_NO_WARNINGS
#endif

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <lzo/lzo1x.h>

#if defined(_WIN32)
#include <windows.h>
#endif

#define SIZE_COUNT 3
#define KIND_COUNT 4
#define BLOCK_COUNT (SIZE_COUNT * KIND_COUNT)
#define MAX_ITERS 1000000

static const size_t g_sizes[SIZE_COUNT] = {
    64u * 1024u,
    1024u * 1024u,
    8u * 1024u * 1024u,
};

static const char *g_size_labels[SIZE_COUNT] = {"64KiB", "1MiB", "8MiB"};

static const char *g_kinds[KIND_COUNT] = {"random", "text", "zeros", "pattern"};

/* Section headings, matching `_groupLabels` in benchmark/dart/canonical.dart. */
static const char *g_group_compress = "Compress (LZO1X-1)";
static const char *g_group_decompress = "Decompress";
static const char *g_group_ratio = "Ratio (compressed/original)";

/* Must match `patternSeed` in benchmark/dart/corpus.dart. */
static const char g_pattern[] = "lzo1x-neo-bench!";

typedef struct {
  const char *kind;
  const char *size_label;
  size_t size;
  unsigned char *data;
} corpus_block;

typedef struct {
  double seconds;
  long iters;
  double ops_per_sec;
  double rme_pct;
} measurement;

typedef struct {
  const unsigned char *src;
  size_t src_len;
  unsigned char *dst;
  size_t dst_cap;
  lzo_uint out_len;
  int rc;
  void *wrkmem;
} compress_job;

typedef struct {
  const unsigned char *src;
  size_t src_len;
  unsigned char *dst;
  size_t dst_cap;
  lzo_uint out_len;
  int rc;
} decompress_job;

typedef struct {
  size_t compressed_len;
  measurement compress;
  measurement decompress;
} block_result;

typedef void (*op_fn)(void *ctx);

/* ------------------------------------------------------------------ */
/* corpus                                                              */
/* ------------------------------------------------------------------ */

static unsigned char *read_file(const char *path, size_t *out_size) {
  FILE *file;
  long length;
  unsigned char *data;

  file = fopen(path, "rb");
  if (file == NULL) return NULL;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return NULL;
  }
  length = ftell(file);
  if (length <= 0) {
    fclose(file);
    return NULL;
  }
  rewind(file);
  data = (unsigned char *)malloc((size_t)length);
  if (data == NULL) {
    fclose(file);
    return NULL;
  }
  if (fread(data, 1, (size_t)length, file) != (size_t)length) {
    free(data);
    fclose(file);
    return NULL;
  }
  fclose(file);
  *out_size = (size_t)length;
  return data;
}

/* xorshift32; must match `_fillRandom()` in corpus.dart byte for byte. */
static void fill_random(unsigned char *out, size_t size) {
  uint32_t state = 0x9E3779B9u;
  size_t i;
  for (i = 0; i < size; i++) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    out[i] = (unsigned char)(state >> 24);
  }
}

static void fill_cyclic(unsigned char *out, size_t size,
                        const unsigned char *source, size_t source_len) {
  size_t i;
  for (i = 0; i < size; i++) out[i] = source[i % source_len];
}

static int build_corpus(corpus_block *blocks, const char *text_path) {
  unsigned char *text = NULL;
  size_t text_len = 0;
  int s;
  int k;
  int index = 0;

  text = read_file(text_path, &text_len);
  if (text == NULL) {
    fprintf(stderr, "error: cannot read text corpus \"%s\" "
                    "(run from the repository root)\n", text_path);
    return 0;
  }

  for (s = 0; s < SIZE_COUNT; s++) {
    for (k = 0; k < KIND_COUNT; k++) {
      size_t size = g_sizes[s];
      unsigned char *data = (unsigned char *)calloc(size, 1);
      if (data == NULL) {
        fprintf(stderr, "error: out of memory allocating %lu bytes\n",
                (unsigned long)size);
        free(text);
        return 0;
      }
      if (k == 0) {
        fill_random(data, size);
      } else if (k == 1) {
        fill_cyclic(data, size, text, text_len);
      } else if (k == 2) {
        /* calloc() already produced an all-zero block. */
      } else {
        fill_cyclic(data, size, (const unsigned char *)g_pattern,
                    sizeof(g_pattern) - 1);
      }
      blocks[index].kind = g_kinds[k];
      blocks[index].size_label = g_size_labels[s];
      blocks[index].size = size;
      blocks[index].data = data;
      index++;
    }
  }

  free(text);
  return 1;
}

static void free_corpus(corpus_block *blocks) {
  int i;
  for (i = 0; i < BLOCK_COUNT; i++) {
    free(blocks[i].data);
    blocks[i].data = NULL;
  }
}

static int dump_corpus(const corpus_block *blocks, const char *directory) {
  char path[1024];
  int i;
  for (i = 0; i < BLOCK_COUNT; i++) {
    FILE *file;
    snprintf(path, sizeof(path), "%s/%s-%s.bin", directory,
             blocks[i].size_label, blocks[i].kind);
    file = fopen(path, "wb");
    if (file == NULL) {
      fprintf(stderr, "error: cannot write %s\n", path);
      return 0;
    }
    if (fwrite(blocks[i].data, 1, blocks[i].size, file) != blocks[i].size) {
      fclose(file);
      fprintf(stderr, "error: short write to %s\n", path);
      return 0;
    }
    fclose(file);
  }
  return 1;
}

/* ------------------------------------------------------------------ */
/* timing                                                              */
/* ------------------------------------------------------------------ */

static double now_seconds(void) {
#if defined(_WIN32)
  LARGE_INTEGER frequency;
  LARGE_INTEGER counter;
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&counter);
  return (double)counter.QuadPart / (double)frequency.QuadPart;
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
#endif
}

static void run_compress(void *ctx) {
  compress_job *job = (compress_job *)ctx;
  job->out_len = (lzo_uint)job->dst_cap;
  job->rc = lzo1x_1_compress(job->src, (lzo_uint)job->src_len, job->dst,
                             &job->out_len, job->wrkmem);
}

static void run_decompress(void *ctx) {
  decompress_job *job = (decompress_job *)ctx;
  job->out_len = (lzo_uint)job->dst_cap;
  job->rc = lzo1x_decompress_safe(job->src, (lzo_uint)job->src_len, job->dst,
                                  &job->out_len, NULL);
}

static measurement measure(op_fn fn, void *ctx, double min_seconds,
                           int min_iters, int max_iters) {
  measurement result;
  double total = 0.0;
  double mean = 0.0;
  double m2 = 0.0;
  double variance;
  double deviation;
  int n = 0;

  memset(&result, 0, sizeof(result));
  if (max_iters > MAX_ITERS) max_iters = MAX_ITERS;

  fn(ctx); /* warm-up, not measured */

  while (n < max_iters) {
    double start = now_seconds();
    double elapsed;
    double delta;
    fn(ctx);
    elapsed = now_seconds() - start;
    n++;
    total += elapsed;
    /* Welford: online mean and sum of squared deviations. */
    delta = elapsed - mean;
    mean += delta / (double)n;
    m2 += delta * (elapsed - mean);
    if (total >= min_seconds && n >= min_iters) break;
  }
  if (n == 0 || total <= 0.0) return result;

  variance = n > 1 ? m2 / (double)(n - 1) : 0.0;
  deviation = sqrt(variance);

  result.seconds = total;
  result.iters = n;
  result.ops_per_sec = (double)n / total;
  result.rme_pct =
      (mean > 0.0 && n > 1) ? (1.96 * deviation / sqrt((double)n) / mean) * 100.0
                            : 0.0;
  return result;
}

/* ------------------------------------------------------------------ */
/* JSON output (benchcat/report@1)                                     */
/* ------------------------------------------------------------------ */

static const char *platform_os(void) {
#if defined(_WIN32)
  return "Windows";
#elif defined(__APPLE__)
  return "macOS";
#elif defined(__linux__)
  return "Linux";
#else
  return "unknown";
#endif
}

static const char *platform_arch(void) {
#if defined(__x86_64__) || defined(_M_X64)
  return "x86_64";
#elif defined(__aarch64__) || defined(_M_ARM64)
  return "aarch64";
#elif defined(__i386__) || defined(_M_IX86)
  return "x86";
#elif defined(__arm__) || defined(_M_ARM)
  return "arm";
#else
  return "unknown";
#endif
}

static void print_row(FILE *out, int *first, const corpus_block *block,
                      const char *operation, const char *group, const char *unit,
                      double value, const char *direction, const char *note,
                      int with_stats, const measurement *stats) {
  char id[64];
  char label[64];

  snprintf(id, sizeof(id), "lzo1x.%s.%s.%s", operation, block->size_label,
           block->kind);
  snprintf(label, sizeof(label), "%s %s", block->kind, block->size_label);

  fprintf(out, "%s    {\n", *first ? "" : ",\n");
  *first = 0;
  fprintf(out, "      \"id\": \"%s\",\n", id);
  fprintf(out, "      \"group\": \"%s\",\n", group);
  fprintf(out, "      \"label\": \"%s\",\n", label);
  fprintf(out, "      \"note\": \"%s\",\n", note);
  fprintf(out, "      \"unit\": \"%s\",\n", unit);
  fprintf(out, "      \"value\": %.6f,\n", value);
  fprintf(out, "      \"direction\": \"%s\",\n", direction);
  fprintf(out, "      \"params\": {\n");
  fprintf(out, "        \"corpus\": \"%s\",\n", block->kind);
  fprintf(out, "        \"size\": \"%s\",\n", block->size_label);
  fprintf(out, "        \"bytes\": %lu,\n", (unsigned long)block->size);
  fprintf(out, "        \"level\": \"fast1\"\n");
  if (with_stats) {
    fprintf(out, "      },\n");
    fprintf(out, "      \"stats\": {\n");
    fprintf(out, "        \"rme_pct\": %.3f,\n", stats->rme_pct);
    fprintf(out, "        \"samples\": %ld\n", stats->iters);
    fprintf(out, "      }\n");
  } else {
    fprintf(out, "      }\n");
  }
  fprintf(out, "    }");
}

static int emit_report(FILE *out, const corpus_block *blocks,
                       const block_result *results) {
  int first = 1;
  int i;
  const char *commit = getenv("GITHUB_SHA");

  fprintf(out, "{\n");
  fprintf(out, "  \"schema\": \"benchcat/report@1\",\n");
  fprintf(out, "  \"meta\": {\n");
  fprintf(out, "    \"tool\": \"liblzo2\",\n");
  fprintf(out, "    \"tool_version\": \"%s\",\n", lzo_version_string());
  if (commit != NULL && commit[0] != '\0') {
    fprintf(out, "    \"commit\": \"%s\",\n", commit);
  }
  fprintf(out, "    \"platform\": {\n");
  fprintf(out, "      \"os\": \"%s\",\n", platform_os());
  fprintf(out, "      \"arch\": \"%s\"\n", platform_arch());
  fprintf(out, "    }\n");
  fprintf(out, "  },\n");
  fprintf(out, "  \"benchmarks\": [\n");

  for (i = 0; i < BLOCK_COUNT; i++) {
    char note[64];
    double value = results[i].compress.ops_per_sec *
                   (double)blocks[i].size / (1000.0 * 1000.0);
    snprintf(note, sizeof(note), "%s block, fast1", blocks[i].size_label);
    print_row(out, &first, &blocks[i], "compress", g_group_compress, "MB/s",
              value, "higher", note, 1, &results[i].compress);
  }
  for (i = 0; i < BLOCK_COUNT; i++) {
    char note[64];
    double value = results[i].decompress.ops_per_sec *
                   (double)blocks[i].size / (1000.0 * 1000.0);
    snprintf(note, sizeof(note), "%s block, fast1", blocks[i].size_label);
    print_row(out, &first, &blocks[i], "decompress", g_group_decompress, "MB/s",
              value, "higher", note, 1, &results[i].decompress);
  }
  for (i = 0; i < BLOCK_COUNT; i++) {
    double value = (double)results[i].compressed_len / (double)blocks[i].size;
    print_row(out, &first, &blocks[i], "ratio", g_group_ratio, "x", value,
              "lower", "compressed/original, lower is better", 0, NULL);
  }

  fprintf(out, "\n  ]\n");
  fprintf(out, "}\n");
  return ferror(out) == 0;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

static void usage(FILE *out) {
  fprintf(out,
          "usage: lzo_bench [options]\n"
          "\n"
          "  --text <path>        text corpus source (default: README.md)\n"
          "  -o, --out <path>     write canonical JSON here (default: stdout)\n"
          "  --min-seconds <s>    minimum measured time per operation "
          "(default: 1.0)\n"
          "  --max-iters <n>      iteration cap per operation (default: "
          "100000)\n"
          "  --dump-corpus <dir>  write the 12 corpus blocks as .bin and "
          "exit\n"
          "  -h, --help           show this help\n");
}

int main(int argc, char **argv) {
  const char *text_path = "README.md";
  const char *out_path = NULL;
  const char *dump_dir = NULL;
  double min_seconds = 1.0;
  int max_iters = 100000;
  corpus_block blocks[BLOCK_COUNT];
  block_result results[BLOCK_COUNT];
  unsigned char *decoded = NULL;
  void *wrkmem = NULL;
  size_t max_size = g_sizes[SIZE_COUNT - 1];
  FILE *out = stdout;
  int i;
  int ok = 0;

  memset(blocks, 0, sizeof(blocks));
  memset(results, 0, sizeof(results));

  for (i = 1; i < argc; i++) {
    const char *arg = argv[i];
    if (strcmp(arg, "--text") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "error: --text needs a value\n");
        return 2;
      }
      text_path = argv[i];
    } else if (strcmp(arg, "-o") == 0 || strcmp(arg, "--out") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "error: --out needs a value\n");
        return 2;
      }
      out_path = argv[i];
    } else if (strcmp(arg, "--min-seconds") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "error: --min-seconds needs a value\n");
        return 2;
      }
      min_seconds = atof(argv[i]);
    } else if (strcmp(arg, "--max-iters") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "error: --max-iters needs a value\n");
        return 2;
      }
      max_iters = atoi(argv[i]);
    } else if (strcmp(arg, "--dump-corpus") == 0) {
      if (++i >= argc) {
        fprintf(stderr, "error: --dump-corpus needs a directory\n");
        return 2;
      }
      dump_dir = argv[i];
    } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
      usage(stdout);
      return 0;
    } else {
      fprintf(stderr, "error: unknown argument \"%s\"\n", arg);
      usage(stderr);
      return 2;
    }
  }

  if (lzo_init() != LZO_E_OK) {
    fprintf(stderr, "error: lzo_init() failed\n");
    return 1;
  }

  if (!build_corpus(blocks, text_path)) return 1;

  if (dump_dir != NULL) {
    int dumped = dump_corpus(blocks, dump_dir);
    free_corpus(blocks);
    return dumped ? 0 : 1;
  }

  wrkmem = malloc(LZO1X_1_MEM_COMPRESS);
  decoded = (unsigned char *)malloc(max_size);
  if (wrkmem == NULL || decoded == NULL) {
    fprintf(stderr, "error: out of memory\n");
    free(wrkmem);
    free(decoded);
    free_corpus(blocks);
    return 1;
  }

  for (i = 0; i < BLOCK_COUNT; i++) {
    size_t bound = blocks[i].size + blocks[i].size / 16 + 64 + 3;
    unsigned char *compressed = (unsigned char *)malloc(bound);
    compress_job compress_ctx;
    decompress_job decompress_ctx;

    if (compressed == NULL) {
      fprintf(stderr, "error: out of memory\n");
      goto cleanup;
    }

    memset(&compress_ctx, 0, sizeof(compress_ctx));
    compress_ctx.src = blocks[i].data;
    compress_ctx.src_len = blocks[i].size;
    compress_ctx.dst = compressed;
    compress_ctx.dst_cap = bound;
    compress_ctx.wrkmem = wrkmem;

    /* One verified reference compression per block. */
    run_compress(&compress_ctx);
    if (compress_ctx.rc != LZO_E_OK) {
      fprintf(stderr, "error: lzo1x_1_compress failed (%d) for %s %s\n",
              compress_ctx.rc, blocks[i].size_label, blocks[i].kind);
      free(compressed);
      goto cleanup;
    }
    results[i].compressed_len = (size_t)compress_ctx.out_len;

    memset(&decompress_ctx, 0, sizeof(decompress_ctx));
    decompress_ctx.src = compressed;
    decompress_ctx.src_len = results[i].compressed_len;
    decompress_ctx.dst = decoded;
    decompress_ctx.dst_cap = max_size;
    run_decompress(&decompress_ctx);
    if (decompress_ctx.rc != LZO_E_OK ||
        (size_t)decompress_ctx.out_len != blocks[i].size ||
        memcmp(decoded, blocks[i].data, blocks[i].size) != 0) {
      fprintf(stderr, "error: roundtrip mismatch for %s %s\n",
              blocks[i].size_label, blocks[i].kind);
      free(compressed);
      goto cleanup;
    }

    results[i].compress =
        measure(run_compress, &compress_ctx, min_seconds, 5, max_iters);
    results[i].decompress =
        measure(run_decompress, &decompress_ctx, min_seconds, 5, max_iters);
    fprintf(stderr, "bench: %-5s %-7s compress %8.2f MB/s  decompress %8.2f "
                    "MB/s  ratio %.4f\n",
            blocks[i].kind, blocks[i].size_label,
            results[i].compress.ops_per_sec * (double)blocks[i].size / 1e6,
            results[i].decompress.ops_per_sec * (double)blocks[i].size / 1e6,
            (double)results[i].compressed_len / (double)blocks[i].size);
    free(compressed);
  }

  if (out_path != NULL) {
    out = fopen(out_path, "wb");
    if (out == NULL) {
      fprintf(stderr, "error: cannot write \"%s\"\n", out_path);
      goto cleanup;
    }
  }
  if (!emit_report(out, blocks, results)) {
    fprintf(stderr, "error: failed to write the report\n");
    if (out != stdout) fclose(out);
    goto cleanup;
  }
  if (out != stdout && fclose(out) != 0) {
    fprintf(stderr, "error: failed to close the report\n");
    goto cleanup;
  }
  ok = 1;

cleanup:
  free(wrkmem);
  free(decoded);
  free_corpus(blocks);
  return ok ? 0 : 1;
}
