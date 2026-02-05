#!/bin/bash

# =========================================================
#  ULTIMATE SETUP: PAQET + X-UI + ROBUST NETWORKING
# =========================================================

# --- DEFAULTS ---
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
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (sudo bash setup.sh)"
    fi
}

# --- SMART FILE ACQUISITION (Download OR Local) ---
get_file() {
    local name=$1      # Display Name
    local url=$2       # Default URL
    local outfile=$3   # Output filename
    
    echo ""
    echo -e "${YELLOW}>>> How do you want to get $name?${NC}"
    echo "   1) Download from Internet (Default)"
    echo "   2) Use a Local File (I uploaded it to /root/...)"
    read -p "   Select [1-2] (Press Enter for 1): " choice
    choice=${choice:-1}
    
    if [ "$choice" == "2" ]; then
        # Local File Mode
        while true; do
            read -p "   Enter full path to file (e.g. /root/file.tar.gz): " localpath
            if [ -f "$localpath" ]; then
                cp "$localpath" "$outfile"
                print_success "Loaded $name from local file."
                return 0
            else
                print_warn "File not found at $localpath. Try again."
            fi
        done
    else
        # Download Mode
        print_info "Downloading $name..."
        rm -f "$outfile"
        wget --show-progress -q -T 60 -c -O "$outfile" "$url"
        
        # Verify
        if [ -s "$outfile" ] && [ $(stat -c%s "$outfile") -gt 1024 ]; then
            print_success "Download complete."
            return 0
        else
            print_warn "Download Failed or Blocked!"
            read -p "   Do you have a local file instead? [y/N]: " retry_local
            if [[ "$retry_local" =~ ^[Yy]$ ]]; then
                # Retry with local
                get_file "$name" "$url" "$outfile"
                return $?
            else
                print_error "Could not get $name. Exiting."
            fi
        fi
    fi
}

install_dependencies() {
    print_info "Checking dependencies..."
    # Fix Apt Lock
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 2; done

    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip"
    
    # Try install
    if ! apt-get install -y $PKGS; then
        print_warn "Apt failed. Switching to Iran mirrors..."
        if grep -q "ubuntu" /etc/os-release; then
             sed -i 's|http://archive.ubuntu.com|http://mirror.iranserver.com|g' /etc/apt/sources.list
             apt-get update
        fi
        apt-get --fix-broken install -y
        apt-get install -y $PKGS
    fi
}

