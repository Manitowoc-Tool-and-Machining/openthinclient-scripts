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
#   sudo ./install-printer.sh --allow-generic-ppd   # accept generic-fallback PPD instead of failing
#
# Exit codes:
#   0  success (or already installed and --force not set)
#   1  generic failure
#   2  no USB printer detected
#   3  unsupported / unknown vendor
#   4  driver install failed
#   5  PPD not found (or only generic fallback available; pass --allow-generic-ppd to accept)
#   6  must be run as root
#
# Changelog:
#   1.0.4 - PPD token matching now emits BOTH the full model id (e.g. "M402dn") and
#           the digit-core ("M402"). HP names family PPDs like "M402-M403", which the
#           full id does not substring-match but the core does. Without this, a
#           PostScript LaserJet with only a family-named PPD still failed to resolve.
#   1.0.3 - Fixed exit-141 (SIGPIPE) bug: the "Available PPDs" reference listing
#           tripped `set -e`/`pipefail` when `head` closed the pipe, so the script
#           aborted with 141 before reaching its intended `exit 5`. Pipeline is now
#           guarded so callers get the correct exit code.
#         - HP PPD resolution now also matches PostScript PPDs. PS-capable LaserJet
#           Pro models (e.g. M402dn) don't ship a free hpcups PPD but print correctly
#           on their native PostScript PPD. install_hp_driver now installs
#           printer-driver-postscript-hp, and the HP generic fallback is a PostScript
#           PPD instead of an inkjet (hp-deskjet) PPD.
#         - Model-token regex now captures lowercase suffixes (e.g. "M402dn").
#   1.0.2 - Prior release.
#
set -euo pipefail

VERSION="1.0.4"

# ---------- Config ----------
LOG_FILE="/var/log/install-printer.log"
EPSON_DEB_URL="https://download3.ebz.epson.net/dsc/f/03/00/16/90/96/951574ae91f5cdc717c8bdce53b1fac5d2dc8a0a/epson-inkjet-printer-escpr2_1.2.31-1_amd64.deb"
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
ALLOW_GENERIC=0

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
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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
        --vendor)             VENDOR="${2,,}"; shift 2 ;;
        --model)              MODEL="$2"; shift 2 ;;
        --name)               QUEUE_NAME="$2"; shift 2 ;;
        --list)               LIST_ONLY=1; shift ;;
        --uninstall)          UNINSTALL="$2"; shift 2 ;;
        --no-default)         SET_DEFAULT=0; shift ;;
        --force)              FORCE=1; shift ;;
        --allow-generic-ppd)  ALLOW_GENERIC=1; shift ;;
        -h|--help)            usage ;;
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
# Returns lines: "VENDOR_KEY|DEVICE_URI|RAW_VENDOR|RAW_MODEL"
# (RAW_VENDOR/RAW_MODEL are URL-decoded; downstream code uses them directly.)
detect_usb_printers() {
    while IFS= read -r line; do
        [[ "$line" =~ ^direct[[:space:]]+(usb://.+)$ ]] || continue
        local uri="${BASH_REMATCH[1]}"

        local raw_vendor="" raw_model=""
        if [[ "$uri" =~ ^usb://([^/]+)/([^?]+) ]]; then
            raw_vendor="${BASH_REMATCH[1]}"
            raw_model="${BASH_REMATCH[2]}"
        else
            continue
        fi

        raw_vendor="$(urldecode "$raw_vendor")"
        raw_model="$(urldecode "$raw_model")"

        local key="unknown"
        case "${raw_vendor,,}" in
            *epson*)              key="epson" ;;
            *hewlett*|*"hp"*)     key="hp" ;;
            *brother*)            key="brother" ;;
            *canon*)              key="canon" ;;
            *lexmark*)            key="lexmark" ;;
        esac

        if [[ "$key" == "unknown" ]]; then
            case "${raw_model,,}" in
                *epson*)                                                 key="epson" ;;
                *officejet*|*deskjet*|*laserjet*|*envy*|*photosmart*)    key="hp" ;;
                *brother*)                                               key="brother" ;;
                *canon*|*pixma*|*imageclass*)                            key="canon" ;;
                *lexmark*)                                               key="lexmark" ;;
            esac
        fi

        echo "${key}|${uri}|${raw_vendor}|${raw_model}"
    done < <(lpinfo -v 2>/dev/null)
}

