# Native build. Termux arm32 (armv7l/armv8l) and arm64 (aarch64) use the
# same sources. Do not copy the binary from one architecture to the other.
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64
CPPFLAGS += $(shell pkg-config --cflags libusb-1.0 2>/dev/null)
LDLIBS += $(shell pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0)

SRCS = src/main.c src/usb.c src/proto.c src/dumpcmd.c
BIN = spdhost
ARCH := $(shell uname -m)

.PHONY: all clean cross-arm32
all: $(BIN)

$(BIN): $(SRCS) src/usb.h src/proto.h src/dumpcmd.h
	@echo "spdhost: compiling for $(ARCH)"
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $(SRCS) $(LDLIBS)

clean:
	rm -f $(BIN)

# Static 32-bit ARM build of spdhost + spd_dump from a PC (no phone, no NDK).
# See scripts/cross-arm32.sh for requirements. Output: dist/arm32/
cross-arm32:
	scripts/cross-arm32.sh
