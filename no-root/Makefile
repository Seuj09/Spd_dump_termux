# Native build. Termux arm32 (armv7l/armv8l) and arm64 (aarch64) use the
# same sources. Do not copy the binary from one architecture to the other.
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64
CFLAGS += -Werror=implicit-function-declaration
CPPFLAGS += $(shell pkg-config --cflags libusb-1.0 2>/dev/null)
LDLIBS += $(shell pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0)

SRCS = src/main.c src/usb.c src/proto.c src/dumpcmd.c src/writecmd.c src/sha256.c
BIN = spdhost
ARCH := $(shell uname -m)

.PHONY: all clean cross-arm32 cross-arm64 cross
all: $(BIN)

$(BIN): $(SRCS) src/usb.h src/proto.h src/dumpcmd.h src/writecmd.h src/sha256.h
	@echo "spdhost: compiling for $(ARCH)"
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $(SRCS) $(LDLIBS)

clean:
	rm -f $(BIN)

# Static ARM builds of spdhost + spd_dump from a PC (no phone, no NDK).
# See scripts/cross-arm32.sh. arm64 is the same script with ARCH=arm64.
# Output: dist/arm32/, dist/arm64/, and dist/spdhost-arm32-arm64-static-<sha>.zip
cross-arm32:
	scripts/cross-arm32.sh
cross-arm64:
	scripts/cross-arm64.sh
cross:
	scripts/cross-both.sh
