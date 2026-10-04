# spdhost FAQ

### Do I need root or a PC?
No. You need Termux, Termux:API (both from F-Droid) and an OTG adapter. See the [tutorial](TUTORIAL.md).

### Which phones are supported?
It's tested on Infinix ums9230 (Unisoc T606 family). FDL sets for other ums9230 brands (Tecno, Realme, itel, universal) and ums512 are included but less tested. Please report your results.

### What's the "host" and what's the "target"?
The host is the phone running Termux. The target is the phone you're flashing, in download mode.

### Detection fails or says `check baud: timeout`. What do I do?

**If the target still boots normally:**
1. Press Ctrl+C to stop the menu while it is still running, then start it again and pick the option.
2. Hold power for about 8 seconds until the target boots.
3. Then hold **power + volume down** with the USB cable plugged in.
4. Wait for the confirmation to appear.

**If the target is bricked and won't turn on:**
1. Unplug the cable and restart the menu.
2. Hold **power + volume down** for 6-8 seconds.
3. Plug in the cable and wait for the confirmation.

Repeat the steps if the error keeps coming back. If it still persists, run:

```sh
SPDHOST_USB_CAPS=1 SPDHOST_BROM_TRACE=1 bash scripts/spdhost-usb ping
```

and report it with the full output.

### Nothing shows up when I plug in.
Your adapter or cable may not switch the host into OTG mode. Try another OTG adapter, and check that OTG is enabled in your host's settings.

### arm32 or arm64 zip?
Run `uname -m`. `aarch64` means arm64, and `armv7l` or `armv8l` means arm32.

### Which FDL files should I use?
Use your brand's folder under `fdl/ums9230/`. If your model has its own `alternatif/<model>` folder, use that. `universal` is the fallback.

### Where do dumps go?
The menu prints the folder after each dump. Every dump comes with a `SHA256SUMS` file so you can check it.

### Can this brick my phone?
Any flasher can. spdhost asks for a typed confirmation before every write, refuses unsafe partition-table writes, protects critical partitions, and backs up `misc` before reboots and slot changes. Always dump first.

### Can I unbrick a phone that won't boot?
If it still enters download mode, usually yes. Flash back your dumped partitions or stock images from the menu.

### Does it work with A/B and non-A/B phones?
A/B is tested. Non-A/B is supported in the code but less tested.

### Reboot to recovery doesn't work on slot B.
That's a known bug in the current beta, and a fix is coming. Use slot A for now.

### Is it the same as spd_dump?
It does the same job and uses the same command logic, rewritten for non-root Termux USB access with extra safety checks.

### Where do I report bugs?
Open an [issue](https://github.com/Seuj09/Spd_dump_termux/issues) with your host phone, target model, FDL folder and the full output.
