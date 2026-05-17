#!/data/data/com.termux/files/usr/bin/bash
# ================================================================
#  install.sh — halle.lua bootstrap installer
#  Repo: https://github.com/lucivaantarez/bp
#
#  Usage (fresh Termux, after Termux:API app is installed):
#    curl -L https://raw.githubusercontent.com/lucivaantarez/bp/refs/heads/main/install.sh | bash
# ================================================================

HALLE_URL="https://raw.githubusercontent.com/lucivaantarez/bp/refs/heads/main/halle.lua"
HALLE_PATH="/storage/emulated/0/Download/halle.lua"

# ─── COLORS ─────────────────────────────────────────────────────
R="\033[0m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
PURPLE="\033[35m"
DIM="\033[2m"

info()  { echo -e "${CYAN}[*]${R} $1"; }
ok()    { echo -e "${GREEN}[+]${R} $1"; }
warn()  { echo -e "${YELLOW}[!]${R} $1"; }
err()   { echo -e "${RED}[-]${R} $1"; }
dim()   { echo -e "${DIM}    $1${R}"; }

# ─── BANNER ─────────────────────────────────────────────────────
echo -e "${PURPLE}╔══════════════════════════════════════════╗"
echo -e "║       halle.lua — installer              ║"
echo -e "║         saturnity / lucivaantarez        ║"
echo -e "╚══════════════════════════════════════════╝${R}"
echo ""

# ─── STEP 1: package update ─────────────────────────────────────
info "Updating package lists..."
if pkg update -y 2>&1 | tail -2 ; then
    ok "Package lists updated."
else
    warn "pkg update had issues — continuing anyway."
fi

# ─── STEP 2: install lua54 ──────────────────────────────────────
if command -v lua5.4 &>/dev/null || command -v lua &>/dev/null; then
    ok "Lua already installed — skipping."
else
    info "Installing lua54..."
    if pkg install lua54 -y; then
        ok "lua54 installed."
    else
        err "Failed to install lua54. Try: pkg install lua54"
        exit 1
    fi
fi

# ─── STEP 3: install curl ────────────────────────────────────────
if command -v curl &>/dev/null; then
    ok "curl already installed — skipping."
else
    info "Installing curl..."
    if pkg install curl -y; then
        ok "curl installed."
    else
        err "Failed to install curl. Try: pkg install curl"
        exit 1
    fi
fi

# ─── STEP 4: install termux-api package ─────────────────────────
if command -v termux-clipboard-get &>/dev/null; then
    ok "termux-api already installed — skipping."
else
    info "Installing termux-api..."
    if pkg install termux-api -y; then
        ok "termux-api installed."
    else
        err "Failed to install termux-api. Try: pkg install termux-api"
        exit 1
    fi
fi

# ─── STEP 5: verify Termux:API app ──────────────────────────────
# Test clipboard — if Termux:API APK isn't installed, this hangs/fails
info "Verifying Termux:API app is working..."
CLIP_TEST=$(timeout 5 termux-clipboard-get 2>&1)
CLIP_EXIT=$?
if [ $CLIP_EXIT -eq 124 ]; then
    warn "termux-clipboard-get timed out."
    dim "The 'termux-api' package is installed but the Termux:API"
    dim "Android app is missing or not running."
    dim "Install it from F-Droid:"
    dim "  https://f-droid.org/packages/com.termux.api/"
    dim "Then re-run this installer."
    exit 1
elif echo "$CLIP_TEST" | grep -qi "error\|exception\|not found" 2>/dev/null; then
    warn "Termux:API app may not be installed."
    dim "Install from F-Droid: https://f-droid.org/packages/com.termux.api/"
    dim "Then re-run this installer."
    exit 1
else
    ok "Termux:API app is working."
fi

# ─── STEP 6: storage permission ─────────────────────────────────
if [ -d "/storage/emulated/0" ]; then
    ok "Storage access already granted — skipping."
else
    info "Requesting storage permission..."
    dim "A popup will appear — tap Allow."
    termux-setup-storage
    sleep 3
    if [ -d "/storage/emulated/0" ]; then
        ok "Storage access granted."
    else
        err "Storage permission not granted."
        dim "Run: termux-setup-storage  — then tap Allow."
        dim "Then re-run this installer."
        exit 1
    fi
fi

# ─── STEP 7: download halle.lua ─────────────────────────────────
info "Downloading halle.lua..."
if curl -sL "$HALLE_URL" -o "$HALLE_PATH"; then
    # Sanity check — file should be at least 5KB
    FILE_SIZE=$(wc -c < "$HALLE_PATH" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -lt 5000 ]; then
        err "Downloaded file looks too small (${FILE_SIZE} bytes) — may be corrupt."
        dim "Check your GitHub URL or repo visibility."
        exit 1
    fi
    ok "halle.lua downloaded to $HALLE_PATH"
else
    err "Download failed. Check your internet connection."
    exit 1
fi

# ─── DONE ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗"
echo -e "║           install complete! ✦            ║"
echo -e "╚══════════════════════════════════════════╝${R}"
echo ""
dim "To run halle:"
echo -e "    ${CYAN}lua $HALLE_PATH${R}"
echo ""
dim "After first run, a 'bypass' alias will be added."
dim "Restart Termux once, then just type: bypass"
echo ""

# Ask to launch now
echo -e "${YELLOW}Launch halle.lua now? (y/n)${R}"
read -r LAUNCH
if [[ "$LAUNCH" =~ ^[Yy]$ ]]; then
    lua "$HALLE_PATH"
fi
