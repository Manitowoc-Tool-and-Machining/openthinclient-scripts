#!/usr/bin/env bash
#
# install-printer.sh
# https://github.com/Manitowoc-Tool-and-Machining/openthinclient-scripts
#
# Multi-vendor USB printer installer for Debian-based thin clients (CUPS).
# Supports: Epson (escpr / escpr2), HP (hplip), Brother (manufacturer drivers).
#
# Usage:
#   sudo ./install-printer.sh                       # auto-detect first USB printer
#   sudo ./install-printer.sh --vendor epson        # force vendor
#   sudo ./install-printer.sh --vendor brother --model HL-L2350DW
#   sudo ./install-printer.sh --name Office-Printer --vendor hp
#   sudo ./install-printer.sh --list                # list detected USB printers and exit
#   sudo ./install-printer.sh --uninstall <name>    # remove a queue
#   sudo ./install-printer.sh --force               # ignore early-exit guard, reinstall
#
# Exit codes:
#   0  success (or already installed and --force not set)
#   1  generic failure
#   2  no USB printer detected
#   3  unsupported / unknown vendor
#   4  driver install failed
#   5  PPD not found
#   6  must be run as root
#
set -euo pipefail

VERSION="1.0.1"

# ---------- Config ----------
LOG_FILE="/var/log/install-printer.log"
EPSON_DEB_URL="https://download3.ebz.epson.net/dsc/f/03/00/16/90/96/951574ae91f5cdc717c8bdce53b1fac5d2dc8a0a/epson-inkjet-printer-escpr2_1.2.31-1_amd64.deb"
EPSON_PPD_FALLBACK="/opt/epson-inkjet-printer-escpr2/ppds/Epson/Epson-ST-M1000_Series-epson-inkjet-printer-escpr2.ppd.gz"
TMP_DIR="$(mktemp -d -t printer-install-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Queue names this script creates — used by the early-exit guard
KNOWN_QUEUE_NAMES=("Epson-Printer" "HP-Printer" "Brother-Printer" "USB-Printer")

# CLI args
VENDOR=""
MODEL=""
QUEUE_NAME=""
LIST_ONLY=0
UNINSTALL=""
SET_DEFAULT=1
FORCE=0

# ---------- Helpers ----------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE" >&2
}

info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
err()   { log "ERROR" "$*"; }
die()   { err "$*"; exit "${2:-1}"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)." 6
    fi
}

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# URL-decode a string (for %20 etc. in USB URIs)
urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# ---------- Argument parsing ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vendor)    VENDOR="${2,,}"; shift 2 ;;
        --model)     MODEL="$2"; shift 2 ;;
        --name)      QUEUE_NAME="$2"; shift 2 ;;
        --list)      LIST_ONLY=1; shift ;;
        --uninstall) UNINSTALL="$2"; shift 2 ;;
        --no-default) SET_DEFAULT=0; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage ;;
        *) die "Unknown argument: $1" 1 ;;
    esac
done

require_root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
info "===== install-printer.sh v$VERSION start ====="

# ---------- Uninstall path ----------
if [[ -n "$UNINSTALL" ]]; then
    info "Removing queue: $UNINSTALL"
    if lpstat -p "$UNINSTALL" &>/dev/null; then
        lpadmin -x "$UNINSTALL"
        info "Removed queue: $UNINSTALL"
        exit 0
    else
        die "Queue '$UNINSTALL' does not exist." 1
    fi
fi

# ---------- Early-exit guard ----------
# If a printer queue created by this script already exists, exit cleanly.
# This makes Autostart=Yes safe — we don't re-run apt-get and reinstall drivers
# on every thin client boot. Override with --force.
if [[ "$LIST_ONLY" -eq 0 && "$FORCE" -eq 0 ]]; then
    if command -v lpstat &>/dev/null; then
        for q in "${KNOWN_QUEUE_NAMES[@]}"; do
            if lpstat -p "$q" &>/dev/null; then
                info "Queue '$q' already configured. Skipping install (use --force to reinstall)."
                exit 0
            fi
        done
        if [[ -n "$QUEUE_NAME" ]] && lpstat -p "$QUEUE_NAME" &>/dev/null; then
            info "Queue '$QUEUE_NAME' already configured. Skipping install (use --force to reinstall)."
            exit 0
        fi
    fi
