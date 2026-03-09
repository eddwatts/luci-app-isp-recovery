#!/bin/sh
# ISP Credential Recovery Tool for OpenWrt
# Captures PPPoE credentials, DHCP info, MAC, VLAN tags from ISP router

PCAP_FILE="/tmp/isp-capture.pcap"
RESULTS_FILE="/tmp/isp-results.json"
LOG_FILE="/tmp/isp-recovery.log"
STATE_FILE="/tmp/isp-recovery.state"
CAPTURE_PID_FILE="/tmp/isp-tcpdump.pid"
CAPTURE_DURATION=30

# ── Community database (Supabase) ─────────────────────────────────────────
# Set these after creating your Supabase project:
#   https://supabase.com → Settings → API
# Leave blank to disable community DB features entirely.
SUPABASE_URL="https://pdgctglsbuksoeatijny.supabase.co"
SUPABASE_KEY="sb_publishable_AbzALgGJV55hYnjCvSu20A_IhK_4s_j"

# Files written by the ISP lookup + DB query steps
ISP_INFO_FILE="/tmp/isp-info.json"       # ip-api.com response for current WAN IP

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

set_state() {
    echo "$1" > "$STATE_FILE"
    log "State: $1"
}

get_state() {
    cat "$STATE_FILE" 2>/dev/null || echo "idle"
}

# ── Detect interfaces — capture port is always lan1 ───────────────────────
detect_interfaces() {
    log "Detecting network interfaces..."
    WAN_IFACE=$(uci get network.wan.ifname 2>/dev/null || uci get network.wan.device 2>/dev/null || echo "eth0")
    LAN_IFACE=$(uci get network.lan.ifname 2>/dev/null | awk '{print $1}' || echo "eth1")

    # Capture port is always lan1 — fixed by design so a monitoring laptop
    # on lan2/lan3 does not interfere with the capture
    CAPTURE_PORT="lan1"

    # Verify lan1 actually exists on this router
    LAN1_OK="yes"
    if ! ip link show lan1 > /dev/null 2>&1; then
        LAN1_OK="no"
        log "WARNING: lan1 not found — check your router's port names"
    else
        log "lan1 confirmed present"
    fi

    cat > /tmp/isp-ifaces.json << EOF
{
  "wan": "$WAN_IFACE",
  "lan": "$LAN_IFACE",
  "capture_port": "lan1",
  "lan1_ok": "$LAN1_OK"
}
EOF
    log "WAN=$WAN_IFACE  LAN=$LAN_IFACE  CapturePort=lan1 (fixed)"
    # Note: ISP lookup runs after autotest success when WAN is confirmed up.
    echo "lan1"
}

# ── Step 2: Setup bridge between LAN port and WAN ─────────────────────────
setup_bridge() {
    CAPTURE_PORT="${1:-lan1}"
    log "Setting up bridge: $CAPTURE_PORT <-> WAN (monitor mode)"

    # Save original WAN config
    uci show network.wan > /tmp/isp-wan-backup.uci

    # Bring capture port down so ISP router detects link loss
    ip link set "$CAPTURE_PORT" down
    log "Port $CAPTURE_PORT is DOWN — ready for ISP router connection"
    set_state "waiting_for_plug"
    echo "ok"
}

# ── Step 3: Enable port and start capture ─────────────────────────────────
start_capture() {
    CAPTURE_PORT="${1:-lan1}"
    log "Bringing $CAPTURE_PORT UP and starting packet capture..."

    # Bring port back up
    ip link set "$CAPTURE_PORT" up
    ip link set "$CAPTURE_PORT" promisc on

    # Start tcpdump capture in background
    # Capture: PPPoE (0x8863/0x8864), VLAN (0x8100), ARP, DHCP, all auth
    tcpdump -i "$CAPTURE_PORT" \
        -w "$PCAP_FILE" \
        -s 0 \
        '(pppoes or pppoed or vlan or arp or (udp and (port 67 or port 68)) or (tcp and (port 1723 or port 1701)) or proto 47)' \
        2>>"$LOG_FILE" &
    
    echo $! > "$CAPTURE_PID_FILE"
    log "tcpdump started (PID: $(cat $CAPTURE_PID_FILE))"
    set_state "capturing"
    echo "ok"
}

# ── Step 4: Stop capture and analyse ──────────────────────────────────────
stop_capture_and_analyse() {
    log "Stopping packet capture..."
    if [ -f "$CAPTURE_PID_FILE" ]; then
        kill "$(cat $CAPTURE_PID_FILE)" 2>/dev/null
        rm -f "$CAPTURE_PID_FILE"
    fi
    pkill -f "tcpdump.*isp-capture" 2>/dev/null
    sleep 1
    set_state "analysing"
    analyse_capture
}

