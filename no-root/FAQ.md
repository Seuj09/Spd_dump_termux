# spdhost FAQ

### Do I need root or a PC?
No. You need Termux, Termux:API (both from F-Droid) and an OTG adapter. See the [tutorial](TUTORIAL.md).

### Which phones are supported?
It's tested on Infinix ums9230 (Unisoc T606 family). FDL sets for other ums9230 brands (Tecno, Realme, itel, universal), ums512, and sc9863a (itel, realme) are included but less tested. Please report your results.

### What's the "host" and what's the "target"?
The host is the phone running Termux. The target is the phone you're flashing, in download mode.

### Detection fails or says `check baud: timeout`. What do I do?

**If the target still boots normally:**
1. Press Ctrl+C to stop the menu while it is still running, then start it again and pick the option.
2. Hold power for about 8 seconds until the target boots.
3. Wait until the menu says **Plug the target in NOW**.
4. Only then hold the target's download-mode keys and plug the cable in. On many Unisoc phones (Infinix, for example) that is **power + volume down**; other models use volume up, both volume keys, or a boot key, so use whatever your model needs.
5. Tap Allow on the permission dialog as soon as it appears (it appears on every plug-in).

**If the target is bricked and won't turn on:**
1. Unplug the cable and restart the menu.
2. Hold the download-mode keys (on Infinix and many other Unisoc phones **power + volume down**; check your model) for 6-8 seconds.
3. Plug in the cable and wait for the confirmation.

Repeat the steps if the error keeps coming back. If it still persists, run:

```sh
SPDHOST_USB_CAPS=1 SPDHOST_BROM_TRACE=1 bash scripts/spdhost-usb ping
```

and report it with the full output.

### The menu stopped in the middle of an option. Do I need to replug?
Some options run in more than one USB session, for example to ask for a typed confirmation or to back up and check `misc`. Between sessions, the target has to reconnect.

- **If the menu asks you to confirm, or shows the plug-in message:** reconnect the target using the steps in the timeout answer above. Use the booting-target steps if it still boots, and the bricked-target steps if it doesn't.
- **If it pauses without either of those:** don't unplug. That's just the tool doing its work, so wait for it to finish.

### Nothing shows up when I plug in.
Your adapter or cable may not switch the host into OTG mode. Try another OTG adapter, and check that OTG is enabled in your host's settings.

### "Display over other apps" is greyed out or disabled for Termux:API.
`SYSTEM_ALERT_WINDOW` is an **app-op**, not a runtime permission: `pm grant … SYSTEM_ALERT_WINDOW` fails ("not a changeable permission type"), and Termux's own uid cannot grant it either.

From a PC with adb (or wireless adb / Shizuku):

```sh
adb shell appops set com.termux.api SYSTEM_ALERT_WINDOW allow
```

Or open **Settings → Apps → Termux:API → Display over other apps** and allow it there. Root-only alternative: `su -c 'appops set com.termux.api SYSTEM_ALERT_WINDOW allow'`.

### arm32 or arm64 zip?
Run `uname -m`. `aarch64` means arm64, and `armv7l` or `armv8l` means arm32.

### Which FDL files should I use?
Pick your **chip first** (menu option 3, or the first-run wizard). Then use your brand's folder under `fdl/<chip>/` (for example `fdl/ums9230/infinix` or `fdl/sc9863a/...`). If your model has its own `alternatif/<model>` folder, use that. `universal` exists **only for ums9230** as a fallback for that chip — do not use a ums9230 loader on sc9863a or ums512.

### Where do dumps go?
The menu prints the folder after each dump (by default `/sdcard/Download`; `backup/` in the unzipped folder without storage permission). Partition images (`NAME.img`) stay alone at the top of that folder, and they are the only files the flash menus [6]/[7]/[9] offer. Everything else goes under `meta/` inside it: `SHA256SUMS`, the parts table (`partition_list.txt`, `partition_bytes.txt`), `dump-manifest.txt`, `partition_*.xml` / `partitions-*.xml`, `sprdpart.bin` / `pgpt.bin`, `misc-slotinfo.img`, Extra [14]'s `*-slota.img` / `*-slotb.img`, and the `*-before-*.img` backups (misc, persist, frp, vbmeta, splloader). Older dumps that still have those files at the top of the dump folder keep working.

To check a dump, run this **from the dump folder** (the names in `SHA256SUMS` are relative to it, so running it inside `meta/` fails):

```sh
cd /sdcard/Download && sha256sum -c meta/SHA256SUMS
```

### Can Extra [16] (PAC extract) overwrite my dumps?
No. It never deletes or replaces the output folder you type. A missing or empty folder receives the entries; any other folder (for example the dump folder itself) gets a new `pac-extract-<date>-<time>` subfolder, and nothing already in it is touched.


### A cable blip mid-dump or mid-flash aborted the transfer. Will it resume?
No. Mid-transfer reconnect is **deferred** (not implemented). If the phone resets or the cable drops during a read or write, that partition is not resumed — replug and run the same option again. `--keep-going` only continues after a failed **read**; a failed **write** always stops the plan (by design).

### Can this brick my phone?
Any flasher can. spdhost asks for a typed confirmation before every write, refuses unsafe partition-table writes, protects critical partitions, and backs up `misc` before reboots and slot changes. Always dump first.

### Can I unbrick a phone that won't boot?
If it still enters download mode, usually yes. Flash back your dumped partitions or stock images from the menu.

### My phone bootloops after I repartitioned.
Repartitioning wipes `super`, so after a repartition you **must** flash a `super.img` (menu [8] reminds you before and after; the old table is saved as `meta/partition_<unixtime>.xml`). Skipping it leaves `super` empty or mismatched, so system, vendor and product can't mount and the phone bootloops. This isn't a tool bug: any repartition that touches `super` needs a matching `super.img` flash.

- **If you changed `super`'s size:** flash a `super.img` built for the new size. Rebuild it with `lpmake` or resize it. The stock `super.img` is sized for the stock `super` and won't boot in a differently sized one.
- **If you didn't change `super`'s size:** flash the stock `super.img` again.

Changing the size of `super` doesn't break boot by itself. The empty or mismatched `super` does.

### Does it work with A/B and non-A/B phones?
A/B is tested. Non-A/B is supported in the code but less tested.

### Reboot to recovery doesn't work on slot B.
That's a known bug in the current beta, and a fix is coming. Use slot A for now.

### Reset FRP asks "Which partition holds FRP?"
Your partition table has both `frp` and `persist`, and which one holds FRP depends on the phone. On the target (while it still boots), `getprop ro.frp.pst` names it; answer `frp` or `persist`. There is no default: Enter cancels, nothing is sent. Outside the menu, set `SPDHOST_FRP_PART=frp` or `SPDHOST_FRP_PART=persist`; spdhost refuses a table with both rows without it. A backup of the erased partition is always taken first.

### Is it the same as spd_dump?
It does the same job and uses the same command logic, rewritten for non-root Termux USB access with extra safety checks.


### Where do I report bugs?
Open an [issue](https://github.com/Seuj09/Spd_dump_termux/issues) with your host phone, target model, FDL folder and the full output.
