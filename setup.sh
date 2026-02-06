#!/bin/bash

# =========================================================
#  PAQET TUNNEL PRO V2 (Configurable Defaults)
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
CYAN='\033[0;36m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$EUID" -ne 0 ]; then print_error "Please run as root (sudo bash setup.sh)"; fi
}

optimize_dns() {
    print_info "Optimizing DNS..."
    [ ! -f /etc/resolv.conf.bak ] && cp /etc/resolv.conf /etc/resolv.conf.bak
    cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
EOF
}

fix_apt_mirrors() {
    print_warn "Apt failed. Finding fastest Iran mirror..."
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [ "$ID" != "ubuntu" ]; then return; fi
        CODENAME=$VERSION_CODENAME
    else
        return
    fi

    MIRRORS=(
      "http://mirror.iranserver.com/ubuntu/"
      "https://mirrors.pardisco.co/ubuntu/"
      "http://mirror.aminidc.com/ubuntu/"
      "https://ubuntu.shatel.ir/ubuntu/"
      "http://mirror.asiatech.ir/ubuntu/"
    )

    BEST_MIRROR=""
    BEST_TIME=1000

    for MIRROR in "${MIRRORS[@]}"; do
        TIME=$(curl -o /dev/null -s -w '%{time_total}\n' --max-time 2 "$MIRROR")
        if [ $? -eq 0 ] && (( $(echo "$TIME < $BEST_TIME" | bc -l) )); then
            BEST_TIME=$TIME
            BEST_MIRROR=$MIRROR
        fi
    done

    if [ -n "$BEST_MIRROR" ]; then
        print_success "Fastest Mirror: $BEST_MIRROR"
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        cat <<EOF > /etc/apt/sources.list
deb ${BEST_MIRROR} ${CODENAME} main restricted universe multiverse
deb ${BEST_MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${BEST_MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${BEST_MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF
        apt-get update
    fi
}

install_dependencies() {
    print_info "Checking dependencies..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 2; done

    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq bc"
    
    if ! apt-get install -y --no-install-recommends $PKGS; then
        optimize_dns
        fix_apt_mirrors
        apt-get --fix-broken install -y
        apt-get install -y --no-install-recommends $PKGS
    fi
}

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
    print_success "IP: $PUBLIC_IP | Iface: $IFACE"
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

# --- STANDALONE CORE (NO PANEL) SETUP ---
install_core_only() {
    echo ""; read -p ">>> Setup Standalone VMess (Core Only)? [y/N]: " setup_core; setup_core=${setup_core:-n}
    if [[ ! "$setup_core" =~ ^[Yy]$ ]]; then return; fi

    print_info "Installing Xray Core..."
    cd /root
    get_file "Xray Core" "$CORE_URL" "xray.zip"
    
    mkdir -p /usr/local/bin /usr/local/etc/xray
    unzip -o xray.zip -d xray_temp >/dev/null
    mv xray_temp/xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    rm -rf xray.zip xray_temp

    # Config Generation
    UUID=$(cat /proc/sys/kernel/random/uuid)
    RAND_PORT=$(shuf -i 2000-60000 -n 1)
    
    cat <<EOF > /usr/local/etc/xray/config.json
{
  "inbounds": [{
    "port": $RAND_PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "$UUID", "alterId": 0 }]
    },
    "streamSettings": { "network": "tcp" }
  }],
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [{ "address": "127.0.0.1", "port": 1080 }]
      }
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

    # Service
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/xray -config /usr/local/etc/xray/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    
    # Link Generation
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Paqet-Core\",\"add\":\"$PUBLIC_IP\",\"port\":\"$RAND_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"\"}"
    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
    
    echo ""; echo "=========================================================="
    echo "✅ STANDALONE VMESS LINK:"; echo -e "${CYAN}$VMESS_LINK${NC}"
    echo "=========================================================="
}

# --- X-UI & AUTOMATION ---
install_xui_logic() {
    # Default is NO
    echo ""; read -p ">>> Install 3X-UI Panel? [y/N]: " install_xui; install_xui=${install_xui:-n}
    
    if [[ "$install_xui" =~ ^[Yy]$ ]]; then
        # Install Panel
        cd /root; rm -rf x-ui*
        get_file "X-UI Panel" "$XUI_URL" "x-ui.tar.gz"
        tar zxf x-ui.tar.gz
        rm -rf /usr/local/x-ui; mv x-ui /usr/local/
        chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/x-ui.sh
        cp /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
        if [ ! -f "/etc/systemd/system/x-ui.service" ]; then
            wget -q -O /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
        fi
        
        # Core Swap (Default No)
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

        # Automated Inbound
        echo ""; read -p ">>> Auto-create VMess User? [y/N]: " create_vmess; create_vmess=${create_vmess:-n}
        if [[ "$create_vmess" =~ ^[Yy]$ ]]; then
            UUID=$(cat /proc/sys/kernel/random/uuid)
            RAND_PORT=$(shuf -i 2000-60000 -n 1)
            SETTINGS="{\"clients\": [{\"id\": \"$UUID\", \"alterId\": 0, \"email\": \"paqet_user\", \"limitIp\": 0, \"totalGB\": 0, \"expiryTime\": 0, \"enable\": true, \"tgId\": \"\", \"subId\": \"\"}], \"disableInsecureEncryption\": false}"
            STREAM="{\"network\": \"tcp\", \"security\": \"none\", \"tcpSettings\": {\"acceptProxyProtocol\": false, \"header\": {\"type\": \"none\"}}}"
            SNIFF="{\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\", \"fakedns\"], \"metadataOnly\": false, \"routeOnly\": false}"

            sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, client_stats, tag, protocol, port, settings, stream_settings, sniffing, listen) VALUES (1, 0, 0, 0, 'Paqet-VMess', 1, 0, 0, 'vmess_auto', 'vmess', $RAND_PORT, '$SETTINGS', '$STREAM', '$SNIFF', '');"
            
            VMESS_JSON="{\"v\":\"2\",\"ps\":\"Paqet-Tunnel\",\"add\":\"$PUBLIC_IP\",\"port\":\"$RAND_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"\"}"
            VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
            
            systemctl restart x-ui
            echo ""; echo "=========================================================="
            echo "✅ VMESS LINK:"; echo -e "${CYAN}$VMESS_LINK${NC}"
            echo "=========================================================="
        fi
    else
        # If NO Panel -> Ask for Core Only
        install_core_only
    fi
}

check_tunnel() {
    print_info "Checking Tunnel..."
    sleep 3
    # Use ifconfig.me which often returns IPv6 if available
    IP=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:1080 http://ifconfig.me)
    
    # Success Logic: If IP is NOT empty and NOT our local IP, it's working (v4 or v6)
    if [ -n "$IP" ] && [ "$IP" != "$PUBLIC_IP" ]; then
        print_success "TUNNEL SUCCESS! Exit IP: $IP"
    else
        print_warn "Tunnel check inconclusive: $IP"
    fi
}

# --- MAIN ---
clear
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          PAQET TUNNEL SETUP (IRAN OPTIMIZED)                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
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
    print_info "Optimizing Iran Server..."
    optimize_dns
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
    install_xui_logic
    
    echo "=========================================================="
    echo "SETUP COMPLETE."
    echo "If you used X-UI or Core, your V2Ray config is ready."
    echo "=========================================================="
fi