list_printers() {
    info "Scanning for USB printers..."
    local found=0
    while IFS='|' read -r key uri rv rm; do
        [[ -z "$uri" ]] && continue
        found=1
        echo "  [$key] ${rv} ${rm}"
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
    # Many LaserJet Pro models (e.g. M402dn) don't ship a free hpcups PPD but have
    # native PostScript level 3 emulation. This package provides matching PS PPDs so
    # resolve_ppd can find a model-specific, non-blank-page driver without hp-plugin.
    apt-get install -y -qq printer-driver-postscript-hp >>"$LOG_FILE" 2>&1 \
        || warn "printer-driver-postscript-hp unavailable; PostScript-only LaserJets may not resolve a PPD."
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
# Build candidate model tokens from a model string like "ST-M1000 Series" and
# try each one against the installed PPD database, preferring more-specific
# matches. Returns the first PPD that matches a real model token.
#
# Output to stdout: "<ppd>|<match_quality>"
#   match_quality: "exact"  — matched a model-specific PPD
#                  "generic" — only a generic vendor PPD found (caller decides)
#                  ""        — nothing usable
resolve_ppd() {
    local vendor="$1"
    local raw_model="$2"

    # Build a list of token candidates from the model string, ordered most-specific first.
    # Examples:
    #   "ST-M1000 Series" → ["ST-M1000", "M1000", "ST-M1000 Series", "ST"]
    #   "HL-L2350DW"      → ["HL-L2350DW", "L2350DW", "HL-L2350"]
    #   "LaserJet M402dn" → ["LaserJet M402dn", "M402dn", "M402"]
    local -a tokens=()

    # The whole trimmed model, with "Series" stripped (CUPS PPDs sometimes don't include it)
    local trimmed="${raw_model%% Series}"
    trimmed="${trimmed% Series}"
    [[ -n "$trimmed" ]] && tokens+=("$trimmed")
    [[ "$trimmed" != "$raw_model" && -n "$raw_model" ]] && tokens+=("$raw_model")

    # Hyphenated model identifier (the most distinctive token in most cases): ST-M1000, HL-L2350DW
    local hyphenated
    hyphenated="$(echo "$raw_model" | grep -oE '[A-Z]+-[A-Z0-9]+' | head -n1 || true)"
    [[ -n "$hyphenated" ]] && tokens+=("$hyphenated")

    # Numeric model identifier WITH any suffix: M1000, L2350DW, 8025, M402dn.
    # Trailing letters may be lowercase on some models (M402dn), so allow either case.
    local numeric_full numeric_core
    numeric_full="$(echo "$raw_model" | grep -oE '[A-Za-z]*[0-9]{3,}[A-Za-z]*' | head -n1 || true)"
    [[ -n "$numeric_full" ]] && tokens+=("$numeric_full")

    # Digit-core only: M402, L2350, 8025. HP (and others) name family PPDs like
    # "M402-M403", which the full id "M402dn" will NOT substring-match but the core
    # "M402" will. Add it as a less-specific fallback after the full id.
    numeric_core="$(echo "$raw_model" | grep -oE '[A-Za-z]*[0-9]{3,}' | head -n1 || true)"
    [[ -n "$numeric_core" && "$numeric_core" != "$numeric_full" ]] && tokens+=("$numeric_core")

    info "PPD candidate tokens: ${tokens[*]:-<none>}"

    # Vendor-specific search filters.
    # For HP we match on the make ("hp") rather than a single driver family, so the
    # search sees both hpcups and PostScript (postscript-hp) PPDs; preferred_driver
    # keeps hpcups first when present (best for inkjets), then PS PPDs are picked up
    # by the vendor-only pass below.
    local vendor_grep="" preferred_driver=""
    case "$vendor" in
        epson)   vendor_grep="epson";   preferred_driver="escpr2" ;;
        hp)      vendor_grep="hp";      preferred_driver="hpcups" ;;
        brother) vendor_grep="brother"; preferred_driver="brlaser" ;;
        *)       vendor_grep="$vendor"; preferred_driver="" ;;
    esac

    local all_ppds
    all_ppds="$(lpinfo -m 2>/dev/null || true)"

    # Try each token against (vendor + preferred driver) first, then (vendor only)
    local token ppd
    for token in "${tokens[@]}"; do
        if [[ -n "$preferred_driver" ]]; then
            ppd="$(echo "$all_ppds" | grep -i "$vendor_grep" | grep -i "$preferred_driver" \
                   | grep -iF -- "$token" | awk '{print $1}' | head -n1 || true)"
            if [[ -n "$ppd" ]]; then
                echo "${ppd}|exact"
                return 0
            fi
        fi
        ppd="$(echo "$all_ppds" | grep -i "$vendor_grep" \
               | grep -iF -- "$token" | awk '{print $1}' | head -n1 || true)"
        if [[ -n "$ppd" ]]; then
            echo "${ppd}|exact"
            return 0
        fi
    done

    # No specific match. Don't silently grab a random vendor PPD — that's how
    # an ST-M1000 ends up on the EC-4020 driver and prints blank pages.
    # Return the most-likely-to-work generic fallback and let the caller decide.
    case "$vendor" in
        hp)
            # Prefer a real PostScript PPD: PS-capable LaserJets print correctly on it
            # (an inkjet PPD like hp-deskjet would garble/blank a mono laser).
            ppd="$(echo "$all_ppds" | grep -i "postscript" | grep -i "hp" | awk '{print $1}' | head -n1 || true)"
            [[ -z "$ppd" ]] && ppd="drv:///sample.drv/generic.ppd"
            ;;
        brother)
            ppd="$(echo "$all_ppds" | grep -i "brlaser" | awk '{print $1}' | head -n1 || true)"
            [[ -z "$ppd" ]] && ppd="drv:///sample.drv/generic.ppd"
            ;;
        *)
            ppd="drv:///sample.drv/generic.ppd"
            ;;
    esac
    echo "${ppd}|generic"
    return 0
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

