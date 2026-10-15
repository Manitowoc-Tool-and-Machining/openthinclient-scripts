#!/usr/bin/env bash
#
# build-bundle.sh
# https://github.com/Manitowoc-Tool-and-Machining/openthinclient-scripts
#
# Builds the offline printer bundle (mtm-printer.tar.gz) for openthinclient
# localboot units and stages it in the Manager's custom/packages folder.
#
# Run ON an openthinclient Manager server (Debian appliance) as the
# openthinclient user. Needs: unsquashfs (squashfs-tools), apt-get, wget, tar,
# sudo. Outbound HTTPS to deb.debian.org, security.debian.org and
# download3.ebz.epson.net.
#
# What it does:
#   1. Finds the newest base_<ver>/base.sfs the Manager is serving and pulls the
#      thin client's dpkg status, apt sources and archive keys out of it.
#   2. Runs apt against THAT package database (not the server's) to compute the
#      exact Debian 13 dependency closure for CUPS + Epson/HP/Brother drivers,
#      and downloads the .debs.
#   3. Downloads the Epson ESC/P-R 2 vendor .deb.
#   4. Packs install-printer.sh + all .debs into
#        opt/mtm-printer/install-printer.sh
#        opt/mtm-printer/debs/*.deb
#      as a root-owned tar.gz.
#   5. Copies it to <Manager-Home>/nfs/root/custom/packages/mtm-printer.tar.gz
#      (the thin client initrd extracts every tar in custom/packages into the
#      root filesystem at boot, before Debian starts; the localboot updater
#      rsyncs custom/ to every unit, applied on its next boot).
#
# Usage:
#   ./build-bundle.sh                       # build + stage on this server
#   ./build-bundle.sh --no-stage            # build only, leave tar in work dir
#   ./build-bundle.sh --work-dir /tmp/x     # custom work dir
#
# Re-run after a base package update on the Manager so the closure is computed
# against the new client package database.
#
set -euo pipefail

MANAGER_HOME="${MANAGER_HOME:-/home/openthinclient/otc-manager-home}"
WORK_DIR="${WORK_DIR:-/tmp/mtm-printer-bundle}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install-printer.sh"
BUNDLE_NAME="mtm-printer.tar.gz"
STAGE=1

EPSON_DEB_URL="https://download3.ebz.epson.net/dsc/f/03/00/16/90/96/951574ae91f5cdc717c8bdce53b1fac5d2dc8a0a/epson-inkjet-printer-escpr2_1.2.31-1_amd64.deb"

# Packages the thin client needs on top of its base image. Keep in sync with
# install-printer.sh (ensure_base_packages + the vendor installers).
PACKAGES=(
    cups
    cups-filters
    printer-driver-escpr
    hplip
    printer-driver-hpcups
    printer-driver-postscript-hp
    printer-driver-brlaser
    printer-driver-ptouch
    printer-driver-foo2zjs
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-stage)   STAGE=0; shift ;;
        --work-dir)   WORK_DIR="$2"; shift 2 ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for t in unsquashfs apt-get wget tar dpkg-deb; do
    command -v "$t" >/dev/null || die "Missing tool: $t (apt-get install squashfs-tools wget)"
done
[[ -f "$INSTALL_SCRIPT" ]] || die "install-printer.sh not found next to this script"

# ---------- 1. Client package database from base.sfs ----------
BASE_SFS="$(ls -1d "$MANAGER_HOME"/nfs/root/packages/base_*/base.sfs 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "$BASE_SFS" ]] || die "No base_*/base.sfs under $MANAGER_HOME/nfs/root/packages"
log "Client base image: $BASE_SFS"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{base,apt/state/lists/partial,apt/cache/archives/partial,apt/etc,stage/opt/mtm-printer/debs}
cd "$WORK_DIR"

sudo unsquashfs -n -q -d base "$BASE_SFS" \
    var/lib/dpkg/status etc/apt etc/debian_version >/dev/null
