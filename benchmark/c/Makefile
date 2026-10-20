# liblzo2 benchmark harness for lzo_neo.
#
# The default target assumes the distribution package:
#
#     sudo apt-get install -y liblzo2-dev
#     make -C benchmark/c
#     ./benchmark/c/lzo_bench --text README.md --out build/bench/liblzo2-c.json
#
# Point it at any other liblzo2 prefix (include/lzo/*.h + lib/liblzo2.a) with:
#
#     make -C benchmark/c LZO_PREFIX=/opt/lzo-2.10

LZO_PREFIX ?= /usr

CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra
CPPFLAGS += -I$(LZO_PREFIX)/include
LDFLAGS  += -L$(LZO_PREFIX)/lib
LDLIBS   += -llzo2 -lm

lzo_bench: bench.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ bench.c $(LDLIBS)

clean:
	rm -f lzo_bench

.PHONY: clean
