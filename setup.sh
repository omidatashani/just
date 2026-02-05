#!/bin/bash

# =========================================================
#  AUTO SETUP: PAQET TUNNEL + Xray
# =========================================================

# --- GLOBAL CONFIG ---
PAQET_URL="https://github.com/enfein/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz"
XUI_URL="https://biaupload.com/do.php?filename=org-c52c22f2ee231.gz"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper Functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (sudo bash setup_tunnel.sh)"
    fi
}

detect_network() {
    print_info "Detecting network details..."
    
    # 1. Detect Interface (find default route interface)
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    
    # 2. Detect Public IP (Try multiple sources for Iran reliability)
    PUBLIC_IP=$(curl -4 -s --max-time 5 icanhazip.com)
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me)
    fi
    
    # 3. Detect Gateway
    GATEWAY_IP=$(ip r | grep default | awk '{print $3}' | head -n 1)
    
    # 4. Detect Gateway MAC (Ping first to ensure ARP entry exists)
    ping -c 1 -W 1 $GATEWAY_IP >/dev/null 2>&1
    GATEWAY_MAC=$(arp -an $GATEWAY_IP | awk '{print $4}' | head -n 1)

    if [ -z "$IFACE" ] || [ -z "$GATEWAY_MAC" ]; then
        print_error "Could not detect Interface or Gateway MAC. Please check internet connection."
    fi
    print_success "Detected: IP=$PUBLIC_IP | Iface=$IFACE | GW MAC=$GATEWAY_MAC"
}

install_dependencies() {
    print_info "Installing dependencies..."
    # Suppress errors if apt fails (common in Iran), try to continue
    apt-get update -qq || print_warn "Apt update timed out or failed. Attempting to continue..."
    
    DEPS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl"
    apt-get install -y $DEPS
    
    if [ $? -ne 0 ]; then
        print_warn "Standard install failed. Trying to fix broken packages..."
        apt-get --fix-broken install -y
        apt-get install -y $DEPS
    fi
}

setup_firewall_bypass() {
    local target_ip=$1
    local port=$2
    local mode=$3 # "server" or "client"

    print_info "Applying Firewall Bypass Rules for Port $port..."
    
    # Clean old rules to avoid duplicates
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    
    if [ "$mode" == "server" ]; then
        # SERVER RULES
        iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
        iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
        iptables -t filter -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -t filter -A OUTPUT -p tcp --sport $port -j ACCEPT
    else
        # CLIENT RULES (Iran)
        # Clean specific target rules first
        iptables -t raw -D OUTPUT -p tcp -d $target_ip --dport $port -j NOTRACK 2>/dev/null
        iptables -t raw -D PREROUTING -p tcp -s $target_ip --sport $port -j NOTRACK 2>/dev/null
        
        # Apply new rules
        iptables -t raw -A OUTPUT -p tcp -d $target_ip --dport $port -j NOTRACK
        iptables -t raw -A PREROUTING -p tcp -s $target_ip --sport $port -j NOTRACK
        iptables -t filter -A OUTPUT -p tcp -d $target_ip --dport $port -j ACCEPT
        iptables -t filter -A INPUT -p tcp -s $target_ip --sport $port -j ACCEPT
    fi
    
    # Common Anti-RST Rule
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP 2>/dev/null
    if [ "$mode" == "client" ]; then
         iptables -t mangle -A OUTPUT -p tcp -d $target_ip --dport $port --tcp-flags RST RST -j DROP 2>/dev/null
    fi

    netfilter-persistent save >/dev/null 2>&1
}

install_paqet() {
    cd /root
    if [ ! -f "paqet" ]; then
        print_info "Downloading Paqet..."
        wget -q -O paqet.tar.gz "$PAQET_URL"
        tar -xzf paqet.tar.gz
        mv paqet_linux_amd64 paqet
        chmod +x paqet
        rm paqet.tar.gz
    else
        print_success "Paqet binary already exists."
    fi
}