sudo chown -R "$(id -u):$(id -g)" base
log "Client Debian version: $(cat base/etc/debian_version)"

# Build a plain sources.list from the client's deb822 .sources files
python3 - base/etc/apt/sources.list.d > apt/etc/sources.list <<'PY'
import sys, glob, re
for f in sorted(glob.glob(sys.argv[1] + '/*.sources')):
    for stanza in open(f).read().split('\n\n'):
        kv = {}
        for line in stanza.splitlines():
            if ':' in line and not line.startswith('#'):
                k, v = line.split(':', 1); kv[k.strip()] = v.strip()
        if kv.get('Types') != 'deb': continue
        for uri in kv['URIs'].split():
            for suite in kv['Suites'].split():
                if 'backports' in suite: continue
                print(f"deb {uri} {suite} {kv['Components']}")
PY
log "Client apt sources:"; sed 's/^/    /' apt/etc/sources.list >&2

APT=(apt-get
    -o Dir::State="$WORK_DIR/apt/state"
    -o Dir::State::status="$WORK_DIR/base/var/lib/dpkg/status"
    -o Dir::Cache="$WORK_DIR/apt/cache"
    -o Dir::Etc::sourcelist="$WORK_DIR/apt/etc/sources.list"
    -o Dir::Etc::sourceparts=-
    -o Dir::Etc::preferences=- -o Dir::Etc::preferencesparts=-
    -o Dir::Etc::trusted=- -o Dir::Etc::trustedparts="$WORK_DIR/base/etc/apt/trusted.gpg.d"
    -o APT::Architecture=amd64
    -o Debug::NoLocking=1
    -o APT::Get::List-Cleanup=0)

# ---------- 2. Dependency closure ----------
log "apt update against client sources..."
"${APT[@]}" update -qq 2>&1 | grep -v "Unable to read /etc/apt/-/" || true
log "Resolving + downloading: ${PACKAGES[*]}"
"${APT[@]}" install --download-only -y --no-install-recommends "${PACKAGES[@]}" 2>&1 \
    | grep -v "^Get:\|Unable to read /etc/apt/-/" >&2
cp apt/cache/archives/*.deb stage/opt/mtm-printer/debs/

# ---------- 3. Epson vendor driver ----------
log "Downloading Epson ESC/P-R 2 driver..."
wget -q -O "stage/opt/mtm-printer/debs/$(basename "$EPSON_DEB_URL")" "$EPSON_DEB_URL"

# ---------- 4. Pack ----------
install -m 0755 "$INSTALL_SCRIPT" stage/opt/mtm-printer/install-printer.sh
chmod 0644 stage/opt/mtm-printer/debs/*.deb
{
    echo "built: $(date -Is) on $(hostname)"
    echo "base: $(basename "$(dirname "$BASE_SFS")")"
    echo "client debian: $(cat base/etc/debian_version)"
    echo "install-printer.sh: $(grep -m1 '^VERSION=' "$INSTALL_SCRIPT")"
    echo "debs:"; ls stage/opt/mtm-printer/debs | sed 's/^/  /'
} > stage/opt/mtm-printer/MANIFEST
tar --owner=0 --group=0 --numeric-owner -C stage -czf "$BUNDLE_NAME" opt
log "Bundle: $WORK_DIR/$BUNDLE_NAME ($(du -h "$BUNDLE_NAME" | cut -f1), $(ls stage/opt/mtm-printer/debs | wc -l) debs)"

# ---------- 5. Stage ----------
if [[ "$STAGE" -eq 1 ]]; then
    DEST="$MANAGER_HOME/nfs/root/custom/packages/$BUNDLE_NAME"
    sudo install -o root -g root -m 0644 "$BUNDLE_NAME" "$DEST"
    log "Staged: $DEST"
    log "Units pick it up on their next updater run (every 10 min) and apply it at the next boot."
fi
