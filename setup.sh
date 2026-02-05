#!/bin/bash

# =========================================================
#  SMART SETUP: PAQET + XRAY (Optimized for IRAN)
# =========================================================

# --- GLOBAL CONFIG ---
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

# --- IRAN REPO OPTIMIZER ---
optimize_iran_repo() {
    print_info "Starting Iran Repository Optimization..."
    
    # Only for Ubuntu
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [ "$ID" != "ubuntu" ]; then
            print_warn "OS is not Ubuntu. Skipping repo optimization."
            return
        fi
        UBUNTU_CODENAME=$VERSION_CODENAME
    else
        print_warn "Could not detect OS. Skipping."
        return
    fi

    MIRRORS=(
      "http://mirror.aminidc.com/ubuntu/"
      "https://mirrors.pardisco.co/ubuntu/"
      "http://mirror.faraso.org/ubuntu/"
      "https://ubuntu-mirror.kimiahost.com/"
      "https://mirror.iranserver.com/ubuntu/"
      "http://repo.iut.ac.ir/repo/Ubuntu/"
      "http://mirrors.sharif.ir/ubuntu/"
      "http://archive.ubuntu.com/ubuntu/"
    )

    print_info "Testing mirrors for Ubuntu $UBUNTU_CODENAME..."
    WORKING_MIRROR=""

    # Backup original sources
    if [ ! -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        print_info "Backup of sources.list created."
    fi

    for MIRROR in "${MIRRORS[@]}"; do
        echo -n "   Testing $MIRROR ... "
        # Use timeout to avoid getting stuck
        if curl -s --head --max-time 2 "$MIRROR" | grep -q "200 OK"; then
            echo -e "${GREEN}OK${NC}"
            WORKING_MIRROR=$MIRROR
            break
        else
            echo -e "${RED}FAIL${NC}"
        fi
    done

    if [ -z "$WORKING_MIRROR" ]; then
        print_warn "No working Iran mirror found. Reverting to default."
        return
    fi

    print_success "Switching to: $WORKING_MIRROR"
    
    cat <<EOF > /etc/apt/sources.list
deb ${WORKING_MIRROR} ${UBUNTU_CODENAME} main restricted universe multiverse
deb ${WORKING_MIRROR} ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb ${WORKING_MIRROR} ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb ${WORKING_MIRROR} ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

    print_info "Updating apt cache..."
    apt-get update -qq
}

install_dependencies() {
    print_info "Checking dependencies..."
    
    # List of required packages
    REQUIRED_PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip"
    MISSING_PKGS=""

    # Check which packages are actually missing
    for pkg in $REQUIRED_PKGS; do
        if ! dpkg -s $pkg >/dev/null 2>&1; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
        fi
    done

    if [ -z "$MISSING_PKGS" ]; then
        print_success "All dependencies are already installed. Skipping apt."
        return
    fi

    print_warn "Missing packages: $MISSING_PKGS"
    print_info "Installing missing packages..."
    
    # Try install. If it fails, run optimization and try again.
    # We create a subshell or flag to check success
    if ! apt-get update -qq; then
        print_warn "Apt update failed. Trying to switch to Iran Mirrors..."
        optimize_iran_repo
    fi
    
    # Attempt install
    apt-get install -y $MISSING_PKGS
    
    if [ $? -ne 0 ]; then
        print_warn "Install failed. Trying to fix Repos + Broken packages..."
        optimize_iran_repo
        apt-get --fix-broken install -y
        apt-get install -y $MISSING_PKGS
    fi
}

detect_network() {
    print_info "Detecting network details..."
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    PUBLIC_IP=$(curl -4 -s --max-time 3 icanhazip.com)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -4 -s --max-time 3 ifconfig.me)
    GATEWAY_IP=$(ip r | grep default | awk '{print $3}' | head -n 1)
    
    ping -c 1 -W 1 $GATEWAY_IP >/dev/null 2>&1
    if command -v arp >/dev/null 2>&1; then
        GATEWAY_MAC=$(arp -an $GATEWAY_IP | awk '{print $4}' | head -n 1)
    fi
    if [ -z "$GATEWAY_MAC" ]; then
        GATEWAY_MAC=$(ip neigh show $GATEWAY_IP | awk '{print $5}' | head -n 1)
    fi

    if [ -z "$IFACE" ] || [ -z "$GATEWAY_MAC" ]; then
        print_error "Network detection failed. Check internet."
    fi
    print_success "Detected: IP=$PUBLIC_IP | Iface=$IFACE | GW MAC=$GATEWAY_MAC"
}

