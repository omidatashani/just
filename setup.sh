#!/bin/bash

# =========================================================
#  ADVANCED SETUP: PAQET + X-UI + MIRRORS + VMESS GEN
# =========================================================

# --- CONFIG ---
PAQET_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz"
XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/v2.4.4/x-ui-linux-amd64.tar.gz"
CORE_URL="https://github.com/GFW-knocker/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$EUID" -ne 0 ]; then print_error "Please run as root (sudo bash setup.sh)"; fi
}

# --- ROBUST MIRROR FIXER ---
fix_apt_mirrors() {
    print_warn "Apt failed. Checking 20+ Iran Mirrors..."
    
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [ "$ID" != "ubuntu" ]; then return; fi
        CODENAME=$VERSION_CODENAME
    else
        return
    fi

    MIRRORS=(
      "https://mirrors.pardisco.co/ubuntu/"
      "http://mirror.aminidc.com/ubuntu/"
      "http://mirror.faraso.org/ubuntu/"
      "https://ir.ubuntu.sindad.cloud/ubuntu/"
      "https://ubuntu-mirror.kimiahost.com/"
      "https://archive.ubuntu.petiak.ir/ubuntu/"
      "https://ubuntu.hostiran.ir/ubuntuarchive/"
      "https://ubuntu.bardia.tech/"
      "https://mirror.iranserver.com/ubuntu/"
      "https://ir.archive.ubuntu.com/ubuntu/"
      "https://mirror.0-1.cloud/ubuntu/"
      "http://linuxmirrors.ir/pub/ubuntu/"
      "http://repo.iut.ac.ir/repo/Ubuntu/"
      "https://ubuntu.shatel.ir/ubuntu/"
      "http://ubuntu.byteiran.com/ubuntu/"
      "https://mirror.rasanegar.com/ubuntu/"
      "http://mirrors.sharif.ir/ubuntu/"
      "http://mirror.ut.ac.ir/ubuntu/"
      "http://mirror.asiatech.ir/ubuntu/"
      "http://archive.ubuntu.com/ubuntu/"
    )

    WORKING_MIRROR=""
    for MIRROR in "${MIRRORS[@]}"; do
        echo -ne "   Testing $MIRROR ... "
        if curl -s --head --max-time 1 "$MIRROR" | grep -q "200 OK"; then
            echo -e "${GREEN}OK${NC}"
            WORKING_MIRROR=$MIRROR
            break
        else
            echo -e "${RED}FAIL${NC}"
        fi
    done

    if [ -n "$WORKING_MIRROR" ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        cat <<EOF > /etc/apt/sources.list
deb ${WORKING_MIRROR} ${CODENAME} main restricted universe multiverse
deb ${WORKING_MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${WORKING_MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${WORKING_MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF
        print_success "Switched to: $WORKING_MIRROR"
        apt-get update
    fi
}

install_dependencies() {
    print_info "Checking dependencies..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 2; done

    # Added sqlite3 for database manipulation
    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq"
    
    if ! apt-get install -y $PKGS; then
        fix_apt_mirrors
        apt-get --fix-broken install -y
        apt-get install -y $PKGS
    fi
}

# --- SMART FILE GETTER ---
get_file() {
    local name=$1; local url=$2; local outfile=$3
    echo -e "${YELLOW}>>> How to get $name?${NC}"
    echo "   1) Download (Default)"
    echo "   2) Local File"
    read -p "   Select [1-2] (Enter=1): " choice; choice=${choice:-1}
    
    if [ "$choice" == "2" ]; then
        while true; do
            read -p "   Path (e.g. /root/file.tar.gz): " localpath
            if [ -f "$localpath" ]; then cp "$localpath" "$outfile"; return 0; fi
            print_warn "File not found."
        done
    else
        wget --show-progress -q -T 60 -c -O "$outfile" "$url"
        if [ -s "$outfile" ]; then return 0; fi
        print_error "Download failed."
    fi
}

detect_network() {
    print_info "Detecting network..."
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    
    # Robust IP Check
    SERVICES=("http://ipv4.icanhazip.com" "http://api.ipify.org" "http://ifconfig.me/ip")
    for S in "${SERVICES[@]}"; do
        PUBLIC_IP=$(curl -s --max-time 3 "$S")
        [[ "$PUBLIC_IP" =~ ^[0-9]+\. ]] && break
    done
    [ -z "$PUBLIC_IP" ] && read -p ">>> Could not detect IP. Enter manually: " PUBLIC_IP
    
    GATEWAY_IP=$(ip r | grep default | awk '{print $3}' | head -n 1)
    ping -c 1 -W 1 $GATEWAY_IP >/dev/null 2>&1
    GATEWAY_MAC=$(ip neigh show $GATEWAY_IP | awk '{print $5}' | head -n 1)
    if [ -z "$GATEWAY_MAC" ] && command -v arp >/dev/null; then
         GATEWAY_MAC=$(arp -an $GATEWAY_IP | awk '{print $4}' | head -n 1)
    fi

    if [ -z "$IFACE" ]; then print_error "Network fail."; fi
    print_success "IP: $PUBLIC_IP | Iface: $IFACE | GW: $GATEWAY_MAC"
}

setup_firewall() {
    local target=$1; local port=$2; local mode=$3
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    
    if [ "$mode" == "server" ]; then
        iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
        iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
        iptables -t filter -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -t filter -A OUTPUT -p tcp --sport $port -j ACCEPT
    else
        iptables -t raw -A OUTPUT -p tcp -d $target --dport $port -j NOTRACK
        iptables -t raw -A PREROUTING -p tcp -s $target --sport $port -j NOTRACK
        iptables -t filter -A OUTPUT -p tcp -d $target --dport $port -j ACCEPT
        iptables -t filter -A INPUT -p tcp -s $target --sport $port -j ACCEPT
        iptables -t mangle -A OUTPUT -p tcp -d $target --dport $port --tcp-flags RST RST -j DROP
    fi
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP
    if command -v netfilter-persistent >/dev/null; then netfilter-persistent save >/dev/null 2>&1; fi
}

install_paqet() {
    cd /root; rm -f paqet*
    get_file "Paqet" "$PAQET_URL" "paqet.tar.gz"
    tar -xzf paqet.tar.gz
    if [ -f "paqet_linux_amd64" ]; then mv paqet_linux_amd64 paqet; fi
    if [ -f "paqet-linux-amd64" ]; then mv paqet-linux-amd64 paqet; fi
    chmod +x paqet
}

# --- X-UI & VMESS GENERATION ---
install_xui_advanced() {
    echo ""; read -p ">>> Install 3X-UI Panel? [Y/n]: " install_xui; install_xui=${install_xui:-y}
    if [[ ! "$install_xui" =~ ^[Yy]$ ]]; then return; fi

    cd /root; rm -rf x-ui*
    get_file "X-UI Panel" "$XUI_URL" "x-ui.tar.gz"
    
    tar zxf x-ui.tar.gz
    rm -rf /usr/local/x-ui
    mv x-ui /usr/local/
    chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/x-ui.sh
    cp /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    
    if [ ! -f "/etc/systemd/system/x-ui.service" ]; then
        wget -q -O /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
    fi

    # Swap Core Choice
    read -p ">>> Swap Xray Core to GFW-Knocker? [y/N]: " swap_core; swap_core=${swap_core:-n}
    if [[ "$swap_core" =~ ^[Yy]$ ]]; then
        get_file "GFW-Knocker Core" "$CORE_URL" "xray.zip"
        unzip -o xray.zip -d xray_temp
        mv xray_temp/xray /usr/local/x-ui/bin/xray-linux-amd64
        chmod +x /usr/local/x-ui/bin/xray-linux-amd64
        rm -rf xray.zip xray_temp
    fi

    systemctl daemon-reload; systemctl enable x-ui; systemctl restart x-ui
    print_success "X-UI Installed."

    # --- AUTOMATED INBOUND CREATION ---
    echo ""; read -p ">>> Auto-create VMess User? [Y/n]: " create_vmess; create_vmess=${create_vmess:-y}
    if [[ "$create_vmess" =~ ^[Yy]$ ]]; then
        
        # 1. Gather Data
        UUID=$(cat /proc/sys/kernel/random/uuid)
        RAND_PORT=$(shuf -i 2000-60000 -n 1)
        read -p "   Traffic Limit (GB) [0 = Unlimited]: " LIMIT_GB; LIMIT_GB=${LIMIT_GB:-0}
        LIMIT_BYTES=$((LIMIT_GB * 1024 * 1024 * 1024))
        
        # 2. Insert into DB
        print_info "Adding Inbound to Database..."
        # Settings JSON for VMess
        SETTINGS="{\"clients\": [{\"id\": \"$UUID\", \"alterId\": 0, \"email\": \"paqet_user\", \"limitIp\": 0, \"totalGB\": $LIMIT_BYTES, \"expiryTime\": 0, \"enable\": true, \"tgId\": \"\", \"subId\": \"\"}], \"disableInsecureEncryption\": false}"
        # Stream Settings JSON
        STREAM="{\"network\": \"tcp\", \"security\": \"none\", \"tcpSettings\": {\"acceptProxyProtocol\": false, \"header\": {\"type\": \"none\"}}}"
        # Sniffing JSON
        SNIFF="{\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\", \"fakedns\"], \"metadataOnly\": false, \"routeOnly\": false}"

        sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, client_stats, tag, protocol, port, settings, stream_settings, sniffing, listen) VALUES (1, 0, 0, $LIMIT_BYTES, 'Paqet-VMess', 1, 0, 0, 'vmess_auto', 'vmess', $RAND_PORT, '$SETTINGS', '$STREAM', '$SNIFF', '');"
        
        # 3. Generate Link
        VMESS_JSON="{\"v\":\"2\",\"ps\":\"Paqet-Tunnel\",\"add\":\"$PUBLIC_IP\",\"port\":\"$RAND_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"\"}"
        VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        
        # 4. Restart X-UI to apply
        systemctl restart x-ui
        
        echo ""
        echo "=========================================================="
        echo "✅ VMESS LINK CREATED:"
        echo -e "${GREEN}$VMESS_LINK${NC}"
        echo "=========================================================="
    fi
}

check_tunnel() {
    local remote=$1
    print_info "Checking Tunnel..."
    sleep 3
    IP=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:1080 http://ifconfig.me)
    if [ "$IP" == "$remote" ]; then print_success "TUNNEL OK! Exit: $IP"; else print_warn "Check: $IP"; fi
}

# --- MAIN ---
check_root; clear
echo "=========================================================="
echo "    ADVANCED SETUP (Mirrors + VMess Gen)                 "
echo "=========================================================="
echo "1) KHAREJ (Germany)"; echo "2) IRAN (Client)"
read -p "Select [1-2]: " ROLE

if [ "$ROLE" == "1" ]; then
    install_dependencies; detect_network
    read -p "Port [8880]: " PORT; PORT=${PORT:-8880}
    KEY=$(openssl rand -hex 16)
    
    install_paqet; setup_firewall "0.0.0.0" "$PORT" "server"
    
    cat <<EOF > /root/server.yaml
role: "server"
log:
  level: "info"
listen:
  addr: ":$PORT"
network:
  interface: "$IFACE"
  ipv4:
    addr: "$PUBLIC_IP:$PORT"
    router_mac: "$GATEWAY_MAC"
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$KEY"
EOF
    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Server
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/root/paqet run -c /root/server.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
    echo ""; print_success "DONE! SAVE THESE:"
    echo "IP: $PUBLIC_IP | PORT: $PORT | KEY: $KEY"

elif [ "$ROLE" == "2" ]; then
    install_dependencies; detect_network
    read -p "Kharej IP: " REMOTE_IP
    read -p "Port [8880]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-8880}
    read -p "Key: " KEY
    
    install_paqet; setup_firewall "$REMOTE_IP" "$REMOTE_PORT" "client"
    
    cat <<EOF > /root/client.yaml
role: "client"
log:
  level: "info"
socks5:
  - listen: "127.0.0.1:1080"
network:
  interface: "$IFACE"
  ipv4:
    addr: "$PUBLIC_IP:0"
    router_mac: "$GATEWAY_MAC"
server:
  addr: "$REMOTE_IP:$REMOTE_PORT"
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$KEY"
EOF
    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Client
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/root/paqet run -c /root/client.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
    
    check_tunnel "$REMOTE_IP"
    install_xui_advanced
    
    echo "=========================================================="
    echo "SETUP COMPLETE."
    echo "1. Configure Panel Settings -> Outbounds -> SOCKS 127.0.0.1:1080"
    echo "2. Use the generated VMess link above."
    echo "=========================================================="
fi