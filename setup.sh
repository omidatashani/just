#!/bin/bash

# =========================================================
#  CORRECTED SETUP: PAQET (Hanselime) + X-UI (GFW-Knocker)
# =========================================================

# --- GLOBAL CONFIG ---
# CORRECTED URL: Using 'hanselime' repo instead of 'enfein'
PAQET_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz"
XUI_URL="https://biaupload.com/do.php?filename=org-c52c22f2ee231.gz"
GFW_KNOCKER_URL="https://github.com/GFW-knocker/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"

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

wait_for_apt() {
    # Fix for 'Could not get lock' error
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 ; do
        print_warn "Waiting for apt lock to release..."
        sleep 3
    done
}

install_dependencies() {
    print_info "Installing dependencies..."
    wait_for_apt
    
    # Fix for missing iptables-persistent on some minimal Ubuntu images
    if ! apt-cache policy | grep -q "universe"; then
        apt-get install -y software-properties-common
        add-apt-repository universe -y
        apt-get update -qq
    fi

    # Added 'unzip' and 'net-tools' to fix previous errors
    DEPS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip"
    
    apt-get update -qq
    apt-get install -y $DEPS
    
    if [ $? -ne 0 ]; then
        print_warn "Standard install failed. Attempting fix..."
        apt-get --fix-broken install -y
        apt-get install -y $DEPS
    fi
}

detect_network() {
    print_info "Detecting network details..."
    
    # Robust Interface Detection
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    
    # Robust IP Detection
    PUBLIC_IP=$(curl -4 -s --max-time 5 icanhazip.com)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me)
    
    # Robust Gateway Detection
    GATEWAY_IP=$(ip r | grep default | awk '{print $3}' | head -n 1)
    
    # Robust MAC Detection (Ping first to ensure ARP table is populated)
    ping -c 1 -W 1 $GATEWAY_IP >/dev/null 2>&1
    if command -v arp >/dev/null 2>&1; then
        GATEWAY_MAC=$(arp -an $GATEWAY_IP | awk '{print $4}' | head -n 1)
    fi
    # Fallback to ip neigh if arp command failed
    if [ -z "$GATEWAY_MAC" ]; then
        GATEWAY_MAC=$(ip neigh show $GATEWAY_IP | awk '{print $5}' | head -n 1)
    fi

    if [ -z "$IFACE" ] || [ -z "$GATEWAY_MAC" ]; then
        print_error "Network detection failed. \nDEBUG: IP=$PUBLIC_IP, GW=$GATEWAY_IP. Check internet connection."
    fi
    print_success "Detected: IP=$PUBLIC_IP | Iface=$IFACE | GW MAC=$GATEWAY_MAC"
}

setup_firewall_bypass() {
    local target_ip=$1
    local port=$2
    local mode=$3

    print_info "Applying Firewall Bypass Rules for Port $port..."
    
    # Clean old rules
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    
    if [ "$mode" == "server" ]; then
        iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
        iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
        iptables -t filter -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -t filter -A OUTPUT -p tcp --sport $port -j ACCEPT
    else
        iptables -t raw -A OUTPUT -p tcp -d $target_ip --dport $port -j NOTRACK
        iptables -t raw -A PREROUTING -p tcp -s $target_ip --sport $port -j NOTRACK
        iptables -t filter -A OUTPUT -p tcp -d $target_ip --dport $port -j ACCEPT
        iptables -t filter -A INPUT -p tcp -s $target_ip --sport $port -j ACCEPT
    fi
    
    # Prevent RST packets
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP 2>/dev/null
    if [ "$mode" == "client" ]; then
         iptables -t mangle -A OUTPUT -p tcp -d $target_ip --dport $port --tcp-flags RST RST -j DROP 2>/dev/null
    fi

    # Save if possible
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi
}

install_paqet() {
    cd /root
    print_info "Downloading Paqet (Hanselime Alpha 14)..."
    rm -f paqet.tar.gz paqet
    
    wget -q -O paqet.tar.gz "$PAQET_URL"
    
    if [ ! -s paqet.tar.gz ]; then
        print_error "Download failed. The URL might be blocked or changed."
    fi

    tar -xzf paqet.tar.gz
    
    # Fix filename variations
    if [ -f "paqet_linux_amd64" ]; then mv paqet_linux_amd64 paqet; fi
    if [ -f "paqet-linux-amd64" ]; then mv paqet-linux-amd64 paqet; fi

    chmod +x paqet
    print_success "Paqet Installed."
}

