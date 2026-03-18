#!/bin/sh
# ISP Recovery Wizard — Install / Uninstall script
# Run ON YOUR OPENWRT ROUTER via SSH
#
# Install:   sh install.sh
# Uninstall: sh install.sh uninstall
#
# v2.1 — Fixed: luci. rpcd prefix, view path under network/, menu.d registration

set -e

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)/luci-app-isp-recovery"
MARKER_DIR="/etc/isp-recovery"
LUCI_VIEW="/www/luci-static/resources/view/network/isp_recovery.js"
LUCI_MENU="/usr/share/luci/menu.d/luci-app-isp-recovery.json"
RPCD_SVC="/usr/libexec/rpcd/luci.isp_recovery"
RPCD_ACL="/usr/share/rpcd/acl.d/luci-app-isp-recovery.json"
BACKEND="/usr/bin/isp-recover.sh"

banner() {
    echo ""
    echo "=================================================="
    echo " ISP Recovery Wizard — $1"
    echo "=================================================="
    echo ""
}

if ! command -v apk > /dev/null 2>&1; then
    echo "ERROR: apk not found — this script must be run on an OpenWrt router."
    exit 1
fi

# ══════════════════════════════════════════════════════════
# UNINSTALL
# ══════════════════════════════════════════════════════════
if [ "$1" = "uninstall" ] || [ "$1" = "remove" ]; then
    banner "Uninstaller"

    echo "[1/5] Removing plugin files..."
    rm -f "$LUCI_VIEW"
    rm -f "$LUCI_MENU"
    rm -f "$RPCD_SVC"
    rm -f "$RPCD_ACL"
    rm -f "$BACKEND"
    # Clean up old v2.0 paths (pre-fix)
    rm -f /www/luci-static/resources/view/isp-recovery/wizard.js
    rmdir /www/luci-static/resources/view/isp-recovery 2>/dev/null || true
    rm -f /usr/libexec/rpcd/isp_recovery
    # Remove old v1.x Lua files if upgrading from a previous install
    rm -f /usr/lib/lua/luci/controller/isp_recovery.lua
    rm -f /usr/lib/lua/luci/view/isp-recovery/wizard.htm
    rmdir /usr/lib/lua/luci/view/isp-recovery 2>/dev/null || true

    echo "[2/5] Removing tcpdump (if we installed it)..."
    if [ -f "$MARKER_DIR/installed-tcpdump" ]; then
        apk remove tcpdump && echo "  tcpdump removed." \
            || echo "  WARNING: could not remove tcpdump — run: apk remove tcpdump"
        rm -f "$MARKER_DIR/installed-tcpdump"
    else
        echo "  tcpdump was pre-existing — leaving it in place."
    fi

    echo "[3/5] Removing libpcap (if we installed it)..."
    if [ -f "$MARKER_DIR/installed-libpcap" ]; then
        apk remove libpcap && echo "  libpcap removed." \
            || echo "  WARNING: could not remove libpcap."
        rm -f "$MARKER_DIR/installed-libpcap"
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
    rm -rf /tmp/luci-*
    /etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart 2>/dev/null || true

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

echo "[1/6] Checking tcpdump/libpcap dependencies..."

if command -v tcpdump > /dev/null 2>&1; then
    echo "  tcpdump: already installed (will not be removed on uninstall)"
else
    echo "  tcpdump: not found — installing..."
    apk update > /dev/null 2>&1 || echo "  WARNING: apk update failed — trying anyway..."
    if apk add tcpdump; then
        touch "$MARKER_DIR/installed-tcpdump"
        echo "  tcpdump: installed ✓ (will be removed on uninstall)"
    else
        echo ""
        echo "  ERROR: Failed to install tcpdump."
        echo "  Ensure the router has internet access, then:"
        echo "    apk update && apk add tcpdump"
        exit 1
    fi
fi

if apk list --installed 2>/dev/null | grep -q "^libpcap"; then
    echo "  libpcap: already installed"
else
    if apk add libpcap 2>/dev/null; then
        touch "$MARKER_DIR/installed-libpcap"
        echo "  libpcap: installed ✓ (will be removed on uninstall)"
    else
        echo "  libpcap: install failed — tcpdump may still work"
    fi
fi