detect_network() {
    print_info "Detecting network..."
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    
    # --- ROBUST IP DETECTION ---
    PUBLIC_IP=""
    SERVICES=("http://ipv4.icanhazip.com" "http://api.ipify.org" "http://ifconfig.me/ip" "http://ipecho.net/plain")
    
    for SERVICE in "${SERVICES[@]}"; do
        TEMP_IP=$(curl -s --max-time 3 "$SERVICE")
        # Validate IP format
        if [[ "$TEMP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            PUBLIC_IP="$TEMP_IP"
            break
        fi
    done

    # Manual Fallback
    if [ -z "$PUBLIC_IP" ]; then
        print_warn "Could not auto-detect Public IP (403 Forbidden)."
        read -p ">>> Please enter this server's Public IP manually: " PUBLIC_IP
    fi
    # ---------------------------

    GATEWAY_IP=$(ip r | grep default | awk '{print $3}' | head -n 1)
    
    # Ping to populate ARP
    ping -c 1 -W 1 $GATEWAY_IP >/dev/null 2>&1
    
    # Try ip neigh first, then arp
    GATEWAY_MAC=$(ip neigh show $GATEWAY_IP | awk '{print $5}' | head -n 1)
    if [ -z "$GATEWAY_MAC" ] && command -v arp >/dev/null; then
         GATEWAY_MAC=$(arp -an $GATEWAY_IP | awk '{print $4}' | head -n 1)
    fi

    if [ -z "$IFACE" ]; then print_error "Network detection failed."; fi
    
    # Final Validation
    if [[ ! "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
         print_error "Invalid IP: $PUBLIC_IP"
    fi

    print_success "IP: $PUBLIC_IP | Iface: $IFACE | GW: $GATEWAY_MAC"
}

setup_firewall() {
    local target=$1; local port=$2; local mode=$3
    print_info "Configuring Firewall..."
    
    # Clean old
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
    cd /root
    rm -f paqet*
    get_file "Paqet Binary" "$PAQET_URL" "paqet.tar.gz"
    
    tar -xzf paqet.tar.gz
    # Fix filename variations
    if [ -f "paqet_linux_amd64" ]; then mv paqet_linux_amd64 paqet; fi
    if [ -f "paqet-linux-amd64" ]; then mv paqet-linux-amd64 paqet; fi
    chmod +x paqet
}

install_xui_custom() {
    echo ""
    read -p ">>> Install 3X-UI Panel? [Y/n]: " install_xui
    install_xui=${install_xui:-y}
    
    if [[ ! "$install_xui" =~ ^[Yy]$ ]]; then return; fi

    cd /root
    rm -rf x-ui*
    get_file "X-UI Panel" "$XUI_URL" "x-ui.tar.gz"
    
    tar zxf x-ui.tar.gz
    rm -rf /usr/local/x-ui
    mv x-ui /usr/local/
    chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/x-ui.sh
    cp /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    
    if [ ! -f "/etc/systemd/system/x-ui.service" ]; then
        wget -q -O /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
    fi

    # Swap Core Option
    read -p ">>> Swap Xray Core to GFW-Knocker? [Y/n]: " swap_core
    swap_core=${swap_core:-y}
    
    if [[ "$swap_core" =~ ^[Yy]$ ]]; then
        get_file "GFW-Knocker Core" "$CORE_URL" "xray.zip"
        unzip -o xray.zip -d xray_temp
        mv xray_temp/xray /usr/local/x-ui/bin/xray-linux-amd64
        chmod +x /usr/local/x-ui/bin/xray-linux-amd64
        rm -rf xray.zip xray_temp
        print_success "Core Swapped."
    fi

    systemctl daemon-reload; systemctl enable x-ui; systemctl restart x-ui
    print_success "X-UI Installed."
}

check_tunnel() {
    local remote_ip=$1
    print_info "Verifying Tunnel..."
    sleep 3
    # Try to fetch IP via Socks Proxy
    DETECTED_IP=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:1080 http://api.ipify.org)
    
    if [ "$DETECTED_IP" == "$remote_ip" ]; then
        print_success "TUNNEL SUCCESS! Exit IP: $DETECTED_IP"
    elif [[ "$DETECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_warn "Tunnel OK but IP differs: $DETECTED_IP (Cloudflare?)"
    else
        print_warn "Tunnel Check Failed. Curl Output: '$DETECTED_IP'"
    fi
}

# --- MAIN ---
check_root
clear
echo "=========================================================="
echo "    ULTIMATE PAQET SETUP (Robust & Fixed)                "
echo "=========================================================="
echo "1) KHAREJ (Germany)"
echo "2) IRAN (Client)"
echo "=========================================================="
read -p "Select [1-2]: " ROLE

if [ "$ROLE" == "1" ]; then
    install_dependencies
    detect_network
    read -p "Paqet Port [8880]: " PORT; PORT=${PORT:-8880}
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
    echo ""; print_success "DONE! SAVE THESE:"
    echo "IP: $PUBLIC_IP | PORT: $PORT | KEY: $KEY"

elif [ "$ROLE" == "2" ]; then
    install_dependencies
    detect_network
    read -p "Kharej IP: " REMOTE_IP
    read -p "Port [8880]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-8880}
    read -p "Key: " KEY
    
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
    
    check_tunnel "$REMOTE_IP"
    install_xui_custom
    
    echo "=========================================================="
    echo "SETUP COMPLETE."
    echo "1. Panel: http://$PUBLIC_IP:2053 (admin/admin)"
    echo "2. Configure Outbounds: SOCKS -> 127.0.0.1:1080"
    echo "=========================================================="
fi