install_xui_gfw_knocker() {
    print_info "Installing 3X-UI with GFW-Knocker Core..."
    
    cd /root/
    wget -q -O x-ui.tar.gz "$XUI_URL"
    tar zxf x-ui.tar.gz > /dev/null
    rm -rf /usr/local/x-ui
    mv x-ui /usr/local/
    
    chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/x-ui.sh
    cp /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    
    # Install Service
    if [ -f "/usr/local/x-ui/x-ui.service" ]; then
        cp /usr/local/x-ui/x-ui.service /etc/systemd/system/
    else
        curl -fLo /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
    fi

    # --- SWAP CORE TO GFW-KNOCKER ---
    print_info "Swapping to GFW-Knocker Xray Core..."
    wget -q -O xray.zip "$GFW_KNOCKER_URL"
    unzip -o xray.zip -d xray_temp > /dev/null
    mv xray_temp/xray /usr/local/x-ui/bin/xray-linux-amd64
    chmod +x /usr/local/x-ui/bin/xray-linux-amd64
    rm -rf xray.zip xray_temp
    # --------------------------------

    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
    print_success "X-UI Ready."
}

check_tunnel() {
    print_info "Testing Tunnel..."
    sleep 5
    # Check if we can reach Google via the local SOCKS proxy
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --socks5-hostname 127.0.0.1:1080 https://www.google.com)
    
    if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "301" ]; then
        print_success "TUNNEL IS WORKING! (Google reachable)"
    else
        print_warn "Tunnel Test Failed (HTTP Code: $HTTP_CODE). Check your IP and Key."
    fi
}

# --- MAIN LOGIC ---

check_root
clear
echo "=========================================================="
echo "      PAQET (Hanselime) + XRAY AUTO INSTALLER            "
echo "=========================================================="
echo "1) SETUP KHAREJ SERVER (Germany/Outside)"
echo "2) SETUP IRAN SERVER (Client)"
echo "=========================================================="
read -p "Select [1 or 2]: " ROLE

if [ "$ROLE" == "1" ]; then
    install_dependencies
    detect_network
    
    echo ""
    read -p "Enter Paqet Port [Default 8880]: " PORT
    PORT=${PORT:-8880}
    KEY=$(openssl rand -hex 16)
    
    install_paqet
    setup_firewall_bypass "0.0.0.0" "$PORT" "server"
    
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

    systemctl daemon-reload
    systemctl enable paqet
    systemctl restart paqet
    
    echo ""
    print_success "SETUP COMPLETE!"
    echo "----------------------------------------------------------"
    echo "USE THESE ON IRAN SERVER:"
    echo -e "IP:   ${GREEN}$PUBLIC_IP${NC}"
    echo -e "PORT: ${GREEN}$PORT${NC}"
    echo -e "KEY:  ${GREEN}$KEY${NC}"
    echo "----------------------------------------------------------"

elif [ "$ROLE" == "2" ]; then
    install_dependencies
    detect_network
    
    echo ""
    echo ">>> Enter details from Kharej Server:"
    read -p "IP: " REMOTE_IP
    read -p "PORT [8880]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-8880}
    read -p "KEY: " KEY
    
    [ -z "$REMOTE_IP" ] && print_error "IP Required"
    [ -z "$KEY" ] && print_error "Key Required"
    
    install_paqet
    setup_firewall_bypass "$REMOTE_IP" "$REMOTE_PORT" "client"
    
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

    systemctl daemon-reload
    systemctl enable paqet
    systemctl restart paqet
    
    print_info "Paqet Started. Installing X-UI..."
    install_xui_gfw_knocker
    
    check_tunnel
    
    # Configure Outbound
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    echo "=========================================================="
    echo -e "1. Open X-UI: ${GREEN}http://$PUBLIC_IP:2053${NC}"
    echo -e "2. Login:     ${GREEN}admin / admin${NC}"
    echo "3. Go to Settings -> Xray Configuration Template"
    echo "4. REPLACE 'outbounds' with:"
    echo -e "${BLUE}"
    cat <<EOF
"outbounds": [
  { "tag": "proxy", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 1080 }] } },
  { "tag": "direct", "protocol": "freedom", "settings": {} }
]
EOF
    echo -e "${NC}"
    echo "5. Create Inbound: Port 443 | TCP | Reality | UUID: $VLESS_UUID"
    echo "=========================================================="

else
    print_error "Invalid selection."
fi