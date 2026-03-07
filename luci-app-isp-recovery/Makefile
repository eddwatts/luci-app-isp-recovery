include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-isp-recovery
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Your Name
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-isp-recovery
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=ISP Credential Recovery Wizard
  # luci-base is a permanent dependency — tcpdump/libpcap are installed
  # at runtime by the postinst script and removed by prerm, so they do
  # not persist on the router after the plugin is uninstalled.
  DEPENDS:=+luci-base
  PKGARCH:=all
endef

define Package/luci-app-isp-recovery/description
  A LuCI wizard for recovering ISP connection credentials (PPPoE/DHCP/Static)
  by capturing and analysing authentication traffic from the ISP router.
  Supports PPPoE username/password, DHCP, static IPoE, VLAN detection,
  and MAC address cloning.
  tcpdump and libpcap are installed automatically on first use and removed
  on uninstall to preserve flash storage.
endef

# ── Post-install: fetch tcpdump + libpcap, record if we installed them ──────
define Package/luci-app-isp-recovery/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0   # skip during image builds

MARKER_DIR=/etc/isp-recovery
mkdir -p "$$MARKER_DIR"

echo "ISP Recovery: checking for tcpdump and libpcap..."

# Only install tcpdump if it is not already present
if ! command -v tcpdump > /dev/null 2>&1; then
    echo "ISP Recovery: installing tcpdump..."
    opkg update > /dev/null 2>&1
    if opkg install tcpdump; then
        # Mark that WE installed it so prerm knows to remove it
        touch "$$MARKER_DIR/installed-tcpdump"
        echo "ISP Recovery: tcpdump installed."
    else
        echo "ISP Recovery WARNING: could not install tcpdump — capture will not work."
        echo "  Run manually: opkg install tcpdump"
    fi
else
    echo "ISP Recovery: tcpdump already present, leaving it as-is."
fi

# libpcap is pulled in as a tcpdump dependency automatically,
# but check independently in case it wasn't
if ! opkg list-installed | grep -q "^libpcap "; then
    if opkg install libpcap > /dev/null 2>&1; then
        touch "$$MARKER_DIR/installed-libpcap"
    fi
fi

# Clear LuCI cache so the new menu entry appears
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart > /dev/null 2>&1 || true
/etc/init.d/rpcd  restart > /dev/null 2>&1 || true

echo "ISP Recovery: installation complete."
echo "  Open LuCI → Network → ISP Recovery to start."
exit 0
endef

# ── Pre-remove: clean up tcpdump/libpcap only if we installed them ──────────
define Package/luci-app-isp-recovery/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

MARKER_DIR=/etc/isp-recovery

echo "ISP Recovery: uninstalling..."

# Remove tcpdump only if this plugin installed it
if [ -f "$$MARKER_DIR/installed-tcpdump" ]; then
    echo "ISP Recovery: removing tcpdump (installed by this plugin)..."
    opkg remove tcpdump && rm -f "$$MARKER_DIR/installed-tcpdump"
else
    echo "ISP Recovery: tcpdump was pre-existing, leaving it in place."
fi

# Remove libpcap only if this plugin installed it and nothing else needs it
if [ -f "$$MARKER_DIR/installed-libpcap" ]; then
    # Check nothing else depends on libpcap before removing
    DEPENDENTS=$(opkg whatdepends libpcap 2>/dev/null | grep -v "luci-app-isp-recovery" | grep -v "^What" | wc -l)
    if [ "$${DEPENDENTS}" -le 1 ]; then
        echo "ISP Recovery: removing libpcap..."
        opkg remove libpcap && rm -f "$$MARKER_DIR/installed-libpcap"
    else
        echo "ISP Recovery: libpcap has other dependents, leaving it in place."
    fi
fi

# Remove temp files from any captures
rm -f /tmp/isp-capture.pcap \
      /tmp/isp-results.json \
      /tmp/isp-autotest.json \
      /tmp/isp-recovery.log \
      /tmp/isp-recovery.state \
      /tmp/isp-ifaces.json \
      /tmp/isp-wan-backup.uci \
      /tmp/isp-tcpdump.pid

# Remove marker directory
rm -rf "$$MARKER_DIR"

# Clear LuCI cache
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart > /dev/null 2>&1 || true

echo "ISP Recovery: uninstalled cleanly."
exit 0
endef

define Build/Compile
endef

define Package/luci-app-isp-recovery/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/isp_recovery.lua \
		$(1)/usr/lib/lua/luci/controller/isp_recovery.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/isp-recovery
	$(INSTALL_DATA) ./root/usr/lib/lua/luci/view/isp-recovery/wizard.htm \
		$(1)/usr/lib/lua/luci/view/isp-recovery/wizard.htm

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/isp-recover.sh \
		$(1)/usr/bin/isp-recover.sh
endef

$(eval $(call BuildPackage,luci-app-isp-recovery))
