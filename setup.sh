#!/bin/bash

# =========================================================
#  MASTER TUNNEL SETUP: PAQET + GFW-KNOCKER + X-UI
#  Supports: Kharej VPS, Iran VPS, and Home Linux/WSL
# =========================================================

# --- CONFIGURATION ---
# Paqet
PAQET_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz"
# GFW-Knocker Source (Using SamNet-dev fork as it is stable/referenced)
GFK_RAW_URL="https://raw.githubusercontent.com/SamNet-dev/paqctl/main/gfk"
MICROSOCKS_URL="https://github.com/rofl0r/microsocks/archive/refs/heads/master.tar.gz"
# X-UI
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
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       MASTER TUNNEL INSTALLER (Paqet & GFW-Knocker)          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() { if [ "$EUID" -ne 0 ]; then print_error "Please run as root (sudo bash setup.sh)"; fi; }

# --- OPTIMIZATIONS (Inspired by paqctl) ---
optimize_network() {
    print_info "Optimizing Network (DNS & Limits)..."
    # DNS
    [ ! -f /etc/resolv.conf.bak ] && cp /etc/resolv.conf /etc/resolv.conf.bak
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2001:4860:4860::8888" > /etc/resolv.conf
    
    # File Limits
    echo "* soft nofile 65535" > /etc/security/limits.d/00-limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.d/00-limits.conf
    ulimit -n 65535
    print_success "Network Optimized."
}

fix_mirrors() {
    [ -f /etc/os-release ] && source /etc/os-release
    if [ "$ID" == "ubuntu" ]; then
        print_warn "Checking fastest Iran mirror..."
        MIRRORS=("http://mirror.iranserver.com/ubuntu/" "https://mirrors.pardisco.co/ubuntu/" "http://archive.ubuntu.com/ubuntu/")
        BEST_MIRROR=""
        BEST_TIME=1000
        for M in "${MIRRORS[@]}"; do
            TIME=$(curl -o /dev/null -s -w '%{time_total}\n' --max-time 1 "$M")
            if [ $? -eq 0 ] && (( $(echo "$TIME < $BEST_TIME" | bc -l) )); then
                BEST_TIME=$TIME; BEST_MIRROR=$M
            fi
        done
        if [ -n "$BEST_MIRROR" ]; then
            print_success "Selected: $BEST_MIRROR"
            cat <<EOF > /etc/apt/sources.list
deb ${BEST_MIRROR} ${VERSION_CODENAME} main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-updates main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-security main restricted universe multiverse
EOF
            apt-get update -qq
        fi
    fi
}

install_base_deps() {
    print_info "Installing Base Dependencies..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 1; done
    # Added python3-venv, gcc, make for GFK/Microsocks
    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq bc python3 python3-pip python3-venv gcc make"
    if ! apt-get install -y --no-install-recommends $PKGS; then
        fix_mirrors
        apt-get --fix-broken install -y
        apt-get install -y --no-install-recommends $PKGS
    fi
}

# --- COMMON NETWORK UTILS ---
detect_ip() {
    # Try multiple services to get Public IP (handles 403 blocks)
    SERVICES=("http://ipv4.icanhazip.com" "http://api.ipify.org" "http://ifconfig.me/ip")
    PUBLIC_IP=""
    for S in "${SERVICES[@]}"; do
        PUBLIC_IP=$(curl -s --max-time 3 "$S")
        [[ "$PUBLIC_IP" =~ ^[0-9]+\. ]] && break
    done
    [ -z "$PUBLIC_IP" ] && read -p ">>> Could not detect IP. Enter manually: " PUBLIC_IP
    
    # Gateway details for raw sockets
    IFACE=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')
    GW_IP=$(ip route get 1.1.1.1 | awk '{print $3}')
    GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    [ -z "$GW_MAC" ] && ping -c 1 $GW_IP >/dev/null && GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    
    print_success "IP: $PUBLIC_IP | Iface: $IFACE"
}

setup_firewall_bypass() {
    local port=$1
    # Raw socket bypass (NOTRACK)
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
    # Anti-RST
    iptables -t mangle -D OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP
    netfilter-persistent save >/dev/null 2>&1
}

