#!/bin/bash

# =========================================================
#  DUAL TUNNEL MASTER: PAQET + GFW-KNOCKER + SMART NETWORKING
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

check_root() { if [ "$EUID" -ne 0 ]; then print_error "Please run as root (sudo bash setup.sh)"; fi; }

# --- SMART NETWORK OPTIMIZATION ---
backup_network_config() {
    if [ ! -f /root/network_backup_done ]; then
        print_info "Backing up network config..."
        [ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak
        [ -f /etc/apt/sources.list ] && cp /etc/apt/sources.list /etc/apt/sources.list.bak
        
        # Create Restore Script
        cat <<EOF > /root/restore_network.sh
#!/bin/bash
[ -f /etc/resolv.conf.bak ] && cp /etc/resolv.conf.bak /etc/resolv.conf
[ -f /etc/apt/sources.list.bak ] && cp /etc/apt/sources.list.bak /etc/apt/sources.list
echo "Network settings restored."
EOF
        chmod +x /root/restore_network.sh
        touch /root/network_backup_done
    fi
}

apply_iran_optimizations() {
    print_warn "Download failed! Switching to Optimized Iran Mirrors & DNS..."
    
    # 1. Optimize DNS (Mix of internal/external)
    cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 185.51.200.2
nameserver 178.22.122.100
nameserver 2001:4860:4860::8888
EOF

    # 2. Find Fastest Mirror
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [ "$ID" == "ubuntu" ]; then
            MIRRORS=(
              "http://mirror.iranserver.com/ubuntu/"
              "https://mirrors.pardisco.co/ubuntu/"
              "http://mirror.aminidc.com/ubuntu/"
              "https://ubuntu.shatel.ir/ubuntu/"
              "http://mirror.asiatech.ir/ubuntu/"
              "https://ir.ubuntu.sindad.cloud/ubuntu/"
              "http://repo.iut.ac.ir/repo/Ubuntu/"
            )
            BEST_MIRROR=""
            BEST_TIME=1000

            print_info "Testing Iran Mirrors..."
            for M in "${MIRRORS[@]}"; do
                TIME=$(curl -o /dev/null -s -w '%{time_total}\n' --max-time 1 "$M")
                if [ $? -eq 0 ] && (( $(echo "$TIME < $BEST_TIME" | bc -l) )); then
                    BEST_TIME=$TIME; BEST_MIRROR=$M
                fi
            done

            if [ -n "$BEST_MIRROR" ]; then
                print_success "Switched to: $BEST_MIRROR"
                cat <<EOF > /etc/apt/sources.list
deb ${BEST_MIRROR} ${VERSION_CODENAME} main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-updates main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-backports main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-security main restricted universe multiverse
EOF
                apt-get update -qq
            fi
        fi
    fi
}

install_dependencies() {
    print_info "Installing Dependencies..."
    backup_network_config
    
    # Wait for locks
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 1; done

    # CRITICAL: python3-venv and build-essential are required for GFK/Microsocks
    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq bc python3 python3-pip python3-venv build-essential"
    
    # Try normal install first
    if ! apt-get install -y $PKGS; then
        # If failed, optimize and try again
        apply_iran_optimizations
        apt-get --fix-broken install -y
        if ! apt-get install -y $PKGS; then
            print_error "Failed to install dependencies even after optimization."
        fi
    fi
}

# --- COMMON UTILS ---
detect_ip() {
    # Robust IP Detection
    SERVICES=("http://ipv4.icanhazip.com" "http://api.ipify.org" "http://ifconfig.me/ip")
    PUBLIC_IP=""
    for S in "${SERVICES[@]}"; do
        PUBLIC_IP=$(curl -s --max-time 3 "$S")
        [[ "$PUBLIC_IP" =~ ^[0-9]+\. ]] && break
    done
    [ -z "$PUBLIC_IP" ] && read -p ">>> Could not detect IP. Enter manually: " PUBLIC_IP
    
    # Gateway Detection for Raw Sockets
    IFACE=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')
    GW_IP=$(ip route get 1.1.1.1 | awk '{print $3}')
    GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    [ -z "$GW_MAC" ] && ping -c 1 $GW_IP >/dev/null && GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    
    print_success "IP: $PUBLIC_IP | Iface: $IFACE"
}

setup_firewall_bypass() {
    local port=$1
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
    iptables -t mangle -D OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP
}

# =========================================================
#  1. PAQET SETUP
# =========================================================
setup_paqet() {
    print_info "Setting up Paqet (Port $PAQET_PORT)..."
    cd /root
    rm -f paqet.tar.gz
    wget -q -O paqet.tar.gz "$PAQET_URL"
    tar -xzf paqet.tar.gz
    [ -f "paqet_linux_amd64" ] && mv paqet_linux_amd64 paqet
    [ -f "paqet-linux-amd64" ] && mv paqet-linux-amd64 paqet
    chmod +x paqet
    
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
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
}

# =========================================================
#  2. GFW-KNOCKER SETUP
# =========================================================
setup_gfk() {
    print_info "Setting up GFW-Knocker (Port $GFK_VIO_PORT)..."
    
    # 1. Python Environment (Fixed PIP Error)
    if [ ! -f /root/gfk_env/bin/pip ]; then
        print_info "Creating Python Venv..."
        rm -rf /root/gfk_env
        python3 -m venv /root/gfk_env
        # Verify venv creation
        if [ ! -f /root/gfk_env/bin/pip ]; then
            print_error "Venv creation failed. 'python3-venv' package might still be missing."
        fi
        /root/gfk_env/bin/pip install --upgrade pip
        /root/gfk_env/bin/pip install scapy aioquic cryptography
    fi

    # 2. Download Scripts
    mkdir -p /root/gfk
    cd /root/gfk
    if [ "$ROLE" == "server" ]; then
        wget -q "$GFK_RAW_URL/server/mainserver.py"
        wget -q "$GFK_RAW_URL/server/quic_server.py"
        wget -q "$GFK_RAW_URL/server/vio_server.py"
        openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=gfk" 2>/dev/null
    else
        wget -q "$GFK_RAW_URL/client/mainclient.py"
        wget -q "$GFK_RAW_URL/client/quic_client.py"
        wget -q "$GFK_RAW_URL/client/vio_client.py"
        
        # 3. Microsocks (Fixed Make Error)
        if [ ! -f /usr/local/bin/microsocks ]; then
            print_info "Compiling Microsocks..."
            cd /tmp
            wget -q -O ms.tar.gz "$MICROSOCKS_URL"
            tar -xzf ms.tar.gz
            cd microsocks-master
            if ! make; then
                print_error "Microsocks compilation failed. 'make' or 'gcc' missing."
            fi
            mv microsocks /usr/local/bin/
            cd /root/gfk
        fi
    fi

    # 4. Generate Config
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

    # 5. Service
    if [ "$ROLE" == "server" ]; then
        sed -i "s|'python3'|'/root/gfk_env/bin/python'|g" mainserver.py
        START_CMD="/root/gfk_env/bin/python /root/gfk/mainserver.py"
    else
        cat <<WRAP > /root/gfk/start_client.sh
#!/bin/bash
pkill microsocks
/usr/local/bin/microsocks -i 127.0.0.1 -p 1081 &
/root/gfk_env/bin/python /root/gfk/mainclient.py
WRAP
        chmod +x /root/gfk/start_client.sh
        START_CMD="/root/gfk/start_client.sh"
    fi

    cat <<EOF > /etc/systemd/system/gfk.service
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
    systemctl daemon-reload; systemctl enable gfk; systemctl restart gfk
}

# =========================================================
#  3. FINAL OPTIONS (X-UI / CORE / VERIFY)
# =========================================================
setup_xray_option() {
    echo ""; echo "--- XRAY CONFIGURATION ---"
    echo "1) Install 3X-UI Panel (Recommended)"
    echo "2) Install Standalone VMess (Core Only)"
    echo "3) Skip"
    read -p "Select [1-3]: " XCHOICE

    if [ "$XCHOICE" == "1" ]; then
        print_info "Installing X-UI..."
        cd /root
        rm -rf x-ui*
        wget -q -O x-ui.tar.gz "$XUI_URL"
        tar zxf x-ui.tar.gz
        mv x-ui /usr/local/
        /usr/local/x-ui/x-ui install >/dev/null
    elif [ "$XCHOICE" == "2" ]; then
        print_info "Installing Xray Core..."
        mkdir -p /usr/local/bin /usr/local/etc/xray
        wget -q -O xray.zip "$CORE_URL"
        unzip -o xray.zip -d xtmp >/dev/null
        mv xtmp/xray /usr/local/bin/
        chmod +x /usr/local/bin/xray
        rm -rf xtmp xray.zip
        
        UUID=$(cat /proc/sys/kernel/random/uuid)
        # Port 443 allows this core to serve BOTH Paqet (forwarded via panel) and GFK (mapped to 443)
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
        echo "VMESS UUID: $UUID"
    fi
}

verify_tunnels() {
    print_info "Verifying Tunnels..."
    sleep 5
    # Check Paqet (Port 1080)
    IP1=$(curl -s --max-time 3 --socks5-hostname 127.0.0.1:1080 http://ifconfig.me)
    if [ -n "$IP1" ]; then print_success "Paqet Tunnel OK! Exit IP: $IP1"; else print_warn "Paqet Tunnel Verification Failed"; fi
    
    # Check GFK (Port 1081 - configured in start_client.sh)
    IP2=$(curl -s --max-time 3 --socks5-hostname 127.0.0.1:1081 http://ifconfig.me)
    if [ -n "$IP2" ]; then print_success "GFK Tunnel OK! Exit IP: $IP2"; else print_warn "GFK Tunnel Verification Failed"; fi
}

# =========================================================
#  MAIN EXECUTION
# =========================================================
check_root
clear
echo "=========================================================="
echo "   DUAL TUNNEL INSTALLER (Paqet + GFW-Knocker)            "
echo "=========================================================="
echo "1) Kharej Server (VPS Outside)"
echo "2) Iran Server   (VPS Bridge / Client)"
read -p "Select Role [1-2]: " ROLE_NUM

if [ "$ROLE_NUM" == "1" ]; then ROLE="server"; else ROLE="client"; fi

install_dependencies
detect_ip

if [ "$ROLE" == "server" ]; then
    KEY=$(openssl rand -hex 16)
else
    read -p "Kharej Server IP: " REMOTE_IP
    read -p "Secret Key: " KEY
fi

setup_paqet
setup_gfk

if [ "$ROLE" == "server" ]; then
    setup_xray_option
    echo ""
    echo "========================================"
    print_success "SERVER SETUP COMPLETE"
    echo "Use these details on Iran/Client:"
    echo "IP:  $PUBLIC_IP"
    echo "Key: $KEY"
    echo "========================================"
else
    verify_tunnels
    echo ""
    echo "========================================"
    print_success "CLIENT SETUP COMPLETE"
    echo "Paqet SOCKS5: 127.0.0.1:1080"
    echo "GFK SOCKS5:   127.0.0.1:1081"
    echo "========================================"
fi