analyse_capture() {
    log "========================================"
    log "Starting comprehensive traffic analysis"
    log "========================================"

    # ── Initialise all fields ─────────────────────────────────────────────
    AUTH_TYPE="unknown"
    AUTH_CONFIDENCE="low"
    PPPOE_USER=""
    PPPOE_PASS=""
    PPPOE_AUTH_METHOD=""
    MAC_ADDR=""
    IP_ADDR=""
    IP_CONFIDENCE=""
    GW_ADDR=""
    GW_CONFIDENCE=""
    NETMASK=""
    NETMASK_SOURCE=""
    VLAN_ID=""
    DNS1=""
    DNS2=""
    NOTES=""

    if [ ! -f "$PCAP_FILE" ]; then
        log "ERROR: No capture file found at $PCAP_FILE"
        write_results "error" "No capture file found — is tcpdump installed?"
        return
    fi

    # Check file has content
    PCAP_SIZE=$(wc -c < "$PCAP_FILE" 2>/dev/null || echo 0)
    if [ "$PCAP_SIZE" -lt 100 ]; then
        log "WARNING: Capture file is very small ($PCAP_SIZE bytes) — no traffic seen"
        write_results "error" "No traffic captured — check the cable and ISP router power"
        return
    fi
    log "Capture file: $PCAP_SIZE bytes"

    # ── Dump full verbose decode once, reuse it ───────────────────────────
    DUMP_V=$(tcpdump -r "$PCAP_FILE" -n -v -e 2>/dev/null)
    DUMP_A=$(tcpdump -r "$PCAP_FILE" -n -A   2>/dev/null)
    DUMP_E=$(tcpdump -r "$PCAP_FILE" -n -e   2>/dev/null)

    # ── 1. MAC ADDRESS ────────────────────────────────────────────────────
    log "--- Detecting MAC address ---"
    # Grab first source MAC from ethernet header (SA = source address)
    MAC_ADDR=$(echo "$DUMP_E" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
    if [ -n "$MAC_ADDR" ]; then
        log "MAC address detected: $MAC_ADDR"
    else
        log "WARNING: Could not determine MAC address"
    fi

    # ── 2. VLAN DETECTION ─────────────────────────────────────────────────
    log "--- Detecting VLAN tags ---"
    # Find most common VLAN ID (802.1Q ethertype 0x8100)
    VLAN_ID=$(echo "$DUMP_V" | grep -oE 'vlan [0-9]+' | \
        awk '{print $2}' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
    if [ -n "$VLAN_ID" ]; then
        log "VLAN tag detected: $VLAN_ID"
    else
        log "No VLAN tags detected (untagged traffic)"
    fi

    # ── 3. PPPoE DETECTION ────────────────────────────────────────────────
    log "--- Testing for PPPoE ---"
    HAS_PPPOE=$(echo "$DUMP_V" | grep -c -i 'pppoe\|PPP-over-Ethernet\|PADI\|PADO\|PADR\|PADS' 2>/dev/null || echo 0)
    
    if [ "$HAS_PPPOE" -gt 0 ]; then
        AUTH_TYPE="pppoe"
        AUTH_CONFIDENCE="high"
        log "PPPoE confirmed ($HAS_PPPOE matching packets)"

        # Determine PAP vs CHAP
        HAS_PAP=$(echo "$DUMP_V"  | grep -c -i 'PAP\|Password Authentication' || echo 0)
        HAS_CHAP=$(echo "$DUMP_V" | grep -c -i 'CHAP\|Challenge Handshake'    || echo 0)

        if [ "$HAS_PAP" -gt 0 ]; then
            PPPOE_AUTH_METHOD="PAP"
            log "PAP authentication detected — credentials will be in cleartext"

            # Method 1: named fields in verbose output
            PPPOE_USER=$(echo "$DUMP_A" | grep -oE 'peer ID "[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | head -1)
            PPPOE_PASS=$(echo "$DUMP_A" | grep -oE 'passwd "[^"]+"'  | grep -oE '"[^"]+"' | tr -d '"' | head -1)

            # Method 2: ASCII dump — PAP sends length-prefixed strings after code/id/length fields
            if [ -z "$PPPOE_USER" ]; then
                PPPOE_USER=$(strings "$PCAP_FILE" 2>/dev/null | \
                    grep -E '^[a-zA-Z0-9._@+/-]{4,80}$' | \
                    grep -iE '@|broadband|adsl|dsl|ppp|user|client|connect|internet' | head -1)
            fi
            if [ -z "$PPPOE_PASS" ]; then
                # Password typically follows username in PAP packet
                PPPOE_PASS=$(strings "$PCAP_FILE" 2>/dev/null | \
                    grep -E '^[^\s]{4,64}$' | grep -v -E '^[0-9a-f]{12}$' | \
                    grep -A1 "$PPPOE_USER" 2>/dev/null | tail -1)
            fi

        elif [ "$HAS_CHAP" -gt 0 ]; then
            PPPOE_AUTH_METHOD="CHAP"
            log "CHAP authentication detected — password is MD5-hashed, not recoverable"
            NOTES="PPPoE uses CHAP: username captured but password is hashed (MD5). Check ISP router admin panel or contact ISP."
            # Username is still sent cleartext in CHAP
            PPPOE_USER=$(echo "$DUMP_A" | grep -oE 'name "[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | head -1)
            if [ -z "$PPPOE_USER" ]; then
                PPPOE_USER=$(strings "$PCAP_FILE" 2>/dev/null | \
                    grep -E '^[a-zA-Z0-9._@+/-]{4,80}$' | \
                    grep -iE '@|broadband|adsl|dsl|connect|internet' | head -1)
            fi
        else
            PPPOE_AUTH_METHOD="unknown"
            log "PPPoE detected but auth method unclear"
        fi

        [ -n "$PPPOE_USER" ] && log "PPPoE username: $PPPOE_USER" || log "WARNING: Could not extract PPPoE username"
        [ -n "$PPPOE_PASS" ] && log "PPPoE password: [found]"     || log "WARNING: Could not extract PPPoE password"
    fi

    # ── 4. DHCP DETECTION ─────────────────────────────────────────────────
    log "--- Testing for DHCP ---"
    HAS_DHCP=$(echo "$DUMP_V" | grep -c -i 'DHCP\|BOOTP\|DISCOVER\|OFFER\|REQUEST\|ACK' || echo 0)

    if [ "$HAS_DHCP" -gt 0 ] && [ "$AUTH_TYPE" = "unknown" ]; then
        AUTH_TYPE="dhcp"
        AUTH_CONFIDENCE="high"
        log "DHCP confirmed ($HAS_DHCP matching packets)"

        # Pull from DHCP ACK — most complete source
        DHCP_ACK=$(echo "$DUMP_V" | awk '/DHCP.*ACK/{found=1} found{print} /^[0-9]/{if(found && !/DHCP/)found=0}')

        IP_ADDR=$(echo "$DHCP_ACK"  | grep -oE 'Your-IP [0-9.]+' | grep -oE '[0-9.]+$' | head -1)
        GW_ADDR=$(echo "$DHCP_ACK"  | grep -oE '(Default-Gateway|Router)[^,)]+' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
        NETMASK=$(echo "$DHCP_ACK"  | grep -oE 'Subnet-Mask [0-9.]+' | grep -oE '[0-9.]+$' | head -1)
        DNS_RAW=$(echo "$DHCP_ACK"  | grep -oE 'Domain-Name-Server[^)]+' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
        DNS1=$(echo "$DNS_RAW" | head -1)
        DNS2=$(echo "$DNS_RAW" | sed -n '2p')

        # Fallback: try DHCP OFFER if ACK not found
        if [ -z "$IP_ADDR" ]; then
            DHCP_OFFER=$(echo "$DUMP_V" | awk '/DHCP.*Offer/{found=1} found{print} /^[0-9]/{if(found && !/DHCP/)found=0}')
            IP_ADDR=$(echo "$DHCP_OFFER" | grep -oE 'Your-IP [0-9.]+' | grep -oE '[0-9.]+$' | head -1)
            GW_ADDR=$(echo "$DHCP_OFFER" | grep -oE '(Default-Gateway|Router)[^,)]+' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
            NETMASK=$(echo "$DHCP_OFFER" | grep -oE 'Subnet-Mask [0-9.]+' | grep -oE '[0-9.]+$' | head -1)
        fi

        [ -n "$IP_ADDR" ]  && { IP_CONFIDENCE="high"; log "DHCP IP: $IP_ADDR"; }
        [ -n "$GW_ADDR" ]  && { GW_CONFIDENCE="high"; log "DHCP Gateway: $GW_ADDR"; }
        [ -n "$NETMASK" ]  && { NETMASK_SOURCE="dhcp"; log "DHCP Netmask: $NETMASK"; }
        [ -n "$DNS1"    ]  && log "DHCP DNS1: $DNS1"
        NETMASK_SOURCE="dhcp"
    fi

    # ── 5. STATIC / IPoE DETECTION via ARP ───────────────────────────────
    # Run this even if DHCP found — may supplement missing fields
    log "--- Analysing ARP traffic for static IP clues ---"
    HAS_ARP=$(echo "$DUMP_V" | grep -c -i 'ARP\|arp' || echo 0)

    if [ "$HAS_ARP" -gt 0 ]; then
        log "ARP traffic present ($HAS_ARP packets)"

        # Gratuitous ARP / ARP Reply — "X is at MAC" = device announcing its IP
        # These are the most reliable source of the assigned IP
        ARP_ANNOUNCES=$(echo "$DUMP_V" | grep -i 'ARP.*Reply\|is-at\|ARP.*Announcement' | \
            grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' )

        # ARP Requests — "who has X?" = device trying to reach gateway
        ARP_REQUESTS=$(echo "$DUMP_V" | grep -i 'ARP.*Request\|who-has' | \
            grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')

        # The gateway is typically the IP being ARP-requested most
        GW_CANDIDATE=$(echo "$ARP_REQUESTS" | sort | uniq -c | sort -rn | \
            awk 'NR==1{print $2}')

        # The ISP router's own IP is in ARP replies
        IP_CANDIDATE=$(echo "$ARP_ANNOUNCES" | grep -v "$GW_CANDIDATE" | head -1)

        # Also check for source IPs in actual IP packets
        IP_FROM_TRAFFIC=$(tcpdump -r "$PCAP_FILE" -n 2>/dev/null | \
            grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | \
            grep -v '255\|0\.0\.0\.0\|224\.\|239\.' | \
            sort | uniq -c | sort -rn | awk 'NR==1{print $2}')

        if [ "$AUTH_TYPE" = "unknown" ] && ([ -n "$GW_CANDIDATE" ] || [ -n "$IP_CANDIDATE" ]); then
            AUTH_TYPE="static"
            AUTH_CONFIDENCE="medium"
            log "Static IP (IPoE) detected via ARP analysis"
        fi

        # Fill in any missing IP/GW values
        if [ -z "$IP_ADDR" ]; then
            IP_ADDR="${IP_CANDIDATE:-$IP_FROM_TRAFFIC}"
            IP_CONFIDENCE="medium"
            [ -n "$IP_ADDR" ] && log "Static IP (from ARP/traffic): $IP_ADDR"
        fi
        if [ -z "$GW_ADDR" ] && [ -n "$GW_CANDIDATE" ]; then
            GW_ADDR="$GW_CANDIDATE"
            GW_CONFIDENCE="medium"
            log "Gateway (from ARP requests): $GW_ADDR"
        fi
    fi

    # ── 6. NETMASK CALCULATION ────────────────────────────────────────────
    log "--- Calculating netmask ---"
    if [ -z "$NETMASK" ] && [ -n "$IP_ADDR" ] && [ -n "$GW_ADDR" ]; then
        NETMASK=$(calc_netmask "$IP_ADDR" "$GW_ADDR")
        NETMASK_SOURCE="calculated"
        log "Netmask calculated from IP+Gateway: $NETMASK"
    elif [ -z "$NETMASK" ] && [ -n "$IP_ADDR" ]; then
        # Last resort: guess from first octet (classful)
        FIRST=$(echo "$IP_ADDR" | cut -d. -f1)
        if   [ "$FIRST" -le 127 ]; then NETMASK="255.0.0.0";     NETMASK_SOURCE="classful-A"
        elif [ "$FIRST" -le 191 ]; then NETMASK="255.255.0.0";   NETMASK_SOURCE="classful-B"
        else                             NETMASK="255.255.255.0"; NETMASK_SOURCE="classful-C"
        fi
        log "Netmask guessed from classful range: $NETMASK ($NETMASK_SOURCE)"
    fi

    # ── 7. DNS DEFAULTS ───────────────────────────────────────────────────
    # If DHCP didn't give us DNS, use Cloudflare (user is happy with this)
    [ -z "$DNS1" ] && DNS1="1.1.1.1"
    [ -z "$DNS2" ] && DNS2="1.0.0.1"
    log "DNS: $DNS1 / $DNS2"

    # ── 8. FINAL SUMMARY ─────────────────────────────────────────────────
    log "========================================"
    log "Analysis complete"
    log "  Auth type : $AUTH_TYPE ($AUTH_CONFIDENCE confidence)"
    log "  MAC       : ${MAC_ADDR:-not detected}"
    log "  VLAN      : ${VLAN_ID:-none}"
    [ "$AUTH_TYPE" = "pppoe"   ] && log "  User      : ${PPPOE_USER:-not found}"
    [ "$AUTH_TYPE" = "pppoe"   ] && log "  Auth mode : ${PPPOE_AUTH_METHOD:-unknown}"
    [ "$AUTH_TYPE" != "pppoe"  ] && log "  IP        : ${IP_ADDR:-not found} ($IP_CONFIDENCE)"
    [ "$AUTH_TYPE" != "pppoe"  ] && log "  Gateway   : ${GW_ADDR:-not found} ($GW_CONFIDENCE)"
    [ "$AUTH_TYPE" != "pppoe"  ] && log "  Netmask   : ${NETMASK:-not found} ($NETMASK_SOURCE)"
    log "========================================"

    write_results "success" ""
}

# ── Netmask calculation from two IPs ──────────────────────────────────────
# Finds the longest common prefix between IP and gateway, maps to netmask.
# e.g. 82.68.12.1 and 82.68.12.6 → /29 → 255.255.255.248
calc_netmask() {
    IP="$1"
    GW="$2"

    # Convert dotted-quad to 32-bit integer
    ip_to_int() {
        local a b c d
        IFS='.' read a b c d << EOF
$1
EOF
        echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
    }

    int_to_dotted() {
        local n=$1
        echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
    }

    IP_INT=$(ip_to_int "$IP")
    GW_INT=$(ip_to_int "$GW")

    # XOR to find differing bits, then find the host portion
    DIFF=$(( IP_INT ^ GW_INT ))

    # Find smallest power-of-2 block that contains both
    BLOCK=1
    while [ "$BLOCK" -le "$DIFF" ]; do
        BLOCK=$(( BLOCK * 2 ))
    done

    # Mask = all 1s except the host block
    MASK=$(( 0xFFFFFFFF & ~(BLOCK - 1) ))

    # Convert to standard ISP subnet sizes
    # ISPs commonly use /29 (8 IPs), /28 (16), /30 (4), /27 (32)
    case "$MASK" in
        4294967292) int_to_dotted 4294967292 ;;   # /30 = 255.255.255.252
        4294967288) int_to_dotted 4294967288 ;;   # /29 = 255.255.255.248
        4294967280) int_to_dotted 4294967280 ;;   # /28 = 255.255.255.240
        4294967264) int_to_dotted 4294967264 ;;   # /27 = 255.255.255.224
        4294967040) int_to_dotted 4294967040 ;;   # /24 = 255.255.255.0
        *)          int_to_dotted "$MASK"    ;;   # whatever it calculates
    esac
}

write_results() {
    STATUS="$1"
    ERROR="$2"

    cat > "$RESULTS_FILE" << EOF
{
  "status": "$STATUS",
  "error": "$ERROR",
  "auth_type": "$AUTH_TYPE",
  "auth_confidence": "$AUTH_CONFIDENCE",
  "pppoe": {
    "username": "$PPPOE_USER",
    "password": "$PPPOE_PASS",
    "auth_method": "$PPPOE_AUTH_METHOD"
  },
  "ip": {
    "address": "$IP_ADDR",
    "gateway": "$GW_ADDR",
    "netmask": "$NETMASK",
    "netmask_source": "$NETMASK_SOURCE",
    "dns1": "$DNS1",
    "dns2": "$DNS2",
    "ip_confidence": "$IP_CONFIDENCE",
    "gw_confidence": "$GW_CONFIDENCE"
  },
  "mac_address": "$MAC_ADDR",
  "vlan_id": "$VLAN_ID",
  "notes": "$NOTES",
  "pcap_file": "$PCAP_FILE",
  "timestamp": "$(date -Iseconds)"
}
EOF
    log "Results written to $RESULTS_FILE"
    set_state "complete"
}

# ── Step 5: Apply recovered settings to WAN ───────────────────────────────
apply_settings() {
    # Accept overridden values from the UI's "edit before apply" form
    # These are passed as environment variables: APPLY_USER, APPLY_PASS, etc.
    RESULTS=$(cat "$RESULTS_FILE" 2>/dev/null)
    AUTH_TYPE=$(echo "$RESULTS" | jsonfilter -e '@.auth_type' 2>/dev/null || echo "")

    # Allow UI overrides (passed via POST params → env vars set by controller)
    [ -n "$APPLY_AUTH_TYPE" ] && AUTH_TYPE="$APPLY_AUTH_TYPE"

    log "Applying settings: AUTH_TYPE=$AUTH_TYPE"

    CAPTURE_PORT=$(jsonfilter -s "$(cat /tmp/isp-ifaces.json 2>/dev/null)" -e '@.capture_port' 2>/dev/null || echo "lan1")
    ip link set "$CAPTURE_PORT" promisc off

    WAN_IFACE=$(uci get network.wan.ifname 2>/dev/null || uci get network.wan.device 2>/dev/null || echo "eth0")

    case "$AUTH_TYPE" in
        pppoe)
            USER="${APPLY_USER:-$(echo "$RESULTS" | jsonfilter -e '@.pppoe.username' 2>/dev/null)}"
            PASS="${APPLY_PASS:-$(echo "$RESULTS" | jsonfilter -e '@.pppoe.password' 2>/dev/null)}"
            VLAN="${APPLY_VLAN:-$(echo "$RESULTS" | jsonfilter -e '@.vlan_id' 2>/dev/null)}"
            MAC="${APPLY_MAC:-$(echo "$RESULTS"  | jsonfilter -e '@.mac_address' 2>/dev/null)}"

            if [ -n "$VLAN" ]; then
                # PPPoE over VLAN — create a VLAN subinterface
                VLAN_IF="${WAN_IFACE}.${VLAN}"
                uci set network.wan_vlan=interface
                uci set network.wan_vlan.ifname="$VLAN_IF"
                uci set network.wan_vlan.proto='pppoe'
                [ -n "$USER" ] && uci set network.wan_vlan.username="$USER"
                [ -n "$PASS" ] && uci set network.wan_vlan.password="$PASS"
                [ -n "$MAC"  ] && uci set network.wan_vlan.macaddr="$MAC"
                log "Configured PPPoE over VLAN $VLAN on $VLAN_IF"
            else
                uci set network.wan.proto='pppoe'
                [ -n "$USER" ] && uci set network.wan.username="$USER"
                [ -n "$PASS" ] && uci set network.wan.password="$PASS"
                [ -n "$MAC"  ] && uci set network.wan.macaddr="$MAC"
                log "Configured PPPoE on $WAN_IFACE"
            fi
            ;;

        dhcp)
            MAC="${APPLY_MAC:-$(echo "$RESULTS" | jsonfilter -e '@.mac_address' 2>/dev/null)}"
            VLAN="${APPLY_VLAN:-$(echo "$RESULTS" | jsonfilter -e '@.vlan_id' 2>/dev/null)}"

            if [ -n "$VLAN" ]; then
                VLAN_IF="${WAN_IFACE}.${VLAN}"
                uci set network.wan.ifname="$VLAN_IF"
            fi
            uci set network.wan.proto='dhcp'
            [ -n "$MAC" ] && uci set network.wan.macaddr="$MAC"
            log "Configured DHCP${VLAN:+ over VLAN $VLAN}"
            ;;

        static)
            IP="${APPLY_IP:-$(echo   "$RESULTS" | jsonfilter -e '@.ip.address' 2>/dev/null)}"
            GW="${APPLY_GW:-$(echo   "$RESULTS" | jsonfilter -e '@.ip.gateway' 2>/dev/null)}"
            NM="${APPLY_NM:-$(echo   "$RESULTS" | jsonfilter -e '@.ip.netmask' 2>/dev/null)}"
            D1="${APPLY_DNS1:-$(echo "$RESULTS" | jsonfilter -e '@.ip.dns1'    2>/dev/null)}"
            D2="${APPLY_DNS2:-$(echo "$RESULTS" | jsonfilter -e '@.ip.dns2'    2>/dev/null)}"
            MAC="${APPLY_MAC:-$(echo "$RESULTS" | jsonfilter -e '@.mac_address' 2>/dev/null)}"
            VLAN="${APPLY_VLAN:-$(echo "$RESULTS" | jsonfilter -e '@.vlan_id' 2>/dev/null)}"

            if [ -n "$VLAN" ]; then
                uci set network.wan.ifname="${WAN_IFACE}.${VLAN}"
            fi
            uci set network.wan.proto='static'
            [ -n "$IP"  ] && uci set network.wan.ipaddr="$IP"
            [ -n "$GW"  ] && uci set network.wan.gateway="$GW"
            [ -n "$NM"  ] && uci set network.wan.netmask="$NM"
            DNS=""
            [ -n "$D1" ] && DNS="$D1"
            [ -n "$D2" ] && DNS="$DNS $D2"
            [ -n "$DNS" ] && uci set network.wan.dns="$DNS"
            [ -n "$MAC" ] && uci set network.wan.macaddr="$MAC"
            log "Configured static IP $IP / $GW / $NM${VLAN:+ over VLAN $VLAN}"
            ;;
    esac

    uci commit network
    /etc/init.d/network restart
    log "Network settings committed and network restarted"
    set_state "applied"
    echo "ok"
}