setup_firewall_bypass() {
    local target_ip=$1; local port=$2; local mode=$3
    print_info "Configuring Firewall for Port $port..."
    
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
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP 2>/dev/null
    if [ "$mode" == "client" ]; then
         iptables -t mangle -A OUTPUT -p tcp -d $target_ip --dport $port --tcp-flags RST RST -j DROP 2>/dev/null
    fi
    if command -v netfilter-persistent >/dev/null; then netfilter-persistent save >/dev/null 2>&1; fi
}

install_paqet() {
    cd /root
    print_info "Downloading Paqet (Hanselime Alpha 14)..."
    rm -f paqet.tar.gz paqet
    wget -q -T 15 -O paqet.tar.gz "$PAQET_URL"
    
    if [ ! -s paqet.tar.gz ]; then
        print_error "Download failed. Check URL or Internet."
    fi
    tar -xzf paqet.tar.gz
    if [ -f "paqet_linux_amd64" ]; then mv paqet_linux_amd64 paqet; fi
    if [ -f "paqet-linux-amd64" ]; then mv paqet-linux-amd64 paqet; fi
    chmod +x paqet
    print_success "Paqet Installed."
}

install_xui_gfw_knocker() {
    print_info "Installing X-UI + GFW-Knocker..."
    cd /root/
    wget -q -T 15 -O x-ui.tar.gz "$XUI_URL"
    tar zxf x-ui.tar.gz > /dev/null
    rm -rf /usr/local/x-ui
    mv x-ui /usr/local/
    chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/x-ui.sh
    cp /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    if [ ! -f "/etc/systemd/system/x-ui.service" ]; then
        curl -fLo /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
    fi

    # Swap Core
    print_info "Swapping Core..."
    wget -q -T 15 -O xray.zip "$GFW_KNOCKER_URL"
    unzip -o xray.zip -d xray_temp > /dev/null
    mv xray_temp/xray /usr/local/x-ui/bin/xray-linux-amd64
    chmod +x /usr/local/x-ui/bin/xray-linux-amd64
    rm -rf xray.zip xray_temp

    systemctl daemon-reload; systemctl enable x-ui; systemctl restart x-ui
    print_success "X-UI Ready."
}

check_tunnel() {
    print_info "Testing Tunnel..."
    sleep 5
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --socks5-hostname 127.0.0.1:1080 https://www.google.com)
    if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "301" ]; then
        print_success "TUNNEL IS WORKING! (Google reachable)"
    else
        print_warn "Tunnel Test Failed (Code: $HTTP_CODE). Check IP/Key."
    fi
}

# --- MAIN ---
check_root
clear
echo "=========================================================="
echo "    SMART SETUP: PAQET + XRAY (IRAN OPTIMIZED)           "
echo "=========================================================="
echo "1) SETUP KHAREJ (Germany/Outside)"
echo "2) SETUP IRAN (Client)"
echo "=========================================================="
read -p "Select [1 or 2]: " ROLE

if [ "$ROLE" == "1" ]; then
    install_dependencies
    detect_network
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
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
    echo ""; print_success "DONE!"; echo "IP: $PUBLIC_IP | PORT: $PORT | KEY: $KEY"

elif [ "$ROLE" == "2" ]; then
    install_dependencies
    detect_network
    echo ""; echo ">>> Enter Kharej Details:"
    read -p "IP: " REMOTE_IP
    read -p "PORT [8880]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-8880}
    read -p "KEY: " KEY
    [ -z "$REMOTE_IP" ] && print_error "IP Required"
    
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
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
    install_xui_gfw_knocker
    check_tunnel
    
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "=========================================================="
    echo "1. Panel: http://$PUBLIC_IP:2053 (admin/admin)"
    echo "2. REPLACE Outbounds with:"
    echo '   "outbounds": [ { "tag": "proxy", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 1080 }] } }, { "tag": "direct", "protocol": "freedom", "settings": {} } ]'
    echo "3. Create Inbound: Port 443 | TCP | Reality | UUID: $VLESS_UUID"
    echo "=========================================================="
else
    print_error "Invalid selection."
fi