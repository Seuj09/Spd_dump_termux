# Termux / Android host build of TomKing spd_dump (libusb path).
# Pin + Termux FD patches: see PIN.txt and TERMUX.md.
LIBUSB = 1
CFLAGS = -O2 -Wall -Wextra -std=c99 -pedantic -Wno-unused
CFLAGS += -DUSE_LIBUSB=$(LIBUSB)
LIBS = -lm
APPNAME = spd_dump
PIN_SHA1 = f2fc779210d9e4b5ca1904c79a49cc5e114b58f3
PIN_REF = pin/f2fc779+termux-usb

ifeq ($(LIBUSB), 1)
LIBS += -lusb-1.0
endif

.PHONY: all clean
all: GITVER.h $(APPNAME)

clean:
	$(RM) GITVER.h $(APPNAME)

# Prefer real git when this tree is inside Spd_dump_termux; else pin labels.
GITVER.h:
	@if git rev-parse HEAD >/dev/null 2>&1; then \
		echo "#define GIT_VER \"$$(git rev-parse --abbrev-ref HEAD)\"" > GITVER.h; \
		echo "#define GIT_SHA1 \"$$(git rev-parse HEAD)\"" >> GITVER.h; \
	else \
		echo "#define GIT_VER \"$(PIN_REF)\"" > GITVER.h; \
		echo "#define GIT_SHA1 \"$(PIN_SHA1)\"" >> GITVER.h; \
	fi

$(APPNAME): $(APPNAME).c common.c
	$(CC) -s $(CFLAGS) -o $@ $^ $(LIBS)