# ── Step 6: Restore / cleanup ──────────────────────────────────────────────
cleanup() {
    log "Cleaning up..."
    pkill -f tcpdump 2>/dev/null
    CAPTURE_PORT=$(jsonfilter -s "$(cat /tmp/isp-ifaces.json 2>/dev/null)" -e '@.capture_port' 2>/dev/null || echo "lan1")
    ip link set "$CAPTURE_PORT" promisc off
    # Remove all temp files including community DB files
    rm -f /tmp/isp-info.json /tmp/isp-db-submit.json
    set_state "idle"
    echo "ok"
}

restore_wan() {
    log "Restoring original WAN config from backup..."
    if [ -f /tmp/isp-wan-backup.uci ]; then
        while IFS='=' read key val; do
            uci set "$key=$val" 2>/dev/null
        done < /tmp/isp-wan-backup.uci
        uci commit network
        /etc/init.d/network restart
    fi
    set_state "idle"
    echo "ok"
}

# ── Auto-test: disable capture port, build attempt list, test each ──────────
AUTOTEST_FILE="/tmp/isp-autotest.json"
ATTEMPT_WAIT=30   # seconds to wait after applying before ping test

autotest() {
    log "========================================"
    log "AUTO-TEST SEQUENCE STARTING"
    log "========================================"
    set_state "autotesting"

    # ── 1. Release capture port back to normal LAN ───────────────────────
    CAPTURE_PORT=$(jsonfilter -s "$(cat /tmp/isp-ifaces.json 2>/dev/null)" \
        -e '@.capture_port' 2>/dev/null || echo "lan1")
    log "Releasing capture port $CAPTURE_PORT back to LAN..."
    ip link set "$CAPTURE_PORT" promisc off
    # Re-add to LAN bridge if it was removed
    LAN_BR=$(uci get network.lan.ifname 2>/dev/null | grep -o 'br-[a-z0-9]*' | head -1)
    LAN_BR="${LAN_BR:-br-lan}"
    brctl addif "$LAN_BR" "$CAPTURE_PORT" 2>/dev/null || true
    log "Port $CAPTURE_PORT returned to LAN bridge $LAN_BR"

    # ── 2. Read analysis results ─────────────────────────────────────────
    RESULTS=$(cat "$RESULTS_FILE" 2>/dev/null)
    if [ -z "$RESULTS" ]; then
        log "ERROR: No analysis results found — run capture first"
        write_autotest_result "error" "No results to test"
        return
    fi

    AUTH_TYPE=$(echo "$RESULTS" | jsonfilter -e '@.auth_type'       2>/dev/null || echo "unknown")
    PPPOE_USER=$(echo "$RESULTS" | jsonfilter -e '@.pppoe.username'  2>/dev/null)
    PPPOE_PASS=$(echo "$RESULTS" | jsonfilter -e '@.pppoe.password'  2>/dev/null)
    IP_ADDR=$(echo "$RESULTS"   | jsonfilter -e '@.ip.address'      2>/dev/null)
    GW_ADDR=$(echo "$RESULTS"   | jsonfilter -e '@.ip.gateway'      2>/dev/null)
    NETMASK=$(echo "$RESULTS"   | jsonfilter -e '@.ip.netmask'      2>/dev/null)
    DNS1=$(echo "$RESULTS"      | jsonfilter -e '@.ip.dns1'         2>/dev/null || echo "1.1.1.1")
    DNS2=$(echo "$RESULTS"      | jsonfilter -e '@.ip.dns2'         2>/dev/null || echo "1.0.0.1")
    MAC_ADDR=$(echo "$RESULTS"  | jsonfilter -e '@.mac_address'     2>/dev/null)
    VLAN_ID=$(echo "$RESULTS"   | jsonfilter -e '@.vlan_id'         2>/dev/null)

    WAN_IFACE=$(uci get network.wan.ifname  2>/dev/null || \
                uci get network.wan.device  2>/dev/null || echo "eth0")

    # ── 3. Build ordered attempt list ───────────────────────────────────
    # Format: "label|proto|use_mac|use_vlan"
    # Priority: PPPoE > Static > DHCP, each tried plain then +mac then +vlan then +both
    ATTEMPTS=""

    build_attempts() {
        local proto="$1"
        local base_label="$2"
        # Only include combinations where we actually have the data
        ATTEMPTS="$ATTEMPTS ${base_label}|${proto}|no|no"
        [ -n "$MAC_ADDR"  ] && ATTEMPTS="$ATTEMPTS ${base_label}+MAC|${proto}|yes|no"
        [ -n "$VLAN_ID"   ] && ATTEMPTS="$ATTEMPTS ${base_label}+VLAN|${proto}|no|yes"
        [ -n "$MAC_ADDR"  ] && [ -n "$VLAN_ID" ] && \
            ATTEMPTS="$ATTEMPTS ${base_label}+VLAN+MAC|${proto}|yes|yes"
    }

    case "$AUTH_TYPE" in
        pppoe)
            build_attempts "pppoe"  "PPPoE"
            # Also try static and DHCP as fallbacks if we have the data
            [ -n "$IP_ADDR" ] && build_attempts "static" "Static-IP"
            build_attempts "dhcp" "DHCP"
            ;;
        static)
            build_attempts "static" "Static-IP"
            build_attempts "dhcp"   "DHCP"
            [ -n "$PPPOE_USER" ] && build_attempts "pppoe" "PPPoE"
            ;;
        dhcp)
            build_attempts "dhcp"   "DHCP"
            [ -n "$IP_ADDR"    ] && build_attempts "static" "Static-IP"
            [ -n "$PPPOE_USER" ] && build_attempts "pppoe"  "PPPoE"
            ;;
        *)
            # Unknown — try everything we have data for
            [ -n "$PPPOE_USER" ] && build_attempts "pppoe"  "PPPoE"
            [ -n "$IP_ADDR"    ] && build_attempts "static" "Static-IP"
            build_attempts "dhcp" "DHCP"
            ;;
    esac

    TOTAL=$(echo "$ATTEMPTS" | wc -w)
    log "Built $TOTAL attempt combinations to test"

    # ── 4. Write initial status file ─────────────────────────────────────
    TRIED_JSON="[]"
    write_autotest_progress "running" "" "$TRIED_JSON" "0" "$TOTAL"

    # ── 5. Attempt loop ───────────────────────────────────────────────────
    ATTEMPT_NUM=0
    SUCCESS=0
    WINNING_LABEL=""

    for ATTEMPT in $ATTEMPTS; do
        ATTEMPT_NUM=$(( ATTEMPT_NUM + 1 ))
        LABEL=$(echo "$ATTEMPT"   | cut -d'|' -f1)
        PROTO=$(echo "$ATTEMPT"   | cut -d'|' -f2)
        USE_MAC=$(echo "$ATTEMPT" | cut -d'|' -f3)
        USE_VLAN=$(echo "$ATTEMPT" | cut -d'|' -f4)

        log "----------------------------------------"
        log "Attempt $ATTEMPT_NUM/$TOTAL: $LABEL"
        log "  Proto=$PROTO  MAC=$USE_MAC  VLAN=$USE_VLAN"

        write_autotest_progress "running" "$LABEL" "$TRIED_JSON" "$ATTEMPT_NUM" "$TOTAL"

        # ── Apply this attempt's config ───────────────────────────────
        # Determine effective WAN ifname (with or without VLAN)
        if [ "$USE_VLAN" = "yes" ] && [ -n "$VLAN_ID" ]; then
            EFFECTIVE_IFACE="${WAN_IFACE}.${VLAN_ID}"
        else
            EFFECTIVE_IFACE="$WAN_IFACE"
        fi

        # Wipe previous WAN config cleanly
        uci revert network.wan 2>/dev/null
        uci delete network.wan_vlan 2>/dev/null

        case "$PROTO" in
            pppoe)
                uci set network.wan.proto='pppoe'
                uci set network.wan.ifname="$EFFECTIVE_IFACE"
                [ -n "$PPPOE_USER" ] && uci set network.wan.username="$PPPOE_USER"
                [ -n "$PPPOE_PASS" ] && uci set network.wan.password="$PPPOE_PASS"
                [ "$USE_MAC" = "yes" ] && [ -n "$MAC_ADDR" ] && \
                    uci set network.wan.macaddr="$MAC_ADDR"
                ;;
            static)
                uci set network.wan.proto='static'
                uci set network.wan.ifname="$EFFECTIVE_IFACE"
                [ -n "$IP_ADDR" ] && uci set network.wan.ipaddr="$IP_ADDR"
                [ -n "$GW_ADDR" ] && uci set network.wan.gateway="$GW_ADDR"
                [ -n "$NETMASK" ] && uci set network.wan.netmask="$NETMASK"
                uci set network.wan.dns="$DNS1 $DNS2"
                [ "$USE_MAC" = "yes" ] && [ -n "$MAC_ADDR" ] && \
                    uci set network.wan.macaddr="$MAC_ADDR"
                ;;
            dhcp)
                uci set network.wan.proto='dhcp'
                uci set network.wan.ifname="$EFFECTIVE_IFACE"
                [ "$USE_MAC" = "yes" ] && [ -n "$MAC_ADDR" ] && \
                    uci set network.wan.macaddr="$MAC_ADDR"
                ;;
        esac

        uci commit network

        # ── Restart WAN interface only (not full network restart) ─────
        log "Restarting WAN interface..."
        ifdown wan 2>/dev/null; sleep 2; ifup wan 2>/dev/null

        # ── Wait for interface to come up ────────────────────────────
        log "Waiting ${ATTEMPT_WAIT}s for interface to establish..."
        WAITED=0
        while [ "$WAITED" -lt "$ATTEMPT_WAIT" ]; do
            sleep 5
            WAITED=$(( WAITED + 5 ))
            # Early-exit if we already have a WAN IP (saves time)
            WAN_IP=$(ip addr show dev "$WAN_IFACE" 2>/dev/null | \
                grep -oE 'inet [0-9.]+' | grep -v '169\.254' | head -1)
            if [ -n "$WAN_IP" ]; then
                log "WAN IP detected early: $WAN_IP (after ${WAITED}s)"
                break
            fi
        done

        # ── Ping test ────────────────────────────────────────────────
        log "Ping test: 8.8.8.8 via WAN..."
        PING_RESULT=$(ping -c 3 -W 4 -I "$WAN_IFACE" 8.8.8.8 2>&1)
        PING_OK=$?

        # Fallback: ping without binding to interface (some setups need this)
        if [ "$PING_OK" -ne 0 ]; then
            PING_RESULT2=$(ping -c 3 -W 4 8.8.8.8 2>&1)
            PING_OK2=$?
            if [ "$PING_OK2" -eq 0 ]; then
                PING_OK=0
                PING_RESULT="$PING_RESULT2 (unbound)"
                log "Ping succeeded without interface binding"
            fi
        fi

        # Extract RTT for reporting
        RTT=$(echo "$PING_RESULT" | grep -oE 'avg[^/]*/([0-9.]+)' | grep -oE '[0-9.]+$')
        [ -z "$RTT" ] && RTT=$(echo "$PING_RESULT" | grep -oE 'time=[0-9.]+' | head -1 | grep -oE '[0-9.]+$')

        # Record this attempt
        STATUS_CHAR="fail"
        [ "$PING_OK" -eq 0 ] && STATUS_CHAR="pass"

        TRIED_JSON=$(append_attempt_json "$TRIED_JSON" \
            "$ATTEMPT_NUM" "$LABEL" "$PROTO" "$USE_MAC" "$USE_VLAN" "$STATUS_CHAR" "$RTT")

        if [ "$PING_OK" -eq 0 ]; then
            log "✓ CONNECTED! Attempt $ATTEMPT_NUM ($LABEL) succeeded"
            [ -n "$RTT" ] && log "  Ping RTT: ${RTT}ms"
            WINNING_LABEL="$LABEL"
            SUCCESS=1
            break
        else
            log "✗ Attempt $ATTEMPT_NUM ($LABEL) failed — no connectivity"
        fi
    done

    # ── 6. Final outcome ──────────────────────────────────────────────────
    if [ "$SUCCESS" -eq 1 ]; then
        log "========================================"
        log "SUCCESS: Connected using: $WINNING_LABEL"
        log "========================================"
        write_autotest_progress "success" "$WINNING_LABEL" "$TRIED_JSON" "$ATTEMPT_NUM" "$TOTAL"
        set_state "connected"

        # ── Community DB: WAN is now up — identify ISP for the submit panel ──
        # lookup_isp is read-only (queries ip-api.com, writes ISP_INFO_FILE).
        # Nothing is submitted to the community DB here — that only happens
        # if the user explicitly clicks "Submit" in the results page.
        lookup_isp >> "$LOG_FILE" 2>&1 &
    else
        log "========================================"
        log "ALL $TOTAL ATTEMPTS FAILED"
        log "Last config left in place for manual adjustment"
        log "========================================"
        write_autotest_progress "failed" "" "$TRIED_JSON" "$ATTEMPT_NUM" "$TOTAL"
        set_state "autotest_failed"
    fi
}