# =========================================================
#  PROTOCOL 1: PAQET (The Simple, Reliable Choice)
# =========================================================
setup_paqet() {
    print_info "Setting up Paqet..."
    cd /root
    rm -f paqet.tar.gz
    wget -q -O paqet.tar.gz "$PAQET_URL"
    tar -xzf paqet.tar.gz
    [ -f "paqet_linux_amd64" ] && mv paqet_linux_amd64 paqet
    [ -f "paqet-linux-amd64" ] && mv paqet-linux-amd64 paqet
    chmod +x paqet
    
    setup_firewall_bypass "$PORT"

    # Config Generation
    if [ "$ROLE" == "server" ]; then
        cat <<EOF > /root/paqet_server.yaml
role: "server"
log: { level: "info" }
listen: { addr: ":$PORT" }
network: { interface: "$IFACE", ipv4: { addr: "$PUBLIC_IP:$PORT", router_mac: "$GW_MAC" } }
transport: { protocol: "kcp", kcp: { block: "aes", key: "$KEY" } }
EOF
        SVC_FILE="paqet-server"
        CMD="/root/paqet run -c /root/paqet_server.yaml"
    else
        cat <<EOF > /root/paqet_client.yaml
role: "client"
log: { level: "info" }
socks5: [ { listen: "127.0.0.1:1080" } ]
network: { interface: "$IFACE", ipv4: { addr: "$PUBLIC_IP:0", router_mac: "$GW_MAC" } }
server: { addr: "$REMOTE_IP:$REMOTE_PORT" }
transport: { protocol: "kcp", kcp: { block: "aes", key: "$KEY" } }
EOF
        SVC_FILE="paqet-client"
        CMD="/root/paqet run -c /root/paqet_client.yaml"
    fi

    # Service
    cat <<EOF > /etc/systemd/system/${SVC_FILE}.service
[Unit]
Description=Paqet Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$CMD
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable ${SVC_FILE}; systemctl restart ${SVC_FILE}
    print_success "Paqet Installed & Running."
}

# =========================================================
#  PROTOCOL 2: GFW-KNOCKER (The Advanced, Heavy Choice)
# =========================================================
setup_gfk() {
    print_info "Setting up GFW-Knocker..."
    
    # 1. Python Environment
    print_info "Setting up Python Venv..."
    mkdir -p /root/gfk_env
    python3 -m venv /root/gfk_env
    /root/gfk_env/bin/pip install --upgrade pip
    /root/gfk_env/bin/pip install scapy aioquic cryptography

    # 2. Download Scripts
    print_info "Downloading Scripts..."
    mkdir -p /root/gfk
    cd /root/gfk
    if [ "$ROLE" == "server" ]; then
        wget -q "$GFK_RAW_URL/server/mainserver.py"
        wget -q "$GFK_RAW_URL/server/quic_server.py"
        wget -q "$GFK_RAW_URL/server/vio_server.py"
        # Generate Certs
        openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=gfk" 2>/dev/null
    else
        wget -q "$GFK_RAW_URL/client/mainclient.py"
        wget -q "$GFK_RAW_URL/client/quic_client.py"
        wget -q "$GFK_RAW_URL/client/vio_client.py"
        # Install Microsocks (Required for Client)
        print_info "Compiling Microsocks..."
        cd /tmp
        wget -q -O ms.tar.gz "$MICROSOCKS_URL"
        tar -xzf ms.tar.gz
        cd microsocks-master
        make >/dev/null
        mv microsocks /usr/local/bin/
        cd /root/gfk
    fi

    # 3. Generate parameters.py
    # GFK needs specific ports. Let's use defaults: VIO=45000, QUIC=25000
    VIO_PORT=45000
    QUIC_PORT=25000
    
    # Generate Auth Code if empty
    [ -z "$KEY" ] && KEY=$(openssl rand -hex 8)

    setup_firewall_bypass $VIO_PORT

    cat <<EOF > /root/gfk/parameters.py
# Auto-Generated
vps_ip = "${REMOTE_IP:-$PUBLIC_IP}"
xray_server_ip_address = "127.0.0.1"
tcp_port_mapping = {14000: 443} # Local 14000 -> Remote 443 (Socks)
udp_port_mapping = {}
vio_tcp_server_port = $VIO_PORT
vio_tcp_client_port = 40000
vio_udp_server_port = 35000
vio_udp_client_port = 30000
quic_server_port = $QUIC_PORT
quic_client_port = 20000
quic_local_ip = "127.0.0.1"
quic_idle_timeout = 86400
udp_timeout = 300
quic_mtu = 1420
quic_verify_cert = False
quic_max_data = 1073741824
quic_max_stream_data = 1073741824
quic_auth_code = "${KEY}"
quic_cert_filepath = ("/root/gfk/cert.pem", "/root/gfk/key.pem")
tcp_flags = "AP"
EOF

    # 4. Service File
    if [ "$ROLE" == "server" ]; then
        # Patch python path in script
        sed -i "s|'python3'|'/root/gfk_env/bin/python'|g" mainserver.py
        START_CMD="/root/gfk_env/bin/python /root/gfk/mainserver.py"
        SVC_NAME="gfk-server"
    else
        # Client Wrapper (Runs python + microsocks)
        cat <<WRAP > /root/gfk/start_client.sh
#!/bin/bash
/usr/local/bin/microsocks -i 127.0.0.1 -p 1080 &
/root/gfk_env/bin/python /root/gfk/mainclient.py
WRAP
        chmod +x /root/gfk/start_client.sh
        START_CMD="/root/gfk/start_client.sh"
        SVC_NAME="gfk-client"
    fi

    cat <<EOF > /etc/systemd/system/${SVC_NAME}.service
[Unit]
Description=GFW-Knocker Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/root/gfk
ExecStart=${START_CMD}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable ${SVC_NAME}; systemctl restart ${SVC_NAME}
    print_success "GFW-Knocker Installed."
}

