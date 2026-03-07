# luci-app-wan-detect

**WAN Credential Recovery Wizard for OpenWrt**  
Automatically recover your ISP connection credentials (PPPoE, DHCP, static IP) by capturing
and analysing the authentication handshake from your ISP's router or modem.
Works with any ISP that uses standard protocols — Sky, BT, Virgin Media, TalkTalk, Plusnet,
Vodafone, EE, and most others worldwide.

---

## What It Does

1. **Detects** your WAN and available LAN ports automatically
2. **Brings down** a spare LAN port so the ISP router sees a "disconnected" cable
3. **Prompts you** to plug your ISP router into that LAN port
4. **Starts a packet capture** (tcpdump) the moment you say it's plugged in
5. **Captures 30 seconds** of traffic — enough for PPPoE handshake, DHCP offer, ARP, VLAN tags
6. **Analyses** the capture for:
   - PPPoE username and password (PAP cleartext)
   - DHCP-assigned IP, gateway, netmask, DNS
   - Static/IPoE IP configuration
   - VLAN 802.1Q tag ID
   - MAC address of ISP router (for MAC cloning)
7. **Displays results** in a clean UI
8. **Optionally applies** the settings directly to your WAN port

---

## Requirements

- OpenWrt 21.02 or later with LuCI installed
- `tcpdump` package (`opkg install tcpdump`)
- A spare LAN port to use as capture port (e.g. `lan1`, `eth1`)
- Your ISP router powered on with an Ethernet cable

---

## Installation

### Option A — Direct install via SSH (recommended)

```sh
# Copy files to your router
scp -r luci-app-isp-recovery/ root@192.168.1.1:/tmp/isp-recovery/
scp install.sh root@192.168.1.1:/tmp/

# SSH in and run installer
ssh root@192.168.1.1
sh /tmp/install.sh
```

Then open LuCI → **Network → ISP Recovery**

### Option B — Build with OpenWrt SDK

```sh
# Copy to package directory
cp -r luci-app-isp-recovery/ ~/openwrt/package/feeds/luci/

# Configure
cd ~/openwrt
make menuconfig
# Enable: LuCI → Applications → luci-app-isp-recovery

make package/luci-app-isp-recovery/compile
# .ipk will be in bin/packages/...
opkg install luci-app-isp-recovery_*.ipk
```

---

## File Structure

```
luci-app-isp-recovery/
├── Makefile                          # OpenWrt package build
├── install.sh                        # Direct SSH installer
├── luasrc/
│   └── controller/
│       └── isp_recovery.lua          # LuCI controller (routes & AJAX handlers)
└── root/
    ├── usr/bin/
    │   └── isp-recover.sh            # Backend: capture, analyse, apply
    └── usr/lib/lua/luci/view/
        └── isp-recovery/
            └── wizard.htm            # Wizard UI (HTML/CSS/JS + LuCI template)
```

---

## Notes on PPPoE Password Recovery

- **PAP mode**: Password is sent in cleartext — fully recoverable ✓
- **CHAP mode**: Password is hashed (MD5 challenge-response) — hash captured but not crackable without a dictionary attack
- If CHAP is used and the password isn't recovered, try logging into your ISP router's admin panel directly, or contact your ISP support

## VLAN Support

If your ISP uses a VLAN tag (common with some UK providers), the tool will detect the 802.1Q tag ID and automatically configure `wan.ifname` with the correct VLAN subinterface (e.g. `eth0.101`).

## MAC Cloning

The ISP may have registered your old router's MAC address. The tool captures it and offers to clone it onto your new WAN port.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "No capture file found" | Ensure tcpdump is installed: `opkg install tcpdump` |
| Empty results | Try increasing capture time — edit `CAPTURE_DURATION=30` in `isp-recover.sh` |
| Can't find LAN port | Manually enter port name in the wizard (e.g. `eth1`, `lan2`) |
| LuCI shows 404 | Clear cache: `rm /tmp/luci-indexcache && /etc/init.d/uhttpd restart` |
| Wizard not in menu | Check controller installed: `ls /usr/lib/lua/luci/controller/isp_recovery.lua` |

---

## Security Note

The captured PCAP file is stored at `/tmp/isp-capture.pcap`. This may contain your ISP credentials in plaintext. Delete it after use:

```sh
rm -f /tmp/isp-capture.pcap /tmp/isp-results.json
```

---

## License

GPL-2.0
