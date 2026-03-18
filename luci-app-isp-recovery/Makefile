include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-isp-recovery
PKG_VERSION:=2.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Your Name
PKG_LICENSE:=GPL-2.0

# ── JS migration notes ────────────────────────────────────────────────────
#
# v1.x: Lua controller (luci/controller/isp_recovery.lua) +
#        HTM template  (luci/view/isp-recovery/wizard.htm)
#
# v2.0: Initial JS migration — had wrong paths (view/isp-recovery/wizard.js,
#        rpcd/isp_recovery without luci. prefix, no menu.d registration).
#
# v2.1: Corrected paths:
#     /www/luci-static/resources/view/network/isp_recovery.js  ← JS view
#     /usr/libexec/rpcd/luci.isp_recovery                      ← rpcd service
#     /usr/share/rpcd/acl.d/luci-app-isp-recovery.json         ← ACL
#     /usr/share/luci/menu.d/luci-app-isp-recovery.json        ← menu entry
#     /usr/bin/isp-recover.sh                                   ← unchanged

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-isp-recovery
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=ISP Credential Recovery Wizard
  # luci-base ≥ 20.x provides the JS view framework (L.view, L.rpc).
  # rpcd + libubox-jshn are needed for the new rpcd service backend.
  # tcpdump/libpcap are installed at runtime by postinst as before.
  DEPENDS:=+luci-base +rpcd +rpcd-mod-file +libubox-jshn
  PKGARCH:=all
endef

define Package/luci-app-isp-recovery/description
  A LuCI wizard for recovering ISP connection credentials (PPPoE/DHCP/Static)
  by capturing and analysing authentication traffic from the ISP router.
  Supports PPPoE username/password, DHCP, static IPoE, VLAN detection,
  and MAC address cloning.

  v2.1: LuCI JS view with rpcd backend. Corrected view/rpcd/menu paths.
endef

# ── Post-install: fetch tcpdump + libpcap, restart rpcd ───────────────────
define Package/luci-app-isp-recovery/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

MARKER_DIR=/etc/isp-recovery
mkdir -p "$$MARKER_DIR"

echo "ISP Recovery: checking for tcpdump and libpcap..."

if ! command -v tcpdump > /dev/null 2>&1; then
    echo "ISP Recovery: installing tcpdump..."
    opkg update > /dev/null 2>&1
    if opkg install tcpdump; then
        touch "$$MARKER_DIR/installed-tcpdump"
        echo "ISP Recovery: tcpdump installed."
    else
        echo "ISP Recovery WARNING: could not install tcpdump — capture will not work."
        echo "  Run manually: opkg install tcpdump"
    fi
else
    echo "ISP Recovery: tcpdump already present, leaving it as-is."
fi

if ! opkg list-installed | grep -q "^libpcap "; then
    if opkg install libpcap > /dev/null 2>&1; then
        touch "$$MARKER_DIR/installed-libpcap"
    fi
fi

# Ensure rpcd service script is executable
chmod 755 /usr/libexec/rpcd/luci.isp_recovery

# Remove stale v2.0 files if upgrading
rm -f /www/luci-static/resources/view/isp-recovery/wizard.js
rmdir /www/luci-static/resources/view/isp-recovery 2>/dev/null || true
rm -f /usr/libexec/rpcd/isp_recovery

# Reload rpcd so it picks up the new service + ACL
/etc/init.d/rpcd reload > /dev/null 2>&1 || /etc/init.d/rpcd restart > /dev/null 2>&1

# Clear LuCI JS cache so the new view is picked up
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-*

echo "ISP Recovery: installation complete."
echo "  Open LuCI → Network → ISP Recovery to start."
exit 0
endef

# ── Pre-remove: clean up tcpdump/libpcap only if we installed them ─────────
define Package/luci-app-isp-recovery/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

MARKER_DIR=/etc/isp-recovery
echo "ISP Recovery: uninstalling..."

if [ -f "$$MARKER_DIR/installed-tcpdump" ]; then
    echo "ISP Recovery: removing tcpdump (installed by this plugin)..."
    opkg remove tcpdump && rm -f "$$MARKER_DIR/installed-tcpdump"
else
    echo "ISP Recovery: tcpdump was pre-existing, leaving it in place."
fi

if [ -f "$$MARKER_DIR/installed-libpcap" ]; then
    DEPENDENTS=$$(opkg whatdepends libpcap 2>/dev/null | grep -v "luci-app-isp-recovery" | grep -v "^What" | wc -l)
    if [ "$${DEPENDENTS}" -le 1 ]; then
        echo "ISP Recovery: removing libpcap..."
        opkg remove libpcap && rm -f "$$MARKER_DIR/installed-libpcap"
    else
        echo "ISP Recovery: libpcap has other dependents, leaving it in place."
    fi
fi

rm -f /tmp/isp-capture.pcap \
      /tmp/isp-results.json \
      /tmp/isp-autotest.json \
      /tmp/isp-recovery.log \
      /tmp/isp-recovery.state \
      /tmp/isp-ifaces.json \
      /tmp/isp-wan-backup.uci \
      /tmp/isp-tcpdump.pid

rm -rf "$$MARKER_DIR"

# Reload rpcd to drop the now-removed service
/etc/init.d/rpcd reload > /dev/null 2>&1 || true

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-*

echo "ISP Recovery: uninstalled cleanly."
exit 0
endef

define Build/Compile
endef

define Package/luci-app-isp-recovery/install
	# ── JS view — path determines URL: /admin/network/isp_recovery ────────
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/network
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/network/isp_recovery.js \
		$(1)/www/luci-static/resources/view/network/isp_recovery.js

	# ── rpcd backend — filename "luci.isp_recovery" = ubus object name ────
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/luci.isp_recovery \
		$(1)/usr/libexec/rpcd/luci.isp_recovery

	# ── rpcd ACL (grants LuCI session permission to call the service) ─────
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-isp-recovery.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-isp-recovery.json

	# ── LuCI menu entry — registers route + sidebar item ──────────────────
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-isp-recovery.json \
		$(1)/usr/share/luci/menu.d/luci-app-isp-recovery.json

	# ── Shell capture/analysis script — UNCHANGED from v1.x ──────────────
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/isp-recover.sh \
		$(1)/usr/bin/isp-recover.sh
endef

$(eval $(call BuildPackage,luci-app-isp-recovery))