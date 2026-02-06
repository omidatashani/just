#!/bin/bash

# =========================================================
#  MASTER DUAL TUNNEL (Verbose & Robust)
# =========================================================

# --- CONFIGURATION ---
PAQET_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz"
GFK_RAW_URL="https://raw.githubusercontent.com/SamNet-dev/paqctl/main/gfk"
MICROSOCKS_URL="https://github.com/rofl0r/microsocks/archive/refs/heads/master.tar.gz"
XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/v2.4.4/x-ui-linux-amd64.tar.gz"
CORE_URL="https://github.com/GFW-knocker/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"

# Ports
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

# --- ROBUST OPTIMIZATION ---
backup_network_config() {
    if [ ! -f /root/network_backup_done ]; then
        print_info "Backing up network config..."
        [ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak
        [ -f /etc/apt/sources.list ] && cp /etc/apt/sources.list /etc/apt/sources.list.bak
        touch /root/network_backup_done
    fi
}

apply_iran_optimizations() {
    print_warn "Standard install failed. Switching to Optimized Mirrors..."
    
    # 1. Optimize DNS
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    echo "nameserver 2001:4860:4860::8888" >> /etc/resolv.conf

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
              "http://repo.iut.ac.ir/repo/Ubuntu/"
            )
            BEST_MIRROR=""
            BEST_TIME=10.0

            print_info "Testing Iran Mirrors (Latency)..."
            
            for M in "${MIRRORS[@]}"; do
                # Test download speed of a small file (Release file)
                TIME=$(curl -o /dev/null -s -w '%{time_total}\n' --max-time 2 "$M")
                
                if [ $? -eq 0 ]; then
                    echo -e "   $M -> ${GREEN}${TIME}s${NC}"
                    # Use awk for float comparison
                    IS_FASTER=$(echo "$TIME $BEST_TIME" | awk '{print ($1 < $2)}')
                    if [ "$IS_FASTER" -eq 1 ]; then
                        BEST_TIME=$TIME
                        BEST_MIRROR=$M
                    fi
                else
                    echo -e "   $M -> ${RED}Timeout${NC}"
                fi
            done

            if [ -n "$BEST_MIRROR" ]; then
                print_success "Selected Fastest: $BEST_MIRROR"
                cat <<EOF > /etc/apt/sources.list
deb ${BEST_MIRROR} ${VERSION_CODENAME} main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-updates main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-backports main restricted universe multiverse
deb ${BEST_MIRROR} ${VERSION_CODENAME}-security main restricted universe multiverse
EOF
                print_info "Updating apt cache (Verbose)..."
                apt-get update
            else
                print_warn "All mirrors timed out. Keeping default."
            fi
        fi
    fi
}

install_dependencies() {
    print_info "Checking System Dependencies..."
    backup_network_config
    
    # Wait for locks
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do 
        echo "Waiting for apt lock..."
        sleep 2
    done

    # CRITICAL PACKAGES
    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq python3 python3-pip python3-venv build-essential"
    
    # Try normal install first
    print_info "Attempting standard install..."
    if ! apt-get install -y $PKGS; then
        apply_iran_optimizations
        print_info "Retrying install with optimized settings..."
        apt-get --fix-broken install -y
        if ! apt-get install -y $PKGS; then
            print_error "Critical failure: Could not install dependencies."
        fi
    fi
}

# --- COMMON UTILS ---
detect_ip() {
    print_info "Detecting IP..."
    SERVICES=("http://ipv4.icanhazip.com" "http://api.ipify.org" "http://ifconfig.me/ip")
    PUBLIC_IP=""
    for S in "${SERVICES[@]}"; do
        PUBLIC_IP=$(curl -s --max-time 3 "$S")
        if [[ "$PUBLIC_IP" =~ ^[0-9]+\. ]]; then
            echo -e "   Detected via $S: ${GREEN}$PUBLIC_IP${NC}"
            break
        fi
    done
    
    if [ -z "$PUBLIC_IP" ]; then
        print_warn "Auto-detection failed (403/Timeout)."
        read -p ">>> Please enter this server's Public IP manually: " PUBLIC_IP
    fi
    
    IFACE=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')
    GW_IP=$(ip route get 1.1.1.1 | awk '{print $3}')
    GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    [ -z "$GW_MAC" ] && ping -c 1 -W 1 $GW_IP >/dev/null && GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    
    print_success "Network Ready: IP=$PUBLIC_IP | IF=$IFACE"
}

setup_firewall_bypass() {
    local port=$1
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
    iptables -t mangle -D OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -t mangle -A OUTPUT -p tcp --sport $port --tcp-flags RST RST -j DROP
    netfilter-persistent save >/dev/null 2>&1
}

# =========================================================
#  1. PAQET SETUP
# =========================================================
setup_paqet() {
    print_info "Installing Paqet..."
    cd /root
    rm -f paqet.tar.gz
    wget --show-progress -q -O paqet.tar.gz "$PAQET_URL"
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
    print_info "Installing GFW-Knocker..."
    
    # 1. Python Venv
    if [ ! -f /root/gfk_env/bin/pip ]; then
        print_info "Creating Python Environment..."
        rm -rf /root/gfk_env
        python3 -m venv /root/gfk_env
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
        
        # 3. Microsocks
        if [ ! -f /usr/local/bin/microsocks ]; then
            print_info "Compiling Microsocks..."
            cd /tmp
            wget -q -O ms.tar.gz "$MICROSOCKS_URL"
            tar -xzf ms.tar.gz
            cd microsocks-master
            make >/dev/null
            mv microsocks /usr/local/bin/
            cd /root/gfk
        fi
    fi

    # 4. Config
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
#  3. FINAL OPTIONS
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
    IP1=$(curl -s --max-time 3 --socks5-hostname 127.0.0.1:1080 http://ifconfig.me)
    if [ -n "$IP1" ]; then print_success "Paqet Tunnel OK! Exit: $IP1"; else print_warn "Paqet Check Failed"; fi
    
    IP2=$(curl -s --max-time 3 --socks5-hostname 127.0.0.1:1081 http://ifconfig.me)
    if [ -n "$IP2" ]; then print_success "GFK Tunnel OK! Exit: $IP2"; else print_warn "GFK Check Failed"; fi
}

# =========================================================
#  MAIN
# =========================================================
check_root
clear
echo "=========================================================="
echo "   DUAL TUNNEL MASTER (Paqet + GFW-Knocker)               "
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
    echo ""; echo "========================================"
    print_success "SERVER SETUP COMPLETE"
    echo "IP:  $PUBLIC_IP"
    echo "Key: $KEY"
    echo "========================================"
else
    verify_tunnels
    echo ""; echo "========================================"
    print_success "CLIENT SETUP COMPLETE"
    echo "Paqet SOCKS5: 127.0.0.1:1080"
    echo "GFK SOCKS5:   127.0.0.1:1081"
    echo "========================================"
fi