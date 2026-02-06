#!/bin/bash

# =========================================================
#  MASTER TUNNEL PRO: Paqet + GFW-Knocker (Fixed Downloads)
# =========================================================

# --- CONFIGURATION ---
PAQET_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz"
GFK_RAW_URL="https://raw.githubusercontent.com/SamNet-dev/paqctl/main/gfk"
MICROSOCKS_URL="https://github.com/rofl0r/microsocks/archive/refs/heads/master.tar.gz"
XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/v2.4.4/x-ui-linux-amd64.tar.gz"
CORE_URL="https://github.com/GFW-knocker/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"

# Default Ports
PAQET_PORT=8880
GFK_VIO_PORT=45000
GFK_QUIC_PORT=25000

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

check_root() { if [ "$EUID" -ne 0 ]; then print_error "Please run as root"; fi; }

# --- SMART FILE DOWNLOADER (CURL FIXED) ---
get_file() {
    local name=$1; local url=$2; local dest=$3
    echo ""
    echo -e "${YELLOW}>>> Source for $name?${NC}"
    echo "   1) Download from Internet (Default)"
    echo "   2) Use Local File (I uploaded it)"
    read -p "   Select [1-2] (Enter=1): " choice
    choice=${choice:-1}

    if [ "$choice" == "2" ]; then
        while true; do
            read -p "   Enter full path to file: " localpath
            if [ -f "$localpath" ]; then
                cp "$localpath" "$dest"
                print_success "Loaded $name from local file."
                return 0
            else
                print_warn "File not found at '$localpath'. Try again."
            fi
        done
    else
        print_info "Downloading $name..."
        rm -f "$dest"
        # Use curl -L (follow redirects) --retry 3 (robustness)
        if curl -L --retry 3 --connect-timeout 15 -o "$dest" "$url"; then
            if [ -s "$dest" ]; then
                print_success "Download complete."
                return 0
            else
                print_error "Downloaded file is empty."
            fi
        else
            print_error "Download Failed! Please check internet or use Option 2 to provide local file."
        fi
    fi
}

# --- NETWORK SETUP ---
install_dependencies() {
    print_info "Installing Dependencies..."
    # Fix Apt Lock
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 1; done

    # Added build-essential (for make) and python3-venv/pip
    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq bc python3 python3-pip python3-venv build-essential"
    
    if ! apt-get install -y $PKGS; then
        print_warn "Standard install failed. Trying Iran-Optimized Mirrors..."
        if grep -q "ubuntu" /etc/os-release; then
             [ ! -f /etc/apt/sources.list.bak ] && cp /etc/apt/sources.list /etc/apt/sources.list.bak
             cat <<EOF > /etc/apt/sources.list
deb http://mirror.iranserver.com/ubuntu/ $(lsb_release -sc) main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ $(lsb_release -sc)-updates main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ $(lsb_release -sc)-backports main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ $(lsb_release -sc)-security main restricted universe multiverse
EOF
             apt-get update -qq
        fi
        apt-get --fix-broken install -y
        if ! apt-get install -y $PKGS; then
            print_error "Critical: Could not install dependencies. Check internet."
        fi
    fi
}

