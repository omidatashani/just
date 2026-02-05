#!/bin/bash

# =========================================================
#  FINAL ROBUST SETUP: PAQET + XRAY (GFW-Knocker)
# =========================================================

# --- CONFIGURATION ---
# Using the working Alpha 14 link from hanselime
PAQET_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz"
# Using a stable mirror for X-UI
XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/v2.4.4/x-ui-linux-amd64.tar.gz"
# GFW Knocker Core
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
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (sudo bash setup.sh)"
    fi
}

# Robust Downloader with Retries
download_file() {
    local url=$1
    local output=$2
    local retries=3
    local count=0

    until [ $count -ge $retries ]; do
        wget --show-progress -q -T 45 -c -O "$output" "$url"
        # Check if file exists and is larger than 1KB
        if [ -s "$output" ] && [ $(stat -c%s "$output") -gt 1024 ]; then
            return 0
        fi
        print_warn "Download failed or incomplete. Retrying ($((count+1))/$retries)..."
        rm -f "$output"
        sleep 2
        count=$((count+1))
    done
    print_error "Failed to download $output after multiple attempts. Check internet/DNS."
}

optimize_iran_repo() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [ "$ID" != "ubuntu" ]; then return; fi
        UBUNTU_CODENAME=$VERSION_CODENAME
    else
        return
    fi
    
    print_info "Optimizing Mirrors for Iran..."
    # Quick check a reliable mirror
    if ! curl -s --head --max-time 2 "http://archive.ubuntu.com/ubuntu/" | grep -q "200 OK"; then
        print_warn "Global repos are slow. Switching to Iran Server..."
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        cat <<EOF > /etc/apt/sources.list
deb http://mirror.iranserver.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
        apt-get update
    fi
}

install_dependencies() {
    print_info "Checking dependencies..."
    
    # Wait for any background apt processes
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        print_warn "Waiting for apt lock..."
        sleep 3
    done

    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip"
    
    # Try install
    if ! apt-get install -y $PKGS; then
        print_warn "Apt failed. optimizing repos..."
        optimize_iran_repo
        apt-get --fix-broken install -y
        apt-get install -y $PKGS
    fi
}

detect_network() {
    print_info "Detecting network..."
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    PUBLIC_IP=$(curl -4 -s --max-time 3 ifconfig.me)
    GATEWAY_IP=$(ip r | grep default | awk '{print $3}' | head -n 1)
    
    ping -c 1 -W 1 $GATEWAY_IP >/dev/null 2>&1
    GATEWAY_MAC=$(ip neigh show $GATEWAY_IP | awk '{print $5}' | head -n 1)
    
    if [ -z "$GATEWAY_MAC" ]; then
        if command -v arp >/dev/null; then
             GATEWAY_MAC=$(arp -an $GATEWAY_IP | awk '{print $4}' | head -n 1)
        fi
    fi

    if [ -z "$IFACE" ] || [ -z "$GATEWAY_MAC" ]; then
        print_error "Network detection failed. \nDebug: IP=$PUBLIC_IP GW=$GATEWAY_IP MAC=$GATEWAY_MAC"
    fi
    print_success "IP: $PUBLIC_IP | Iface: $IFACE | GW MAC: $GATEWAY_MAC"
}

setup_firewall() {
    local target=$1; local port=$2; local mode=$3
    print_info "Configuring Firewall..."
    
    # Reset specific rules
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
        # Anti-RST specifically for target
        iptables -t mangle -A OUTPUT -p tcp -d $target --dport $port --tcp-flags RST RST -j DROP
    fi
    
    # Generic Anti-RST
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP
    
    if command -v netfilter-persistent >/dev/null; then netfilter-persistent save >/dev/null 2>&1; fi
}

install_paqet() {
    cd /root
    print_info "Downloading Paqet..."
    rm -f paqet*
    download_file "$PAQET_URL" "paqet.tar.gz"
    
    tar -xzf paqet.tar.gz
    # Fix variable naming
    if [ -f "paqet_linux_amd64" ]; then mv paqet_linux_amd64 paqet; fi
    if [ -f "paqet-linux-amd64" ]; then mv paqet-linux-amd64 paqet; fi
    chmod +x paqet
}

install_xui() {
    print_info "Installing X-UI..."
    cd /root
    rm -rf x-ui*
    download_file "$XUI_URL" "x-ui.tar.gz"
    
    tar zxf x-ui.tar.gz
    rm -rf /usr/local/x-ui
    mv x-ui /usr/local/
    chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/x-ui.sh
    cp /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    
    if [ ! -f "/etc/systemd/system/x-ui.service" ]; then
        wget -q -O /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
    fi
    
    print_info "Swapping Core to GFW-Knocker..."
    download_file "$CORE_URL" "xray.zip"
    unzip -o xray.zip -d xray_temp
    mv xray_temp/xray /usr/local/x-ui/bin/xray-linux-amd64
    chmod +x /usr/local/x-ui/bin/xray-linux-amd64
    rm -rf xray.zip xray_temp x-ui.tar.gz
    
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
}

check_tunnel() {
    local remote_ip=$1
    print_info "Verifying Tunnel Connection..."
    sleep 5
    
    # Curl through proxy
    DETECTED_IP=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:1080 http://ifconfig.me)
    
    if [ "$DETECTED_IP" == "$remote_ip" ]; then
        print_success "TUNNEL SUCCESS! Traffic is exiting via: $DETECTED_IP"
    elif [[ "$DETECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_warn "Tunnel is working, but IP is different: $DETECTED_IP (Might be Cloudflare/CDN)"
    else
        print_error "Tunnel Check Failed. Curl Output: '$DETECTED_IP'. Check firewall/keys."
    fi
}

# --- MAIN LOGIC ---

check_root
clear
echo "=========================================================="
echo "      PAQET (Alpha 14) + XRAY AUTO INSTALLER              "
echo "=========================================================="
echo "1) SETUP KHAREJ (Germany/Outside)"
echo "2) SETUP IRAN (Client)"
echo "=========================================================="
read -p "Select [1 or 2]: " ROLE

if [ "$ROLE" == "1" ]; then
    # SERVER SETUP
    install_dependencies
    detect_network
    read -p "Paqet Port [Default 8880]: " PORT; PORT=${PORT:-8880}
    KEY=$(openssl rand -hex 16)
    
    install_paqet
    setup_firewall "0.0.0.0" "$PORT" "server"
    
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
    echo ""; print_success "SETUP COMPLETE!"
    echo "SAVE THIS FOR IRAN SERVER:"
    echo "IP: $PUBLIC_IP"
    echo "PORT: $PORT"
    echo "KEY: $KEY"

elif [ "$ROLE" == "2" ]; then
    # CLIENT SETUP
    install_dependencies
    detect_network
    echo ">>> Enter Kharej Server Details:"
    read -p "IP: " REMOTE_IP
    read -p "PORT [8880]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-8880}
    read -p "KEY: " KEY
    [ -z "$REMOTE_IP" ] && print_error "IP Required"
    
    install_paqet
    setup_firewall "$REMOTE_IP" "$REMOTE_PORT" "client"
    
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
    
    install_xui
    check_tunnel "$REMOTE_IP"
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "=========================================================="
    echo "1. Panel: http://$PUBLIC_IP:2053 (admin/admin)"
    echo "2. IMPORTANT: Change 'Outbounds' in Panel Settings to:"
    echo '   "outbounds": [ { "tag": "proxy", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 1080 }] } }, { "tag": "direct", "protocol": "freedom", "settings": {} } ]'
    echo "3. Create Inbound: TCP | Reality | UUID: $UUID"
    echo "=========================================================="
fi