install_xui() {
    print_info "Installing 3X-UI Panel..."
    
    # Detect Architecture
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64 | x64 | amd64) XUI_ARCH="amd64" ;;
        i*86 | x86) XUI_ARCH="386" ;;
        armv8* | armv8 | arm64 | aarch64) XUI_ARCH="arm64" ;;
        armv7* | armv7) XUI_ARCH="armv7" ;;
        armv6* | armv6) XUI_ARCH="armv6" ;;
        armv5* | armv5) XUI_ARCH="armv5" ;;
        s390x) XUI_ARCH="s390x" ;;
        *) XUI_ARCH="amd64" ;;
    esac

    # Detect OS Release
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        release=$ID
    else
        release="debian"
    fi

    cd /root/
    print_info "Downloading X-UI from custom link..."
    # Download as tar.gz
    wget -O x-ui-linux-${XUI_ARCH}.tar.gz "$XUI_URL"

    rm -rf x-ui/ /usr/local/x-ui/ /usr/bin/x-ui
    tar zxvf x-ui-linux-${XUI_ARCH}.tar.gz > /dev/null
    
    chmod +x x-ui/x-ui x-ui/bin/xray-linux-* x-ui/x-ui.sh
    cp x-ui/x-ui.sh /usr/bin/x-ui

    # Service File Logic
    if [ -f "x-ui/x-ui.service" ]; then
        cp -f x-ui/x-ui.service /etc/systemd/system/
    elif [[ "$release" == "ubuntu" || "$release" == "debian" || "$release" == "armbian" ]]; then
        curl -fLo /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
    else
        curl -fLo /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.rhel
    fi

    mv x-ui/ /usr/local/
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
    
    print_success "3X-UI Installed Successfully."
}

# --- MAIN SCRIPT EXECUTION ---

check_root
clear
echo "=========================================================="
echo "         HOPE: PAQET TUNNEL + Xray AUTO INSTALLER              "
echo "=========================================================="
echo "1) SETUP KHAREJ SERVER (The Exit)"
echo "2) SETUP IRAN SERVER (The Client)"
echo "=========================================================="
read -p "Select [1 or 2]: " ROLE

if [ "$ROLE" == "1" ]; then
    # === KHAREJ SERVER FLOW ===
    install_dependencies
    detect_network
    
    echo ""
    read -p "Enter Paqet Port [Press Enter for 8880]: " PORT
    PORT=${PORT:-8880}
    
    # Generate Secret Key
    KEY=$(openssl rand -hex 16)
    
    install_paqet
    setup_firewall_bypass "0.0.0.0" "$PORT" "server"
    
    # Create Server Config
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

    # Create Service
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
    echo "=========================================================="
    print_success "KHAREJ SERVER SETUP COMPLETE!"
    echo "----------------------------------------------------------"
    echo "COPY THESE VALUES FOR YOUR IRAN SERVER INPUT:"
    echo "----------------------------------------------------------"
    echo -e "Server IP:   ${GREEN}$PUBLIC_IP${NC}"
    echo -e "Tunnel Port: ${GREEN}$PORT${NC}"
    echo -e "Secret Key:  ${GREEN}$KEY${NC}"
    echo "=========================================================="

elif [ "$ROLE" == "2" ]; then
    # === IRAN CLIENT FLOW ===
    install_dependencies
    detect_network
    
    echo ""
    echo ">>> Please enter details from the KHAREJ Server:"
    read -p "KHAREJ IP: " REMOTE_IP
    read -p "Tunnel Port [Default 8880]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-8880}
    read -p "Secret Key: " KEY
    
    if [ -z "$REMOTE_IP" ] || [ -z "$KEY" ]; then
        print_error "IP and Key are required!"
    fi
    
    install_paqet
    setup_firewall_bypass "$REMOTE_IP" "$REMOTE_PORT" "client"
    
    # Create Client Config
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

    # Create Service
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
    
    print_success "Paqet Tunnel Connected!"
    
    # Install X-UI
    install_xui
    
    echo "=========================================================="
    echo "              FINAL CONFIGURATION REQUIRED                "
    echo "=========================================================="
    echo -e "1. Open X-UI Panel: ${GREEN}http://$PUBLIC_IP:2053${NC}"
    echo -e "2. Default Login:   ${GREEN}admin / admin${NC}"
    echo "3. Go to 'Settings' -> 'Xray Configuration Template'"
    echo "4. DELETE the 'outbounds' section and PASTE this:"
    echo "   (This routes user traffic into the tunnel)"
    echo -e "${BLUE}"
    cat <<EOF
"outbounds": [
  {
    "tag": "proxy",
    "protocol": "socks",
    "settings": {
      "servers": [
        {
          "address": "127.0.0.1",
          "port": 1080
        }
      ]
    }
  },
  {
    "tag": "direct",
    "protocol": "freedom",
    "settings": {}
  }
]
EOF
    echo -e "${NC}"
    echo "5. Click SAVE and RESTART XRAY."
    echo "6. Go to 'Inbounds' and create a VMess/VLESS TCP user."
    echo "=========================================================="

else
    print_error "Invalid Choice. Run script again."
fi