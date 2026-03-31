include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-isp-recovery
PKG_VERSION:=2.1.0
PKG_RELEASE:=2
PKG_MAINTAINER:=Your Name
PKG_LICENSE:=GPL-2.0

LUCI_TITLE:=ISP Credential Recovery Wizard
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +libubox-jshn
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-isp-recovery/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-isp-recovery.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-isp-recovery.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/luci.isp_recovery $(1)/usr/libexec/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/isp-recovery
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/isp-recovery/*.js $(1)/www/luci-static/resources/view/isp-recovery/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/isp-recover.sh $(1)/usr/bin/
endef

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

define Package/luci-app-isp-recovery/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

MARKER_DIR=/etc/isp-recovery
echo "ISP Recovery: removing..."

# Stop any running capture (in case user left it running)
pkill -f "tcpdump.*-i.*-w.*-c.*1000" 2>/dev/null || true

# Remove tcpdump/libpcap only if we installed them
if [ -f "$$MARKER_DIR/installed-tcpdump" ]; then
    echo "ISP Recovery: removing tcpdump..."
    opkg remove tcpdump 2>/dev/null || true
    rm -f "$$MARKER_DIR/installed-tcpdump"
fi

if [ -f "$$MARKER_DIR/installed-libpcap" ]; then
    echo "ISP Recovery: removing libpcap..."
    opkg remove libpcap 2>/dev/null || true
    rm -f "$$MARKER_DIR/installed-libpcap"
fi

# Remove marker directory
rmdir "$$MARKER_DIR" 2>/dev/null || true

# Reload rpcd to unregister service
/etc/init.d/rpcd reload > /dev/null 2>&1 || /etc/init.d/rpcd restart > /dev/null 2>&1

# Clear LuCI cache
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-*

echo "ISP Recovery: removal complete."
exit 0
endef

$(eval $(call BuildPackage,luci-app-isp-recovery))