fi

# ---------- Base packages ----------
ensure_base_packages() {
    info "Updating apt and installing base CUPS packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        cups \
        cups-client \
        cups-bsd \
        libcupsimage2 \
        usbutils \
        curl \
        ca-certificates \
        printer-driver-all \
        >>"$LOG_FILE" 2>&1 || die "Failed to install base packages." 4
    systemctl enable --now cups >>"$LOG_FILE" 2>&1 || warn "Could not enable cups service (may already be running)."
}

# ---------- USB printer detection ----------
# Parses USB device URIs from `lpinfo -v`. The URI itself contains the make and
# model in a reliable, parseable form (e.g. usb://EPSON/ST-M1000%20Series?serial=...),
# so we use that as the source of truth rather than trying to query lpinfo for it.
#
# Returns lines: "VENDOR_KEY|DEVICE_URI|MAKE_MODEL"
detect_usb_printers() {
    while IFS= read -r line; do
        # lpinfo -v output format: "<class> <uri>" e.g. "direct usb://EPSON/ST-M1000%20Series?..."
        [[ "$line" =~ ^direct[[:space:]]+(usb://.+)$ ]] || continue
        local uri="${BASH_REMATCH[1]}"

        # Extract vendor (host part) and model (path part) directly from the URI
        # usb://VENDOR/MODEL?query  →  vendor=VENDOR, model=MODEL
        local raw_vendor="" raw_model=""
        if [[ "$uri" =~ ^usb://([^/]+)/([^?]+) ]]; then
            raw_vendor="${BASH_REMATCH[1]}"
            raw_model="${BASH_REMATCH[2]}"
        else
            continue
        fi

        # URL-decode (handle %20 → space, etc.)
        raw_vendor="$(urldecode "$raw_vendor")"
        raw_model="$(urldecode "$raw_model")"

        local mm="${raw_vendor} ${raw_model}"
        local key="unknown"
        case "${raw_vendor,,}" in
            *epson*)              key="epson" ;;
            *hewlett*|*"hp"*)     key="hp" ;;
            *brother*)            key="brother" ;;
            *canon*)              key="canon" ;;
            *lexmark*)            key="lexmark" ;;
        esac

        # Fallback: some printers report a generic vendor in the URI host but the
        # brand name appears in the model. Sniff the model too if we got nothing.
        if [[ "$key" == "unknown" ]]; then
            case "${raw_model,,}" in
                *epson*)                                                 key="epson" ;;
                *officejet*|*deskjet*|*laserjet*|*envy*|*photosmart*)    key="hp" ;;
                *brother*)                                               key="brother" ;;
                *canon*|*pixma*|*imageclass*)                            key="canon" ;;
                *lexmark*)                                               key="lexmark" ;;
            esac
        fi

        echo "${key}|${uri}|${mm}"
    done < <(lpinfo -v 2>/dev/null)
}

list_printers() {
    info "Scanning for USB printers..."
    local found=0
    while IFS='|' read -r key uri mm; do
        [[ -z "$uri" ]] && continue
        found=1
        echo "  [$key] $mm"
        echo "         URI: $uri"
    done < <(detect_usb_printers)
    if [[ $found -eq 0 ]]; then
        warn "No USB printers detected. Is the printer plugged in and powered on?"
        return 2
    fi
}

# ---------- Vendor-specific installers ----------

install_epson_driver() {
    info "Installing Epson ESC/PR2 driver..."
    if apt-cache show printer-driver-escpr >/dev/null 2>&1; then
        apt-get install -y -qq printer-driver-escpr >>"$LOG_FILE" 2>&1 || warn "printer-driver-escpr install failed; falling back to vendor .deb"
    fi

    local deb="$TMP_DIR/epson-driver.deb"
    info "Downloading Epson escpr2 vendor driver..."
    if curl -fsSL -o "$deb" "$EPSON_DEB_URL"; then
        dpkg -i "$deb" >>"$LOG_FILE" 2>&1 || {
            info "Resolving dependencies for Epson driver..."
            apt-get install -f -y -qq >>"$LOG_FILE" 2>&1
        }
    else
        warn "Could not download Epson vendor driver; relying on distro packages."
    fi
}