append_attempt_json() {
    EXISTING="$1"
    NUM="$2"
    LABEL="$3"
    PROTO="$4"
    USE_MAC="$5"
    USE_VLAN="$6"
    STATUS="$7"
    RTT="${8:-}"

    NEW_ENTRY="{\"num\":$NUM,\"label\":\"$LABEL\",\"proto\":\"$PROTO\",\"mac\":\"$USE_MAC\",\"vlan\":\"$USE_VLAN\",\"status\":\"$STATUS\",\"rtt\":\"$RTT\"}"

    if [ "$EXISTING" = "[]" ]; then
        echo "[$NEW_ENTRY]"
    else
        echo "${EXISTING%]},${NEW_ENTRY}]"
    fi
}

write_autotest_progress() {
    STATUS="$1"
    CURRENT_LABEL="$2"
    TRIED="$3"
    DONE="$4"
    TOTAL="$5"

    cat > "$AUTOTEST_FILE" << EOF
{
  "status": "$STATUS",
  "current": "$CURRENT_LABEL",
  "attempts_done": $DONE,
  "attempts_total": $TOTAL,
  "tried": $TRIED,
  "timestamp": "$(date -Iseconds)"
}
EOF
}

write_autotest_result() {
    cat > "$AUTOTEST_FILE" << EOF
{"status":"$1","error":"$2","tried":[],"attempts_done":0,"attempts_total":0}
EOF
    set_state "autotest_failed"
}