echo "[2/6] Checking rpcd dependency..."
if ! command -v rpcd > /dev/null 2>&1; then
    echo "  rpcd: not found — installing..."
    if apk add rpcd rpcd-mod-file; then
        echo "  rpcd: installed ✓"
    else
        echo "  ERROR: Failed to install rpcd — required for v2.1 JS backend."
        exit 1
    fi
else
    echo "  rpcd: present ✓"
fi

echo "[3/6] Installing plugin files..."

# View JS — repo: htdocs/luci-static/resources/view/network/isp_recovery.js
mkdir -p /www/luci-static/resources/view/network
cp "$PLUGIN_DIR/luci-app-isp-recovery/htdocs/luci-static/resources/view/network/isp_recovery.js" "$LUCI_VIEW"

# rpcd service — repo: root/usr/libexec/rpcd/luci.isp_recovery
mkdir -p /usr/libexec/rpcd
cp "$PLUGIN_DIR/luci-app-isp-recovery/root/usr/libexec/rpcd/luci.isp_recovery" "$RPCD_SVC"
chmod +x "$RPCD_SVC"

# ACL — repo: root/usr/share/rpcd/acl.d/luci-app-isp-recovery.json
mkdir -p /usr/share/rpcd/acl.d
cp "$PLUGIN_DIR/luci-app-isp-recovery/root/usr/share/rpcd/acl.d/luci-app-isp-recovery.json" "$RPCD_ACL"

# Backend shell script — repo: root/usr/bin/isp-recover.sh
cp "$PLUGIN_DIR/luci-app-isp-recovery/root/usr/bin/isp-recover.sh" "$BACKEND"
chmod +x "$BACKEND"

# Clean up old v2.0 paths (pre-fix) and v1.x Lua files
rm -f /www/luci-static/resources/view/isp-recovery/wizard.js
rmdir /www/luci-static/resources/view/isp-recovery 2>/dev/null || true
rm -f /usr/libexec/rpcd/isp_recovery
rm -f /usr/lib/lua/luci/controller/isp_recovery.lua
rm -f /usr/lib/lua/luci/view/isp-recovery/wizard.htm
rmdir /usr/lib/lua/luci/view/isp-recovery 2>/dev/null || true

echo "  All plugin files installed ✓"

echo "[4/6] Installing LuCI menu entry..."
# Menu JSON — repo: root/usr/share/luci/menu.d/luci-app-isp-recovery.json
mkdir -p /usr/share/luci/menu.d
cp "$PLUGIN_DIR/luci-app-isp-recovery/root/usr/share/luci/menu.d/luci-app-isp-recovery.json" "$LUCI_MENU"
echo "  Menu entry installed ✓"

echo "[5/6] Verifying..."
MISSING=""
[ ! -f "$LUCI_VIEW"  ] && MISSING="$MISSING view-js"
[ ! -f "$LUCI_MENU"  ] && MISSING="$MISSING menu-json"
[ ! -f "$RPCD_SVC"   ] && MISSING="$MISSING rpcd-service"
[ ! -f "$RPCD_ACL"   ] && MISSING="$MISSING acl"
[ ! -f "$BACKEND"    ] && MISSING="$MISSING backend"
if [ -n "$MISSING" ]; then
    echo "  ERROR: missing files:$MISSING"
    exit 1
fi
echo "  Verification passed ✓"

echo "[6/6] Refreshing LuCI..."
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-*
/etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart 2>/dev/null || true
echo "  LuCI refreshed ✓"

echo ""
echo "✓ Installed successfully! (v2.1 — LuCI JS)"
echo ""
echo "  Open LuCI → Network → ISP Recovery"
echo "  URL: http://192.168.1.1/cgi-bin/luci/admin/network/isp_recovery"
echo ""
echo "  Log out and back into LuCI if the menu item doesn't appear."
echo ""

# apk show output format will vary — best effort size display
TCPDUMP_KB=$(apk show tcpdump 2>/dev/null | awk '/^Installed-Size:/{print int($2)}')
LIBPCAP_KB=$(apk show libpcap  2>/dev/null | awk '/^Installed-Size:/{print int($2)}')
if [ -n "$TCPDUMP_KB" ]; then
    echo "  Storage: tcpdump (~${TCPDUMP_KB}KB) + libpcap (~${LIBPCAP_KB}KB)"
    echo "  Both will be removed automatically when you uninstall."
fi
echo ""
echo "  To uninstall:  sh $(basename "$0") uninstall"
echo ""