install_hp_driver() {
    info "Installing HPLIP for HP printers..."
    apt-get install -y -qq hplip hplip-data printer-driver-hpcups >>"$LOG_FILE" 2>&1 \
        || die "Failed to install hplip." 4
    info "HPLIP installed. Note: some LaserJet Pro / certain inkjets need 'hp-plugin' run interactively."
}

install_brother_driver() {
    info "Configuring Brother printer support..."
    apt-get install -y -qq \
        printer-driver-brlaser \
        printer-driver-ptouch \
        printer-driver-foo2zjs \
        >>"$LOG_FILE" 2>&1 || warn "One or more Brother driver packages failed; continuing."

    if [[ -n "$MODEL" ]]; then
        info "Brother model specified: $MODEL"
        info "If '$MODEL' is not supported by brlaser/foomatic, download the LPR + cupswrapper"
        info "  .deb pair from https://support.brother.com and install with dpkg -i."
    fi
}

# ---------- PPD resolution ----------
# Picks the closest matching PPD for the detected vendor/model from the
# installed PPD database (lpinfo -m). Falls back to known-good defaults.
resolve_ppd() {
    local vendor="$1"
    local mm="$2"
    local ppd=""

    # Pull a model token from the make/model string for fuzzy matching.
    # Examples: "EPSON ST-M1000 Series" → "ST-M1000"
    #           "Brother HL-L2350DW"    → "HL-L2350DW"
    local model_token=""
    model_token="$(echo "$mm" | grep -oE '[A-Z]+-?[A-Z0-9]+([_-][A-Z0-9]+)*' | head -n1 || true)"

    case "$vendor" in
        epson)
            # Try matching the specific model first
            if [[ -n "$model_token" ]]; then
                ppd="$(lpinfo -m 2>/dev/null | grep -i "epson" | grep -i "$model_token" | grep -i "escpr2" | awk '{print $1}' | head -n1)"
                [[ -z "$ppd" ]] && ppd="$(lpinfo -m 2>/dev/null | grep -i "epson" | grep -i "$model_token" | awk '{print $1}' | head -n1)"
            fi
            # Generic Epson escpr2 match
            [[ -z "$ppd" ]] && ppd="$(lpinfo -m 2>/dev/null | grep -i "epson" | grep -i "escpr2" | awk '{print $1}' | head -n1)"
            [[ -z "$ppd" ]] && ppd="$(lpinfo -m 2>/dev/null | grep -i "epson" | awk '{print $1}' | head -n1)"
            # Last-resort: hardcoded fallback PPD installed by the vendor .deb
            if [[ -z "$ppd" && -f "$EPSON_PPD_FALLBACK" ]]; then
                ppd="$EPSON_PPD_FALLBACK"
            fi
            ;;
        hp)
            if [[ -n "$model_token" ]]; then
                ppd="$(lpinfo -m 2>/dev/null | grep -i "hpcups" | grep -i "$model_token" | awk '{print $1}' | head -n1)"
            fi
            [[ -z "$ppd" ]] && ppd="$(lpinfo -m 2>/dev/null | grep -i "hpcups" | awk '{print $1}' | head -n1)"
            [[ -z "$ppd" ]] && ppd="drv:///hp/hpcups.drv/hp-deskjet.ppd"
            ;;
        brother)
            local brother_token="${MODEL:-$model_token}"
            if [[ -n "$brother_token" ]]; then
                ppd="$(lpinfo -m 2>/dev/null | grep -i "brlaser" | grep -i "$brother_token" | awk '{print $1}' | head -n1)"
                [[ -z "$ppd" ]] && ppd="$(lpinfo -m 2>/dev/null | grep -i "brother" | grep -i "$brother_token" | awk '{print $1}' | head -n1)"
            fi
            [[ -z "$ppd" ]] && ppd="$(lpinfo -m 2>/dev/null | grep -i "brlaser" | awk '{print $1}' | head -n1)"
            [[ -z "$ppd" ]] && ppd="$(lpinfo -m 2>/dev/null | grep -i "brother" | awk '{print $1}' | head -n1)"
            [[ -z "$ppd" ]] && ppd="drv:///sample.drv/generic.ppd"
            ;;
        *)
            ppd="drv:///sample.drv/generic.ppd"
            ;;
    esac
    echo "$ppd"
}