# =========================================================
#  X-UI / CORE SETUP (Server Side Only)
# =========================================================
setup_xray_logic() {
    # If using GFK Server, we NEED Xray listening on port 443 to act as the destination
    if [ "$PROTOCOL" == "2" ] && [ "$ROLE" == "server" ]; then
        print_info "Installing Xray Core for GFK target..."
        mkdir -p /usr/local/bin /usr/local/etc/xray
        wget -q -O xray.zip "$CORE_URL"
        unzip -o xray.zip -d xtmp >/dev/null
        mv xtmp/xray /usr/local/bin/
        chmod +x /usr/local/bin/xray
        rm -rf xtmp xray.zip
        
        # SOCKS config on 443 (Target of GFK mapping)
        cat <<EOF > /usr/local/etc/xray/config.json
{
  "inbounds": [{
    "port": 443,
    "listen": "127.0.0.1",
    "protocol": "socks",
    "settings": { "auth": "noauth", "udp": true }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
        # Run Xray
        nohup /usr/local/bin/xray -config /usr/local/etc/xray/config.json >/dev/null 2>&1 &
        return
    fi

    # Normal X-UI Logic for Paqet
    echo ""; read -p ">>> Install 3X-UI Panel? [y/N]: " install_xui; install_xui=${install_xui:-n}
    if [[ "$install_xui" =~ ^[Yy]$ ]]; then
        cd /root
        wget -q -O x-ui.tar.gz "$XUI_URL"
        tar zxf x-ui.tar.gz
        rm -rf /usr/local/x-ui; mv x-ui /usr/local/
        chmod +x /usr/local/x-ui/x-ui
        /usr/local/x-ui/x-ui install >/dev/null
        print_success "X-UI Installed."
    fi
}

# =========================================================
#  MAIN EXECUTION FLOW
# =========================================================
check_root
print_banner

# 1. Choose Environment
echo "Select Environment:"
echo " 1) Kharej Server (VPS Outside)"
echo " 2) Iran Server   (VPS Bridge)"
echo " 3) Client Device (Home Linux/WSL/Laptop)"
read -p "Select [1-3]: " ENV_CHOICE

# 2. Choose Protocol
echo ""; echo "Select Tunnel Protocol:"
echo " 1) Paqet (Standard, Reliable)"
echo " 2) GFW-Knocker (Advanced, Heavy Obfuscation)"
read -p "Select [1-2]: " PROTOCOL

# 3. Setup Logic
if [ "$ENV_CHOICE" == "1" ]; then ROLE="server"; fi
if [ "$ENV_CHOICE" == "2" ]; then ROLE="client"; fi # Iran acts as client to Kharej
if [ "$ENV_CHOICE" == "3" ]; then ROLE="client"; fi

# Pre-Install
optimize_network
install_base_deps
detect_ip

# Gather Credentials
if [ "$ROLE" == "server" ]; then
    read -p "Tunnel Port [8880]: " PORT; PORT=${PORT:-8880}
    KEY=$(openssl rand -hex 16)
else
    read -p "Kharej Server IP: " REMOTE_IP
    read -p "Tunnel Port [8880]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-8880}
    read -p "Secret/Auth Key: " KEY
fi

# Execute
if [ "$PROTOCOL" == "1" ]; then
    setup_paqet
elif [ "$PROTOCOL" == "2" ]; then
    setup_gfk
fi

# Post-Install & X-UI
if [ "$ROLE" == "server" ]; then
    setup_xray_logic
    echo ""; echo "======================================"
    print_success "INSTALLATION COMPLETE"
    echo "Save these details for your client:"
    echo "Server IP: $PUBLIC_IP"
    echo "Port:      $PORT"
    echo "Key:       $KEY"
    echo "======================================"
else
    echo ""; echo "======================================"
    print_success "CLIENT CONNECTED"
    echo "SOCKS5 Proxy is ready at: 127.0.0.1:1080"
    if [ "$PROTOCOL" == "2" ]; then
        echo "(GFW-Knocker mode uses internal Microsocks)"
    fi
    echo "======================================"
fi