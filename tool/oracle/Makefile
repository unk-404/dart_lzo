# Build the liblzo2 oracle CLI.
#
# The reference library is never vendored into this repository. Point the build
# at an installed liblzo2 2.10 or at a source-tree build:
#
#   make LZO_PREFIX=/opt/lzo-2.10                 # <prefix>/include, <prefix>/lib
#   make LZO_INCLUDE=/path/include LZO_LIBDIR=/path/src/.libs
#
# The CI differential job builds lzo 2.10 from the official tarball and passes
# LZO_PREFIX.

CC ?= cc
CFLAGS ?= -O2 -std=c99 -Wall -Wextra -Wpedantic
LZO_PREFIX ?= /usr/local
LZO_INCLUDE ?= $(LZO_PREFIX)/include
LZO_LIBDIR ?= $(LZO_PREFIX)/lib

CPPFLAGS += -I$(LZO_INCLUDE)
LDFLAGS += -L$(LZO_LIBDIR)
LDLIBS += -llzo2

TARGET := lzo_oracle

all: $(TARGET)

$(TARGET): lzo_oracle.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ lzo_oracle.c $(LDFLAGS) $(LDLIBS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