# ---------- Queue creation ----------
add_queue() {
    local name="$1"
    local uri="$2"
    local ppd="$3"

    if lpstat -p "$name" &>/dev/null; then
        info "Existing queue '$name' found — replacing it."
        lpadmin -x "$name" || warn "Could not remove existing queue '$name'."
    fi

    info "Creating queue: name='$name' uri='$uri' ppd='$ppd'"
    if [[ -f "$ppd" ]]; then
        lpadmin -p "$name" -v "$uri" -P "$ppd" -E -o printer-is-shared=false
    else
        lpadmin -p "$name" -v "$uri" -m "$ppd" -E -o printer-is-shared=false
    fi

    lpadmin -p "$name" -o media=Letter -o sides=one-sided 2>/dev/null || true
    cupsenable "$name" 2>/dev/null || true
    cupsaccept "$name" 2>/dev/null || true

    if [[ "$SET_DEFAULT" -eq 1 ]]; then
        lpadmin -d "$name"
        info "Set '$name' as default printer."
    fi
}

# ---------- Main ----------
ensure_base_packages

if [[ "$LIST_ONLY" -eq 1 ]]; then
    list_printers || exit 2
    exit 0
fi

info "Detecting USB printers..."
mapfile -t PRINTERS < <(detect_usb_printers)

if [[ ${#PRINTERS[@]} -eq 0 ]]; then
    die "No USB printers detected. Plug in the printer, power it on, and re-run." 2
fi

SELECTED=""
if [[ -n "$VENDOR" ]]; then
    for line in "${PRINTERS[@]}"; do
        if [[ "$line" == "${VENDOR}|"* ]]; then
            SELECTED="$line"
            break
        fi
    done
    if [[ -z "$SELECTED" ]]; then
        warn "No USB printer matching vendor '$VENDOR' found. Detected printers:"
        list_printers || true
        die "Connect the correct printer or omit --vendor to auto-pick." 2
    fi
else
    SELECTED="${PRINTERS[0]}"
    VENDOR="${SELECTED%%|*}"
fi

IFS='|' read -r DETECTED_VENDOR PRINTER_URI PRINTER_MM <<<"$SELECTED"
info "Selected printer: vendor='$DETECTED_VENDOR' model='$PRINTER_MM'"
info "                  URI: $PRINTER_URI"

if [[ -z "$QUEUE_NAME" ]]; then
    case "$DETECTED_VENDOR" in
        epson)   QUEUE_NAME="Epson-Printer" ;;
        hp)      QUEUE_NAME="HP-Printer" ;;
        brother) QUEUE_NAME="Brother-Printer" ;;
        *)       QUEUE_NAME="USB-Printer" ;;
    esac
fi
QUEUE_NAME="$(echo "$QUEUE_NAME" | tr ' /#' '-')"

case "$DETECTED_VENDOR" in
    epson)   install_epson_driver ;;
    hp)      install_hp_driver ;;
    brother) install_brother_driver ;;
    *)       die "Detected vendor '$DETECTED_VENDOR' is not supported by this script. Pass --vendor to override." 3 ;;
esac

PPD="$(resolve_ppd "$DETECTED_VENDOR" "$PRINTER_MM")"
if [[ -z "$PPD" ]]; then
    die "Could not resolve a PPD for $DETECTED_VENDOR / $PRINTER_MM." 5
fi
info "Using PPD: $PPD"

add_queue "$QUEUE_NAME" "$PRINTER_URI" "$PPD"

if lpstat -p "$QUEUE_NAME" &>/dev/null; then
    info "SUCCESS: Queue '$QUEUE_NAME' is ready."
    lpstat -p "$QUEUE_NAME" -l | tee -a "$LOG_FILE"
    info "Test print with:  echo 'CUPS test from install-printer.sh' | lp -d $QUEUE_NAME"
    exit 0
else
    die "Queue '$QUEUE_NAME' did not register with CUPS — check $LOG_FILE." 1
fi
