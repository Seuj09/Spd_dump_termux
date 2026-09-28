# TomKing spd_dump (Termux)

Vendored [TomKing062/spreadtrum_flash](https://github.com/TomKing062/spreadtrum_flash)
at pin `f2fc779`, with Termux `termux-usb` FD adopt patches.

| | |
| --- | --- |
| Build | `make` (needs `clang`, `libusb`) |
| Wrapper | `scripts/spd_dump-usb` |
| Guide | [TERMUX.md](TERMUX.md) |
| Pin | [PIN.txt](PIN.txt) |
| FDL example | [`../fdl/ums9230/infinix/`](../fdl/ums9230/infinix/) |

This is the **full** TomKing client (BootROM→FDL path). For the smaller
Seuj09-native client with BootROM hello hardening, use sibling **spdhost**
under [`../`](../).