detect_ip() {
    SERVICES=("http://api.ipify.org" "http://ipv4.icanhazip.com")
    PUBLIC_IP=""
    for S in "${SERVICES[@]}"; do
        PUBLIC_IP=$(curl -s --max-time 3 "$S")
        [[ "$PUBLIC_IP" =~ ^[0-9]+\. ]] && break
    done
    
    if [ -z "$PUBLIC_IP" ]; then
        # Fallback to interface IP
        DEF_IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
        PUBLIC_IP=$(ip -4 addr show $DEF_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    fi

    if [ -z "$PUBLIC_IP" ]; then
        print_warn "Could not detect IP."
        read -p ">>> Enter this server's Public IP manually: " PUBLIC_IP
    fi
    
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    GW_IP=$(ip route get 8.8.8.8 | awk '{print $3}')
    GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    [ -z "$GW_MAC" ] && ping -c 1 $GW_IP >/dev/null && GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    
    print_success "IP: $PUBLIC_IP | IF: $IFACE"
}

setup_firewall_bypass() {
    local port=$1
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
    netfilter-persistent save >/dev/null 2>&1
}

# =========================================================
#  1. PAQET SETUP
# =========================================================
setup_paqet() {
    print_info "Setting up Paqet ($PAQET_PORT)..."
    cd /root
    if [ ! -f "paqet" ]; then
        get_file "Paqet Binary" "$PAQET_URL" "paqet.tar.gz"
        tar -xzf paqet.tar.gz
        [ -f "paqet_linux_amd64" ] && mv paqet_linux_amd64 paqet
        [ -f "paqet-linux-amd64" ] && mv paqet-linux-amd64 paqet
        chmod +x paqet
    fi
    
    setup_firewall_bypass "$PAQET_PORT"

    if [ "$ROLE" == "server" ]; then
        cat <<EOF > /root/paqet_server.yaml
role: "server"
log: { level: "info" }
listen: { addr: ":$PAQET_PORT" }
network: { interface: "$IFACE", ipv4: { addr: "$PUBLIC_IP:$PAQET_PORT", router_mac: "$GW_MAC" } }
transport: { protocol: "kcp", kcp: { block: "aes", key: "$KEY" } }
EOF
        CMD="/root/paqet run -c /root/paqet_server.yaml"
    else
        cat <<EOF > /root/paqet_client.yaml
role: "client"
log: { level: "info" }
socks5: [ { listen: "127.0.0.1:1080" } ]
network: { interface: "$IFACE", ipv4: { addr: "$PUBLIC_IP:0", router_mac: "$GW_MAC" } }
server: { addr: "$REMOTE_IP:$PAQET_PORT" }
transport: { protocol: "kcp", kcp: { block: "aes", key: "$KEY" } }
EOF
        CMD="/root/paqet run -c /root/paqet_client.yaml"
    fi

    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet
After=network.target
[Service]
ExecStart=$CMD
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
}

# =========================================================
#  2. GFW-KNOCKER SETUP
# =========================================================
setup_gfk() {
    print_info "Setting up GFW-Knocker ($GFK_VIO_PORT)..."
    
    if [ ! -f /root/gfk_env/bin/pip ]; then
        print_info "Creating Python Env..."
        rm -rf /root/gfk_env
        python3 -m venv /root/gfk_env
        /root/gfk_env/bin/pip install --upgrade pip
        if ! /root/gfk_env/bin/pip install scapy aioquic cryptography; then
             print_warn "Pip install failed. Retrying..."
             /root/gfk_env/bin/pip install scapy aioquic cryptography
        fi
    fi

    mkdir -p /root/gfk
    cd /root/gfk
    
    if [ "$ROLE" == "server" ]; then
        echo ""; echo -e "${YELLOW}>>> Source for GFK Server Scripts?${NC}"
        echo "   1) Download from GitHub (Default)"
        echo "   2) Use Local Files (Upload a ZIP)"
        read -p "   Select [1-2]: " gfk_choice
        gfk_choice=${gfk_choice:-1}

        if [ "$gfk_choice" == "2" ]; then
            read -p "   Enter path to ZIP file (e.g. /root/gfk.zip): " zip_path
            if [ -f "$zip_path" ]; then
                unzip -o "$zip_path" -d /root/gfk
                print_success "Extracted local scripts."
            else
                print_error "File not found. Please upload and try again."
            fi
        else
            wget -q "$GFK_RAW_URL/server/mainserver.py"
            wget -q "$GFK_RAW_URL/server/quic_server.py"
            wget -q "$GFK_RAW_URL/server/vio_server.py"
        fi
        openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=gfk" 2>/dev/null
    else
        wget -q "$GFK_RAW_URL/client/mainclient.py"
        wget -q "$GFK_RAW_URL/client/quic_client.py"
        wget -q "$GFK_RAW_URL/client/vio_client.py"
        
        if [ ! -f /usr/local/bin/microsocks ]; then
            get_file "Microsocks Source" "$MICROSOCKS_URL" "ms.tar.gz"
            mkdir -p ms_build
            tar -xzf ms.tar.gz -C ms_build --strip-components=1
            cd ms_build
            make >/dev/null && mv microsocks /usr/local/bin/
            cd /root/gfk
            rm -rf ms_build ms.tar.gz
        fi
    fi

    setup_firewall_bypass $GFK_VIO_PORT
    [ -z "$KEY" ] && KEY=$(openssl rand -hex 8)

    cat <<EOF > /root/gfk/parameters.py
vps_ip = "${REMOTE_IP:-$PUBLIC_IP}"
xray_server_ip_address = "127.0.0.1"
tcp_port_mapping = {14000: 443}
udp_port_mapping = {}
vio_tcp_server_port = $GFK_VIO_PORT
vio_tcp_client_port = 40000
vio_udp_server_port = 35000
vio_udp_client_port = 30000
quic_server_port = $GFK_QUIC_PORT
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

    if [ "$ROLE" == "server" ]; then
        sed -i "s|'python3'|'/root/gfk_env/bin/python'|g" mainserver.py
        START_CMD="/root/gfk_env/bin/python /root/gfk/mainserver.py"
        SVC_NAME="gfk-server"
    else
        cat <<WRAP > /root/gfk/start_client.sh
#!/bin/bash
pkill microsocks
/usr/local/bin/microsocks -i 127.0.0.1 -p 1081 &
/root/gfk_env/bin/python /root/gfk/mainclient.py
WRAP
        chmod +x /root/gfk/start_client.sh
        START_CMD="/root/gfk/start_client.sh"
        SVC_NAME="gfk-client"
    fi

    cat <<EOF > /etc/systemd/system/${SVC_NAME}.service
[Unit]
Description=GFW-Knocker
After=network.target
[Service]
User=root
WorkingDirectory=/root/gfk
ExecStart=${START_CMD}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable ${SVC_NAME}; systemctl restart ${SVC_NAME}
}

# --- SERVER OPTIONS ---
setup_server_options() {
    echo ""; echo -e "${CYAN}--- XRAY CONFIGURATION ---${NC}"
    echo "1) Install 3X-UI Panel"
    echo "2) Install Standalone VMess (Core Only)"
    echo "3) Skip (No Xray)"
    read -p "Select [1-3]: " XCHOICE
    XCHOICE=${XCHOICE:-3}

    if [ "$XCHOICE" == "1" ]; then
        cd /root
        get_file "X-UI Panel" "$XUI_URL" "x-ui.tar.gz"
        tar zxf x-ui.tar.gz
        mv x-ui /usr/local/
        /usr/local/x-ui/x-ui install
        
    elif [ "$XCHOICE" == "2" ]; then
        print_info "Installing Xray Core..."
        mkdir -p /usr/local/bin /usr/local/etc/xray
        get_file "Xray Core" "$CORE_URL" "xray.zip"
        unzip -o xray.zip -d xtmp
        mv xtmp/xray /usr/local/bin/
        chmod +x /usr/local/bin/xray
        rm -rf xtmp xray.zip
        
        UUID=$(cat /proc/sys/kernel/random/uuid)
        cat <<EOF > /usr/local/etc/xray/config.json
{
  "inbounds": [{
    "port": 443,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID" }] },
    "streamSettings": { "network": "tcp" }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
        nohup /usr/local/bin/xray -config /usr/local/etc/xray/config.json >/dev/null 2>&1 &
        echo ""; echo "VMESS UUID: $UUID"
        
    else
        # XCHOICE 3 (SKIP)
        echo ""; echo -e "${YELLOW}GFW-Knocker needs a backend (SOCKS5/VMess on 127.0.0.1:443).${NC}"
        read -p "Install minimal Xray Core as backend? (Recommended for GFK) [Y/n]: " install_silent
        install_silent=${install_silent:-y}
        
        if [[ "$install_silent" =~ ^[Yy]$ ]]; then
            print_info "Installing Silent Xray Core..."
            mkdir -p /usr/local/bin /usr/local/etc/xray
            get_file "Xray Core" "$CORE_URL" "xray.zip"
            unzip -o xray.zip -d xtmp
            mv xtmp/xray /usr/local/bin/
            chmod +x /usr/local/bin/xray
            rm -rf xtmp xray.zip
            
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
            nohup /usr/local/bin/xray -config /usr/local/etc/xray/config.json >/dev/null 2>&1 &
            print_success "Silent Xray Core running on 127.0.0.1:443"
        else
            print_warn "Skipped. You MUST set up your own backend on port 443 for GFK to work."
        fi
    fi
}

verify_tunnels() {
    print_info "Verifying Tunnels..."
    sleep 5
    
    IP1=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:1080 http://api.ipify.org)
    if [[ "$IP1" =~ [0-9]+\.[0-9]+ ]] || [[ "$IP1" =~ ":" ]]; then 
        print_success "Paqet Tunnel OK! Exit: $IP1"
    else
        print_warn "Paqet Check Failed: $IP1"
    fi
    
    IP2=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:1081 http://api.ipify.org)
    if [[ "$IP2" =~ [0-9]+\.[0-9]+ ]] || [[ "$IP2" =~ ":" ]]; then 
        print_success "GFK Tunnel OK! Exit: $IP2"
    else
        print_warn "GFK Check Failed: $IP2"
    fi
}

# =========================================================
#  MAIN EXECUTION
# =========================================================
check_root
clear
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}   MASTER DUAL TUNNEL (Paqet + GFW-Knocker)               ${NC}"
echo -e "${CYAN}==========================================================${NC}"
echo "1) Kharej Server (VPS Outside)"
echo "2) Iran Server   (VPS Bridge / Client)"
read -p "Select Role [1-2]: " ROLE_NUM

if [ "$ROLE_NUM" == "1" ]; then ROLE="server"; else ROLE="client"; fi

install_dependencies
detect_ip

# --- PORTS ---
echo ""; echo -e "${CYAN}--- PORT CONFIGURATION ---${NC}"
read -p "Paqet Port (Press Enter for 8880): " PAQET_PORT; PAQET_PORT=${PAQET_PORT:-8880}
read -p "GFK VIO Port (Press Enter for 45000): " GFK_VIO_PORT; GFK_VIO_PORT=${GFK_VIO_PORT:-45000}
read -p "GFK QUIC Port (Press Enter for 25000): " GFK_QUIC_PORT; GFK_QUIC_PORT=${GFK_QUIC_PORT:-25000}

if [ "$ROLE" == "server" ]; then
    KEY=$(openssl rand -hex 16)
else
    echo ""; echo -e "${CYAN}--- KHAREJ DETAILS ---${NC}"
    read -p "Kharej Server IP: " REMOTE_IP
    read -p "Secret Key (from Kharej): " KEY
fi

setup_paqet
setup_gfk

if [ "$ROLE" == "server" ]; then
    setup_server_options
    echo ""; echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      SERVER SETUP COMPLETE             ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "COPY THESE TO IRAN SERVER:"
    echo -e "IP:            ${YELLOW}$PUBLIC_IP${NC}"
    echo -e "Paqet Port:    ${YELLOW}$PAQET_PORT${NC}"
    echo -e "GFK VIO Port:  ${YELLOW}$GFK_VIO_PORT${NC}"
    echo -e "GFK QUIC Port: ${YELLOW}$GFK_QUIC_PORT${NC}"
    echo -e "Secret Key:    ${YELLOW}$KEY${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    verify_tunnels
    echo ""; echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      CLIENT SETUP COMPLETE             ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Paqet SOCKS5:  ${YELLOW}127.0.0.1:1080${NC}"
    echo -e "GFK SOCKS5:    ${YELLOW}127.0.0.1:1081${NC}"
    echo -e "${GREEN}========================================${NC}"
fi