IFS='|' read -r DETECTED_VENDOR PRINTER_URI RAW_VENDOR RAW_MODEL <<<"$SELECTED"
info "Selected printer: vendor='$DETECTED_VENDOR' make='$RAW_VENDOR' model='$RAW_MODEL'"
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

PPD_RESULT="$(resolve_ppd "$DETECTED_VENDOR" "$RAW_MODEL")"
PPD="${PPD_RESULT%|*}"
PPD_QUALITY="${PPD_RESULT##*|}"

if [[ -z "$PPD" ]]; then
    die "Could not resolve a PPD for $DETECTED_VENDOR / $RAW_MODEL." 5
fi

if [[ "$PPD_QUALITY" == "generic" ]]; then
    if [[ "$ALLOW_GENERIC" -eq 1 ]]; then
        warn "No model-specific PPD found for '$RAW_MODEL'. Falling back to generic: $PPD"
        warn "Output quality may be reduced; printer may produce blank pages on incompatible models."
    else
        err "No model-specific PPD found for '$RAW_MODEL'."
        err "Refusing to install with a generic PPD because that often results in blank pages."
        err "Available ${DETECTED_VENDOR} PPDs (for reference):"
        # NOTE: `head` closes the pipe early, which sends SIGPIPE to the upstream
        # grep. Under `set -e`/`pipefail` that made the whole script abort with 141
        # *before* the `exit 5` below. Guard the pipeline so the intended exit code
        # is preserved.
        { lpinfo -m 2>/dev/null | grep -i "$DETECTED_VENDOR" | head -n 30 || true; } \
            | while IFS= read -r ln; do
                err "  $ln"
            done
        err "Options:"
        err "  1) Install the vendor's model-specific PPD/driver and re-run."
        err "  2) Re-run with --allow-generic-ppd to accept the generic fallback anyway."
        exit 5
    fi
fi

info "Using PPD: $PPD (match: $PPD_QUALITY)"

add_queue "$QUEUE_NAME" "$PRINTER_URI" "$PPD"

if lpstat -p "$QUEUE_NAME" &>/dev/null; then
    info "SUCCESS: Queue '$QUEUE_NAME' is ready."
    lpstat -p "$QUEUE_NAME" -l | tee -a "$LOG_FILE"
    info "Test print with:  echo 'CUPS test from install-printer.sh' | lp -d $QUEUE_NAME"
    exit 0
else
    die "Queue '$QUEUE_NAME' did not register with CUPS — check $LOG_FILE." 1
fi
