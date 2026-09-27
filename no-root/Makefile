# Build on a desktop or inside Termux. Both have pkg-config and libusb.
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_FILE_OFFSET_BITS=64
CPPFLAGS += $(shell pkg-config --cflags libusb-1.0 2>/dev/null)
LDLIBS += $(shell pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0)

SRCS = src/main.c src/usb.c src/proto.c
BIN = spdhost

.PHONY: all clean
all: $(BIN)

$(BIN): $(SRCS) src/usb.h src/proto.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $(SRCS) $(LDLIBS)

clean:
	rm -f $(BIN)
