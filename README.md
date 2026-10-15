# openthinclient-scripts

Scripts and tooling for [openthinclient](https://openthinclient.com/)-based thin clients running Debian. Maintained by Manitowoc Tool & Machining IT.

## Contents

| Script | Purpose |
| --- | --- |
| [`install-printer.sh`](#install-printersh) | Multi-vendor USB printer installer for CUPS (Epson, HP, Brother) |
| [`build-bundle.sh`](#build-bundlesh) | Builds the offline driver bundle and stages it on an openthinclient Manager |

---

## install-printer.sh

Auto-detects a connected USB printer, installs the appropriate vendor driver stack, and configures a CUPS queue. Designed to run unattended on Debian-based thin clients (openthinclient runs on Debian 13 "Trixie" as of openthinclient 2603+).

### Supported vendors

| Vendor | Drivers installed | Notes |
| --- | --- | --- |
| **Epson** | `printer-driver-escpr` (distro) + `epson-inkjet-printer-escpr2` (vendor .deb) | Vendor `escpr2` driver pulled directly from Epson. Required for newer models (ST-M1000, ET series) not covered by distro `escpr`. |
| **HP** | `hplip`, `hplip-data`, `printer-driver-hpcups` | Some LaserJet Pro / inkjets need `hp-plugin` (proprietary firmware blob) which requires interactive EULA acceptance — flagged in script log. |
| **Brother** | `printer-driver-brlaser`, `printer-driver-foo2zjs`, `printer-driver-ptouch` | Most modern Brother lasers/MFCs work with `brlaser`. Older or specialty models need vendor LPR + cupswrapper .deb pair from [support.brother.com](https://support.brother.com). |

Canon and Lexmark printers are detected and reported but **not** installed automatically — pass `--vendor` to override at your own risk.

### Usage

```bash
# Auto-detect and install the first USB printer found
sudo ./install-printer.sh

# List detected USB printers without installing anything
sudo ./install-printer.sh --list

# Force a vendor (useful if multiple USB printers attached)
sudo ./install-printer.sh --vendor brother --model HL-L2350DW

# Custom queue name, do not set as default printer
sudo ./install-printer.sh --name Shop-Floor-Printer --no-default

# Force reinstall (skip the early-exit guard)
sudo ./install-printer.sh --force

# Ignore the offline bundle and install from apt / vendor downloads
sudo ./install-printer.sh --online

# Remove a queue
sudo ./install-printer.sh --uninstall Epson-Printer
```

### Behavior

- **Offline by default on the shop floor.** If `/opt/mtm-printer/debs/*.deb` exists (delivered by the openthinclient custom folder, see [build-bundle.sh](#build-bundlesh)), CUPS and every vendor driver are installed from there with `dpkg` and **no network is used**: no `apt-get`, no Epson download, no GitHub fetch. `--online` forces the old apt path; `--bundle-dir <dir>` points at another bundle.
- **Idempotent.** If a printer queue created by this script (`Epson-Printer`, `HP-Printer`, `Brother-Printer`, `USB-Printer`) already exists, the script exits 0 without reinstalling. Use `--force` to override.
- **Logged.** All output is written to `/var/log/install-printer.log` with timestamps. Always check this first when troubleshooting.
- **Default queue names** per vendor: `Epson-Printer`, `HP-Printer`, `Brother-Printer`. Override with `--name`.
- **Sets the new printer as default** unless `--no-default` is passed.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success (or already installed and `--force` not set) |
| 1 | Generic failure |
| 2 | No USB printer detected |
| 3 | Unsupported / unknown vendor |
| 4 | Driver package install failed |
| 5 | PPD could not be resolved |
| 6 | Not run as root |

---

## build-bundle.sh

Builds `mtm-printer.tar.gz`, the offline bundle that makes `install-printer.sh` work with no network. Run it **on an openthinclient Manager server** as the `openthinclient` user:

```bash
sudo apt-get install -y squashfs-tools wget
./build-bundle.sh            # build and stage into <Manager-Home>/nfs/root/custom/packages/
./build-bundle.sh --no-stage # build only
```

What it does:

1. Finds the newest `base_<ver>/base.sfs` the Manager serves and pulls the **thin client's** `dpkg` status, apt sources and archive keys out of it.
2. Runs `apt-get install --download-only` against that package database (not the server's own) to get the exact Debian 13 dependency closure for `cups`, `cups-filters`, `printer-driver-escpr`, `hplip`, `printer-driver-hpcups`, `printer-driver-postscript-hp`, `printer-driver-brlaser`, `printer-driver-ptouch`, `printer-driver-foo2zjs`.
3. Downloads the Epson ESC/P-R 2 vendor `.deb`.
4. Packs `opt/mtm-printer/install-printer.sh`, `opt/mtm-printer/debs/*.deb` and a `MANIFEST` into a root-owned `tar.gz` (about 18 MB).
5. Installs it as `<Manager-Home>/nfs/root/custom/packages/mtm-printer.tar.gz`.

How it reaches the units: the thin client initrd extracts every tar in `custom/packages/` into the root filesystem at boot, before Debian starts (`mountcustom` in `init_functions`). On localboot units the updater (`Localboot > Activate client update = Yes`) rsyncs `custom/` from the Manager every 10 minutes and the new content is applied on the unit's next boot. Each Manager has its own custom folder, so copy the tar to every server (or run the build on each).

Re-run after a **base** package update on the Manager, because the closure is computed against the client package database in that image. Loose `.deb` files in `custom/packages/` are ignored by the client; only tar archives are processed.

## Deployment

### openthinclient — Command line application

Create a Command line application in the openthinclient management console with:

- **Type:** Command line
- **Autostart:** Yes (safe — script no-ops if a queue is already configured)
- **Hide icon:** Yes
- **Elevated privileges:** Allow sudo

**Command line field** (offline bundle, recommended; requires `mtm-printer.tar.gz` staged on that Manager):

```bash
sudo /opt/mtm-printer/install-printer.sh
```

The script is part of the bundle, so a new script version ships by rebuilding and restaging the bundle, not by changing this field.

**Command line field** (online fallback, pinned to a release tag; needs WiFi up and internet egress at autostart time):

```bash
sh -c 'set -e; TMP=$(mktemp); curl -fsSL https://raw.githubusercontent.com/Manitowoc-Tool-and-Machining/openthinclient-scripts/v1.0.0/install-printer.sh -o "$TMP" && chmod +x "$TMP" && sudo "$TMP"; rc=$?; rm -f "$TMP"; exit $rc'
```

**Or pinned to a specific commit SHA** (most secure — can't be changed without an explicit redeploy):

```bash
sh -c 'set -e; TMP=$(mktemp); curl -fsSL https://raw.githubusercontent.com/Manitowoc-Tool-and-Machining/openthinclient-scripts/<commit-sha>/install-printer.sh -o "$TMP" && chmod +x "$TMP" && sudo "$TMP"; rc=$?; rm -f "$TMP"; exit $rc'
```

**Avoid pinning to `main`** — a bad commit on `main` would propagate to every thin client on next boot.

### Manual install on a thin client

```bash
curl -fsSL -o /tmp/install-printer.sh https://raw.githubusercontent.com/Manitowoc-Tool-and-Machining/openthinclient-scripts/main/install-printer.sh
chmod +x /tmp/install-printer.sh
sudo /tmp/install-printer.sh
```

### PXE boot vs. local boot

Critical distinction:

- **Local-boot thin clients** (e.g., GMKtec NucBox G3S running Debian 13 directly): run this script once during provisioning. Changes persist.
- **PXE-booted thin clients**: anything installed at runtime is wiped on reboot because the OS is delivered fresh from the openthinclient server image. For these clients, CUPS and the vendor drivers must be **baked into the openthinclient base image / application profile**. Use this script as a reference for what packages and PPDs to include, not as a runtime install.

### Required network access

The thin client must reach:

- `archive.ubuntu.com` / `deb.debian.org` — base packages (`cups`, `libcupsimage2`, `printer-driver-*`, `hplip`)
- `download3.ebz.epson.net` — Epson vendor `escpr2` .deb
- `raw.githubusercontent.com` — to fetch this script (only when using the one-liner deployment)
- `support.brother.com` — only if a specific Brother model needs vendor LPR/cupswrapper pair (manual step)

If thin clients are on a restricted VLAN, either pre-stage the .deb files locally or whitelist the above domains.

---

## Troubleshooting

**"No USB printer detected" (exit 2)**
The printer must be plugged in and powered on before the script runs. Verify with `lsusb` and `lpinfo -v | grep usb`.

**Script reports success but printing fails**
Check `/var/log/cups/error_log` and the script's own log at `/var/log/install-printer.log`. Common causes: wrong PPD selected (script picks the closest match — may not be exact), printer offline, or HP printer needing `hp-plugin` firmware blob.

**"Queue 'X' already configured. Skipping install" but printer doesn't work**
The early-exit guard saw an existing queue. Reinstall with `--force`:
```bash
sudo ./install-printer.sh --force
```

**HP LaserJet Pro / certain HP inkjets fail to print**
These models require `hp-plugin`, which downloads a proprietary firmware blob and requires interactive EULA acceptance. SSH into the thin client and run `sudo hp-plugin -i` manually.

**Brother model not supported by `brlaser`**
Download the LPR + cupswrapper .deb pair for the specific model from [support.brother.com](https://support.brother.com), copy them to the thin client, and install:
```bash
sudo dpkg -i <model>-lpr-*.deb <model>-cupswrapper-*.deb
sudo ./install-printer.sh --force
```

---

## Versioning

This repo uses [Semantic Versioning](https://semver.org/) for tagged releases. Pin the openthinclient deployment to a specific tag (e.g. `v1.0.0`) rather than `main` to avoid surprise deployments.

| Version | Notes |
| --- | --- |
| 1.1.0 | Offline mode: installs from `/opt/mtm-printer/debs` with `dpkg` when present; `--online`, `--bundle-dir`. New `build-bundle.sh`. Fixes the localboot autostart race (script ran before WiFi associated). |
| 1.0.4 | PPD token matching emits the digit-core model id (M402) so family-named PostScript PPDs resolve. |
| 1.0.3 | SIGPIPE exit-141 fix; PostScript LaserJet PPD support (`printer-driver-postscript-hp`). |
| 1.0.2 | Better PPD model matching; refuse a generic PPD instead of silently falling back. |
| 1.0.1 | Vendor detection parses the USB URI directly. |
| 1.0.0 | Initial release. Multi-vendor support (Epson, HP, Brother), early-exit guard, structured logging, CLI args. |

---

## License

MIT — see [LICENSE](LICENSE).

## Maintainers

Manitowoc Tool & Machining — IT
