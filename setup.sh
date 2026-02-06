#!/bin/bash

# =========================================================
#  PAQET SIMPLE TUNNEL V2: PAQET + OPTIONAL XRAY BRIDGE
# =========================================================

# --- CONFIGURATION ---
PAQET_VERSION="v1.0.0-alpha.14"
PAQET_URL="https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/paqet-linux-amd64-${PAQET_VERSION}.tar.gz"
XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/v2.4.4/x-ui-linux-amd64.tar.gz"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"

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

# --- DOWNLOADER ---
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
                print_warn "File not found. Try again."
            fi
        done
    else
        print_info "Downloading $name..."
        rm -f "$dest"
        if curl -L --progress-bar --retry 3 --connect-timeout 20 -o "$dest" "$url"; then
            if [ -s "$dest" ] && [ $(stat -c%s "$dest") -gt 1000 ]; then
                print_success "Download complete."
                return 0
            else
                print_error "Download corrupted. Try Option 2."
            fi
        else
            print_error "Download Failed! Check internet or use Option 2."
        fi
    fi
}

# --- DEPENDENCIES ---
install_dependencies() {
    print_info "Installing Dependencies..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 1; done

    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq bc"
    
    if ! apt-get install -y $PKGS; then
        print_warn "Apt failed. Switching to Iran mirrors..."
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
        apt-get install -y $PKGS
    fi
}

detect_ip() {
    PUBLIC_IP=$(curl -s --max-time 3 http://api.ipify.org)
    if [[ ! "$PUBLIC_IP" =~ ^[0-9]+\. ]]; then
        DEF_IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
        PUBLIC_IP=$(ip -4 addr show $DEF_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    fi
    [ -z "$PUBLIC_IP" ] && read -p ">>> Enter Public IP Manually: " PUBLIC_IP
    
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
#  PAQET SETUP
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
Description=Paqet Service
After=network.target
[Service]
ExecStart=$CMD
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
    
    if [ "$ROLE" == "client" ]; then
        print_info "Waiting for Paqet to initialize..."
        sleep 3
    fi
}

# =========================================================
#  IRAN-ONLY: XRAY BRIDGE SETUP
# =========================================================
setup_iran_xray() {
    echo ""; echo -e "${CYAN}--- BRIDGE CONFIGURATION ---${NC}"
    echo "1) Install 3X-UI Panel (Visual Management)"
    echo "2) Install Simple Xray Core (Lightweight)"
    echo "3) I already have Xray/X-UI installed (Default)"
    read -p "Select [1-3]: " XCHOICE
    XCHOICE=${XCHOICE:-3}

    if [ "$XCHOICE" != "3" ]; then
        UUID=$(cat /proc/sys/kernel/random/uuid)
        RAND_PORT=$(shuf -i 2000-60000 -n 1)
    fi

    if [ "$XCHOICE" == "1" ]; then
        # --- X-UI ---
        print_info "Installing X-UI..."
        cd /root
        get_file "X-UI Panel" "$XUI_URL" "x-ui.tar.gz"
        tar zxf x-ui.tar.gz
        mv x-ui /usr/local/
        /usr/local/x-ui/x-ui install
        
        print_info "Configuring X-UI Database..."
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '[{\"tag\":\"proxy\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":1080}]}},{\"tag\":\"direct\",\"protocol\":\"freedom\",\"settings\":{}}]' WHERE key = 'xrayTemplateConfig';"
        sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, client_stats, tag, protocol, port, settings, stream_settings, sniffing, listen) VALUES (1, 0, 0, 0, 'Paqet-VMess', 1, 0, 0, 'vmess_auto', 'vmess', $RAND_PORT, '{\"clients\": [{\"id\": \"$UUID\", \"alterId\": 0, \"email\": \"paqet_user\"}]}', '{\"network\": \"tcp\"}', '{\"enabled\": true}', '');"
        
        systemctl restart x-ui
        
    elif [ "$XCHOICE" == "2" ]; then
        # --- CORE ONLY ---
        print_info "Installing Xray Core..."
        mkdir -p /usr/local/bin /usr/local/etc/xray
        get_file "Xray Core" "$XRAY_URL" "xray.zip"
        unzip -o xray.zip -d xtmp >/dev/null
        mv xtmp/xray /usr/local/bin/
        chmod +x /usr/local/bin/xray
        rm -rf xtmp xray.zip
        
        cat <<EOF > /usr/local/etc/xray/config.json
{
  "inbounds": [{
    "port": $RAND_PORT,
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID" }] },
    "streamSettings": { "network": "tcp" }
  }],
  "outbounds": [
    { "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 1080 }] } },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
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
        systemctl daemon-reload; systemctl enable xray; systemctl restart xray
    else
        print_info "Skipping Xray installation (Using existing setup)."
    fi

    # Output based on choice
    echo ""; echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      IRAN SETUP COMPLETE               ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "1. Paqet Tunnel: Connected to Kharej"
    
    if [ "$XCHOICE" != "3" ]; then
        VMESS_JSON="{\"v\":\"2\",\"ps\":\"Paqet-Iran\",\"add\":\"$PUBLIC_IP\",\"port\":\"$RAND_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"\"}"
        VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        echo -e "2. Xray Bridge:  Running on Port $RAND_PORT"
        echo -e "3. VMess Link:"
        echo -e "${CYAN}$VMESS_LINK${NC}"
    else
        echo -e "2. Xray Bridge:  ${YELLOW}Use your existing Panel${NC}"
        echo -e "3. Config Info:  Set your Outbound to ${CYAN}SOCKS5 127.0.0.1:1080${NC}"
    fi
    echo -e "${GREEN}========================================${NC}"
}

# =========================================================
#  MAIN EXECUTION
# =========================================================
check_root
clear
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}   PAQET SIMPLE TUNNEL (Kharej <-> Iran Bridge2)           ${NC}"
echo -e "${CYAN}==========================================================${NC}"
echo "1) Kharej Server (Tunnel Exit)"
echo "2) Iran Server   (Tunnel Entry + Bridge)"
read -p "Select Role [1-2]: " ROLE_NUM

if [ "$ROLE_NUM" == "1" ]; then ROLE="server"; else ROLE="client"; fi

install_dependencies
detect_ip

# --- PORTS ---
echo ""; echo -e "${CYAN}--- CONFIGURATION ---${NC}"
read -p "Paqet Port (Press Enter for 8880): " PAQET_PORT; PAQET_PORT=${PAQET_PORT:-8880}

if [ "$ROLE" == "server" ]; then
    KEY=$(openssl rand -hex 16)
else
    echo ""; echo -e "${CYAN}--- KHAREJ DETAILS ---${NC}"
    read -p "Kharej Server IP: " REMOTE_IP
    read -p "Secret Key (from Kharej): " KEY
fi

setup_paqet

if [ "$ROLE" == "server" ]; then
    echo ""; echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      KHAREJ SETUP COMPLETE             ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Use these details on Iran Server:"
    echo -e "IP:            ${YELLOW}$PUBLIC_IP${NC}"
    echo -e "Paqet Port:    ${YELLOW}$PAQET_PORT${NC}"
    echo -e "Secret Key:    ${YELLOW}$KEY${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    setup_iran_xray
fi