# Native build. Termux arm32 (armv7l/armv8l) and arm64 (aarch64) use the
# same sources. Do not copy the binary from one architecture to the other.
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64
CFLAGS += -Werror=implicit-function-declaration
CPPFLAGS += $(shell pkg-config --cflags libusb-1.0 2>/dev/null)
LDLIBS += $(shell pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0)

SRCS = src/main.c src/usb.c src/usb_list.c src/proto.c src/dumpcmd.c \
       src/writecmd.c src/sha256.c src/dhtb.c src/pac.c
HDRS = src/usb.h src/usb_list.h src/proto.h src/dumpcmd.h src/writecmd.h \
       src/sha256.h src/dhtb.h src/pac.h
BIN = spdhost
ARCH := $(shell uname -m)
# P0-2: `spdhost caps` reports the commit it was built from. The stamp file
# is rewritten only when HEAD moves, so a new commit relinks the binary and
# an unchanged tree does not. Outside git it says "unknown".
BUILD_SHA := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
SHA_STAMP = .build-sha

.PHONY: all clean cross-arm32 cross-arm64 cross FORCE
all: $(BIN)

$(SHA_STAMP): FORCE
	@[ "$$(cat $@ 2>/dev/null)" = "$(BUILD_SHA)" ] || echo "$(BUILD_SHA)" > $@

$(BIN): $(SRCS) $(HDRS) $(SHA_STAMP)
	@echo "spdhost: compiling for $(ARCH)"
	$(CC) $(CFLAGS) $(CPPFLAGS) -DSPDHOST_BUILD_SHA='"$(BUILD_SHA)"' -o $@ $(SRCS) $(LDLIBS)

clean:
	rm -f $(BIN) $(SHA_STAMP)

# Static ARM builds of spdhost + spd_dump from a PC (no phone, no NDK).
# See scripts/cross-arm32.sh. arm64 is the same script with ARCH=arm64.
# Output: dist/arm32/, dist/arm64/, and dist/spdhost-arm32-arm64-static-<sha>.zip
cross-arm32:
	scripts/cross-arm32.sh
cross-arm64:
	scripts/cross-arm64.sh
cross:
	scripts/cross-both.sh
