#!/bin/sh
# ISP Recovery Wizard — Install / Uninstall script
# Run ON YOUR OPENWRT ROUTER via SSH
#
# Install:   sh install.sh
# Uninstall: sh install.sh uninstall

set -e

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
MARKER_DIR="/etc/isp-recovery"
LUCI_CTRL="/usr/lib/lua/luci/controller/isp_recovery.lua"
LUCI_VIEW="/usr/lib/lua/luci/view/isp-recovery/wizard.htm"
BACKEND="/usr/bin/isp-recover.sh"

banner() {
    echo ""
    echo "=================================================="
    echo " ISP Recovery Wizard — $1"
    echo "=================================================="
    echo ""
}

if ! command -v opkg > /dev/null 2>&1; then
    echo "ERROR: opkg not found — this script must be run on an OpenWrt router."
    exit 1
fi

# ══════════════════════════════════════════════════════════
# UNINSTALL
# ══════════════════════════════════════════════════════════
if [ "$1" = "uninstall" ] || [ "$1" = "remove" ]; then
    banner "Uninstaller"

    echo "[1/5] Removing plugin files..."
    rm -f "$LUCI_CTRL"
    rm -f "$LUCI_VIEW"
    rm -f "$BACKEND"
    rmdir /usr/lib/lua/luci/view/isp-recovery 2>/dev/null || true

    echo "[2/5] Removing tcpdump (if we installed it)..."
    if [ -f "$MARKER_DIR/installed-tcpdump" ]; then
        opkg remove tcpdump && echo "  tcpdump removed." \
            || echo "  WARNING: could not remove tcpdump — run: opkg remove tcpdump"
        rm -f "$MARKER_DIR/installed-tcpdump"
    else
        echo "  tcpdump was pre-existing — leaving it in place."
    fi

    echo "[3/5] Removing libpcap (if we installed it)..."
    if [ -f "$MARKER_DIR/installed-libpcap" ]; then
        DEPS=$(opkg whatdepends libpcap 2>/dev/null | grep -v "^What depends" | grep -v "luci-app-isp-recovery" | grep -c "." || true)
        if [ "${DEPS:-0}" -le 0 ]; then
            opkg remove libpcap && echo "  libpcap removed." \
                || echo "  WARNING: could not remove libpcap."
            rm -f "$MARKER_DIR/installed-libpcap"
        else
            echo "  libpcap has other dependents — leaving it in place."
        fi
    else
        echo "  libpcap was pre-existing — leaving it in place."
    fi

    echo "[4/5] Cleaning up capture files and markers..."
    rm -f /tmp/isp-capture.pcap \
          /tmp/isp-results.json \
          /tmp/isp-autotest.json \
          /tmp/isp-recovery.log \
          /tmp/isp-recovery.state \
          /tmp/isp-ifaces.json \
          /tmp/isp-wan-backup.uci \
          /tmp/isp-tcpdump.pid
    rm -rf "$MARKER_DIR"

    echo "[5/5] Refreshing LuCI..."
    rm -f /tmp/luci-indexcache
    /etc/init.d/uhttpd restart 2>/dev/null || true

    echo ""
    echo "✓ ISP Recovery Wizard uninstalled cleanly."
    echo "  Flash storage recovered from tcpdump/libpcap if this plugin installed them."
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════
# INSTALL
# ══════════════════════════════════════════════════════════
banner "Installer"

mkdir -p "$MARKER_DIR"

echo "[1/4] Checking dependencies..."

if command -v tcpdump > /dev/null 2>&1; then
    echo "  tcpdump: already installed (will not be removed on uninstall)"
else
    echo "  tcpdump: not found — installing..."
    opkg update > /dev/null 2>&1 || echo "  WARNING: opkg update failed — trying anyway..."
    if opkg install tcpdump; then
        touch "$MARKER_DIR/installed-tcpdump"
        echo "  tcpdump: installed ✓ (will be removed on uninstall)"
    else
        echo ""
        echo "  ERROR: Failed to install tcpdump."
        echo "  Ensure the router has internet access, then:"
        echo "    opkg update && opkg install tcpdump"
        exit 1
    fi
fi

if opkg list-installed 2>/dev/null | grep -q "^libpcap "; then
    echo "  libpcap: already installed"
else
    if opkg install libpcap 2>/dev/null; then
        touch "$MARKER_DIR/installed-libpcap"
        echo "  libpcap: installed ✓ (will be removed on uninstall)"
    else
        echo "  libpcap: install failed — tcpdump may still work"
    fi
fi

echo "[2/4] Installing plugin files..."
mkdir -p /usr/lib/lua/luci/controller
cp "$PLUGIN_DIR/luasrc/controller/isp_recovery.lua" "$LUCI_CTRL"
mkdir -p /usr/lib/lua/luci/view/isp-recovery
cp "$PLUGIN_DIR/root/usr/lib/lua/luci/view/isp-recovery/wizard.htm" "$LUCI_VIEW"
cp "$PLUGIN_DIR/root/usr/bin/isp-recover.sh" "$BACKEND"
chmod +x "$BACKEND"
echo "  All plugin files installed ✓"

echo "[3/4] Verifying..."
MISSING=""
[ ! -f "$LUCI_CTRL" ] && MISSING="$MISSING controller"
[ ! -f "$LUCI_VIEW" ] && MISSING="$MISSING wizard"
[ ! -f "$BACKEND"   ] && MISSING="$MISSING backend"
if [ -n "$MISSING" ]; then
    echo "  ERROR: missing files:$MISSING"
    exit 1
fi
echo "  Verification passed ✓"

echo "[4/4] Refreshing LuCI..."
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/rpcd  restart 2>/dev/null || true
echo "  LuCI refreshed ✓"

echo ""
echo "✓ Installed successfully!"
echo ""
echo "  Open LuCI → Network → ISP Recovery"
echo "  URL: http://192.168.1.1/cgi-bin/luci/admin/network/isp_recovery/wizard"
echo ""

TCPDUMP_KB=$(opkg info tcpdump 2>/dev/null | awk '/^Installed-Size:/{print int($2/1024)}')
LIBPCAP_KB=$(opkg info libpcap  2>/dev/null | awk '/^Installed-Size:/{print int($2/1024)}')
if [ -n "$TCPDUMP_KB" ]; then
    echo "  Storage: tcpdump (~${TCPDUMP_KB}KB) + libpcap (~${LIBPCAP_KB}KB)"
    echo "  Both will be removed automatically when you uninstall."
fi
echo ""
echo "  To uninstall:  sh $(basename "$0") uninstall"
echo ""