# ── Community DB: lookup current WAN IP with ip-api.com ───────────────────
# Writes ISP_INFO_FILE:
#   {"country":"GB","countryName":"United Kingdom","isp":"Sky UK","as":"AS5607"}
# Called during detect (step 1) so the result is ready when the wizard loads.
lookup_isp() {
    if [ -z "$SUPABASE_URL" ]; then
        log "Community DB: not configured (SUPABASE_URL empty) — skipping ISP lookup"
        echo '{"error":"not_configured"}' > "$ISP_INFO_FILE"
        return
    fi

    log "Community DB: looking up ISP via ip-api.com..."

    # Determine WAN IP — try the WAN interface first, fall back to any routable IP
    WAN_IFACE=$(uci get network.wan.ifname 2>/dev/null || \
                uci get network.wan.device 2>/dev/null || echo "")
    WAN_IP=""
    if [ -n "$WAN_IFACE" ]; then
        WAN_IP=$(ip addr show dev "$WAN_IFACE" 2>/dev/null | \
            grep -oE 'inet [0-9.]+' | grep -v '169\.254' | head -1 | awk '{print $2}')
    fi
    # Fallback: ask ip-api.com to auto-detect our IP (omit the IP from the URL)
    if [ -z "$WAN_IP" ]; then
        log "  Could not determine WAN IP — using ip-api.com auto-detect"
        WAN_IP=""
    fi

    # ip-api.com — free, no key, HTTP (avoids SSL cert issues on OpenWrt)
    # Rate limit: 45 req/min per IP — irrelevant for router use
    URL="http://ip-api.com/json/${WAN_IP}?fields=status,country,countryCode,isp,as,org"

    RESPONSE=$(wget -qO- --timeout=8 "$URL" 2>/dev/null)
    if [ -z "$RESPONSE" ]; then
        log "  ip-api.com: no response (offline or DNS not ready?)"
        echo '{"error":"no_response"}' > "$ISP_INFO_FILE"
        return
    fi

    # Quick check: did we get a valid response?
    STATUS=$(echo "$RESPONSE" | grep -o '"status":"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
    if [ "$STATUS" != "success" ]; then
        log "  ip-api.com: returned status=$STATUS"
        echo "$RESPONSE" > "$ISP_INFO_FILE"
        return
    fi

    echo "$RESPONSE" > "$ISP_INFO_FILE"
    ASN=$(echo "$RESPONSE" | grep -o '"as":"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
    ISP=$(echo "$RESPONSE" | grep -o '"isp":"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
    log "  ISP: $ISP  ASN: $ASN"
}


# ── Community DB: submit working config after auto-test success ─────────────
# Called from autotest() success block with:
#   $1 = "yes"/"no"  — whether MAC cloning was needed
#   $2 = integer     — how many attempts were needed
#   $3 = "yes"/"no"  — whether auto-test actually connected (vs manual/skipped)
# Runs in a background subshell — never blocks the main flow.
# NEVER sends: usernames, passwords, MAC addresses, IP addresses.
db_submit_config() {
    if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
        log "Community DB: not configured — skipping submission"
        return
    fi

    # ── ISP identity from ip-api.com (populated by lookup_isp above) ─────
    if [ ! -f "$ISP_INFO_FILE" ]; then
        log "Community DB: no ISP info available — skipping"
        return
    fi
    COUNTRY_CODE=$(grep -o '"countryCode":"[^"]*"' "$ISP_INFO_FILE" | grep -o '"[^"]*"$' | tr -d '"')
    COUNTRY_NAME=$(grep -o '"country":"[^"]*"'     "$ISP_INFO_FILE" | grep -o '"[^"]*"$' | tr -d '"')
    ISP_NAME=$(grep -o '"isp":"[^"]*"'             "$ISP_INFO_FILE" | grep -o '"[^"]*"$' | tr -d '"')
    ASN=$(grep -o '"as":"[^"]*"'                   "$ISP_INFO_FILE" | grep -o '"[^"]*"$' | tr -d '"')

    # ── Capture results ───────────────────────────────────────────────────
    if [ ! -f "$RESULTS_FILE" ]; then
        log "Community DB: no capture results — skipping"
        return
    fi
    AUTH_TYPE=$(grep -o '"auth_type":"[^"]*"'   "$RESULTS_FILE" | grep -o '"[^"]*"$' | tr -d '"')
    AUTH_METHOD=$(grep -o '"auth_method":"[^"]*"' "$RESULTS_FILE" | grep -o '"[^"]*"$' | tr -d '"')
    VLAN_ID=$(grep -o '"vlan_id":"[^"]*"'        "$RESULTS_FILE" | grep -o '"[^"]*"$' | tr -d '"')

    # ── Winning attempt parameters (passed in) ────────────────────────────
    MAC_CLONE_NEEDED_BOOL="false"
    [ "$1" = "yes" ] && MAC_CLONE_NEEDED_BOOL="true"

    AUTO_CONNECTED_BOOL="false"
    [ "$3" = "yes" ] && AUTO_CONNECTED_BOOL="true"

    ATTEMPTS_NEEDED="${2:-null}"
    [ "$AUTO_CONNECTED_BOOL" = "false" ] && ATTEMPTS_NEEDED="null"

    # ── Privacy booleans — derived from capture, no raw values sent ───────
    # username_capturable: true only if PPPoE PAP username appeared in clear
    USERNAME_CAPTURABLE="false"
    _u=$(grep -o '"username":"[^"]*"' "$RESULTS_FILE" | grep -o '"[^"]*"$' | tr -d '"')
    [ -n "$_u" ] && [ "$AUTH_METHOD" = "PAP" ] && USERNAME_CAPTURABLE="true"
    unset _u

    # password_capturable: same condition — PAP sends password in clear too
    PASSWORD_CAPTURABLE="$USERNAME_CAPTURABLE"

    # Normalise auth_method — default to NONE for non-PPPoE
    [ -z "$AUTH_METHOD" ] && AUTH_METHOD="NONE"

    # OpenWrt version
    OWRT_VER=$(grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d'=' -f2 | tr -d '"')

    log "Community DB: submitting — ASN=$ASN auth=$AUTH_TYPE/$AUTH_METHOD vlan=${VLAN_ID:-none} mac_clone=$MAC_CLONE_NEEDED_BOOL user_capturable=$USERNAME_CAPTURABLE connected=$AUTO_CONNECTED_BOOL"

    # ── JSON body — no PII ────────────────────────────────────────────────
    BODY=$(printf '{
  "p_country_code":        "%s",
  "p_country_name":        "%s",
  "p_isp_name":            "%s",
  "p_asn":                 "%s",
  "p_auth_type":           "%s",
  "p_auth_method":         "%s",
  "p_vlan_id":             %s,
  "p_mac_clone_needed":    %s,
  "p_username_capturable": %s,
  "p_password_capturable": %s,
  "p_auto_connected":      %s,
  "p_openwrt_version":     "%s",
  "p_attempts_needed":     %s
}' \
        "$COUNTRY_CODE" "$COUNTRY_NAME" "$ISP_NAME" "$ASN" \
        "$AUTH_TYPE" "$AUTH_METHOD" \
        "$([ -n "$VLAN_ID" ] && echo "\"$VLAN_ID\"" || echo 'null')" \
        "$MAC_CLONE_NEEDED_BOOL" \
        "$USERNAME_CAPTURABLE" \
        "$PASSWORD_CAPTURABLE" \
        "$AUTO_CONNECTED_BOOL" \
        "$OWRT_VER" \
        "$ATTEMPTS_NEEDED")



    # Call the submit_isp_config Postgres function via Supabase RPC
    RESPONSE=$(wget -qO- \
        --method=POST \
        --header="apikey: ${SUPABASE_KEY}" \
        --header="Authorization: Bearer ${SUPABASE_KEY}" \
        --header="Content-Type: application/json" \
        --body-data="$BODY" \
        --timeout=10 \
        "${SUPABASE_URL}/rest/v1/rpc/submit_isp_config" 2>/dev/null)

    if [ -n "$RESPONSE" ]; then
        log "  Community DB: submitted — $RESPONSE"
        echo "$RESPONSE" > /tmp/isp-db-submit.json
    else
        log "  Community DB: submission failed (network error or timeout)"
    fi
}

# ── Main dispatcher ────────────────────────────────────────────────────────
case "$1" in
    detect)       detect_interfaces ;;
    setup)        setup_bridge "$2" ;;
    capture)      start_capture "$2" ;;
    stop)         stop_capture_and_analyse ;;
    analyse)      analyse_capture ;;
    autotest)     autotest ;;
    apply)        apply_settings ;;
    restore)      restore_wan ;;
    cleanup)      cleanup ;;
    state)        get_state ;;
    results)      cat "$RESULTS_FILE"   2>/dev/null || echo '{"status":"no_results"}' ;;
    autotest_results) cat "$AUTOTEST_FILE" 2>/dev/null || echo '{"status":"no_results"}' ;;
    log)          cat "$LOG_FILE" 2>/dev/null ;;
    isp_info)     cat "$ISP_INFO_FILE" 2>/dev/null || echo '{"status":"not_ready"}' ;;
    db_submit)
        [ ! -f "$ISP_INFO_FILE" ] && lookup_isp
        db_submit_config "$2" "$3" "yes"
        ;;
    *)
        echo "Usage: $0 {detect|setup|capture|stop|autotest|apply|restore|cleanup|state|results|log|isp_info|db_submit}"
        exit 1
        ;;
esac
