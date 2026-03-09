#!/usr/bin/env bash
#
# WireGuard Road Warrior Installer
# Modernized version with privacy-focused logging control
# Fixed file permissions for security
#

set -euo pipefail

# ────────────────────────────────────────────────
#  Initialization and sanity checks
# ────────────────────────────────────────────────

# Ensure script is run with bash, not sh/dash
if [[ "$(readlink -f /proc/$$/exe)" == */dash ]]; then
    echo "Error: This script must be executed with bash, not sh." >&2
    exit 1
fi

umask 077

# Discard stdin to prevent issues with curl|bash one-liners
read -t 0.001 -N 999999 discard_stdin 2>/dev/null || true

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# Verify sbin directories are in PATH
if ! grep -q sbin <<< "$PATH"; then
    echo "Error: PATH does not include sbin directories. Try using 'su -' instead of 'su'." >&2
    exit 1
fi

# ────────────────────────────────────────────────
#  OS Detection and compatibility
# ────────────────────────────────────────────────

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        os="${ID:-unknown}"
        os_version="${VERSION_ID:-0}"
    else
        os="unknown"
    fi

    case "$os" in
        ubuntu)
            if (( ${os_version//./} < 2204 )); then
                echo "Error: Ubuntu 22.04 or newer is required." >&2
                exit 1
            fi
            ;;
        debian)
            if [[ $os_version -lt 11 ]]; then
                echo "Error: Debian 11 or newer is required." >&2
                exit 1
            fi
            if grep -q '/sid' /etc/debian_version 2>/dev/null; then
                echo "Error: Debian testing/unstable is not supported." >&2
                exit 1
            fi
            ;;
        almalinux|rocky|centos)
            if (( ${os_version%%.*} < 9 )); then
                echo "Error: ${PRETTY_NAME:-$os} 9 or newer is required." >&2
                exit 1
            fi
            os="centos"  # Normalize for package management
            ;;
        fedora)
            if (( ${os_version%%.*} < 36 )); then
                echo "Warning: Fedora 36 or newer is recommended." >&2
            fi
            ;;
        *)
            echo "Error: Unsupported distribution." >&2
            echo "Supported distributions:" >&2
            echo "  • Ubuntu ≥ 22.04" >&2
            echo "  • Debian ≥ 11" >&2
            echo "  • AlmaLinux/Rocky/CentOS Stream ≥ 9" >&2
            echo "  • Fedora (recent versions)" >&2
            exit 1
            ;;
    esac
}

detect_os

# ────────────────────────────────────────────────
#  Environment detection
# ────────────────────────────────────────────────

detect_virtualization() {
    if systemd-detect-virt -cq 2>/dev/null; then
        # Inside container
        if ! grep -q '^wireguard ' /proc/modules 2>/dev/null; then
            use_boringtun=1
        else
            use_boringtun=0
        fi
    else
        use_boringtun=0
    fi

    if (( use_boringtun == 1 )); then
        if [[ "$(uname -m)" != "x86_64" ]]; then
            echo "Error: BoringTun only supports x86_64 in containers." >&2
            exit 1
        fi
        if [[ ! -c /dev/net/tun ]] || ! exec 7<>/dev/net/tun 2>/dev/null; then
            echo "Error: TUN device is not available." >&2
            exit 1
        fi
    fi
}

detect_virtualization

# ────────────────────────────────────────────────
#  Utility functions
# ────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_hostname() {
    local hostname=$1
    [[ $hostname =~ ^[a-zA-Z0-9.-]+$ ]] && [[ ! $hostname =~ ^[.-] ]] && [[ ! $hostname =~ [.-]$ ]]
}

sanitize_client_name() {
    local name=$1
    # Allow alphanumeric, underscore, hyphen, limit to 15 chars
    echo "$name" | tr -c '[:alnum:]_-' '_' | cut -c1-15
}

get_free_octet() {
    local octet=2
    while grep -q "10.7.0.$octet/" /etc/wireguard/wg0.conf 2>/dev/null; do
        ((octet++))
        if (( octet >= 255 )); then
            echo "Error: IP address space exhausted (maximum 253 clients)." >&2
            exit 1
        fi
    done
    echo "$octet"
}

install_packages() {
    local packages=("$@")
    case "$os" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq "${packages[@]}"
            ;;
        centos|fedora)
            if [[ "$os" == "centos" ]]; then
                dnf install -y -q epel-release
            fi
            dnf install -y -q "${packages[@]}"
            ;;
    esac
}

# ────────────────────────────────────────────────
#  DNS selection
# ────────────────────────────────────────────────

select_dns() {
    echo
    echo "DNS Server Selection:"
    echo "  1) System default resolvers"
    echo "  2) Google (8.8.8.8, 8.8.4.4)"
    echo "  3) Cloudflare (1.1.1.1, 1.0.0.1)"
    echo "  4) OpenDNS (208.67.222.222, 208.67.220.220)"
    echo "  5) Quad9 (9.9.9.9, 149.112.112.112)"
    echo "  6) Gcore (95.85.95.85, 2.56.220.2)"
    echo "  7) AdGuard (94.140.14.14, 94.140.15.15)"
    echo "  8) Custom DNS servers"
    
    read -r -p "Choice [1]: " dns_choice
    
    case "${dns_choice:-1}" in
        1|"")
            if grep -q '^nameserver 127.0.0.53' /etc/resolv.conf; then
                resolv="/run/systemd/resolve/resolv.conf"
            else
                resolv="/etc/resolv.conf"
            fi
            DNS_SERVERS=$(grep '^nameserver' "$resolv" | grep -v '127.0.0.53' | awk '{print $2}' | paste -sd, -)
            ;;
        2) DNS_SERVERS="8.8.8.8,8.8.4.4" ;;
        3) DNS_SERVERS="1.1.1.1,1.0.0.1" ;;
        4) DNS_SERVERS="208.67.222.222,208.67.220.220" ;;
        5) DNS_SERVERS="9.9.9.9,149.112.112.112" ;;
        6) DNS_SERVERS="95.85.95.85,2.56.220.2" ;;
        7) DNS_SERVERS="94.140.14.14,94.140.15.15" ;;
        8)
            local custom_dns=()
            echo "Enter DNS servers (IPv4 addresses, separated by commas or spaces):"
            read -r custom_input
            
            # Convert commas to spaces and split
            custom_input=$(echo "$custom_input" | tr ',' ' ')
            for ip in $custom_input; do
                if validate_ip "$ip"; then
                    custom_dns+=("$ip")
                fi
            done
            
            if (( ${#custom_dns[@]} == 0 )); then
                echo "Error: No valid DNS servers provided." >&2
                exit 1
            fi
            DNS_SERVERS=$(IFS=,; echo "${custom_dns[*]}")
            ;;
        *)
            echo "Error: Invalid selection." >&2
            exit 1
            ;;
    esac
}

# ────────────────────────────────────────────────
#  Logging configuration
# ────────────────────────────────────────────────

configure_logging() {
    echo
    echo "Logging Configuration:"
    echo "  This setting determines whether the server keeps connection logs."
    echo "  1) Keep logs (default WireGuard behavior - SaveConfig=true)"
    echo "  2) Disable logging (maximum privacy - SaveConfig=false)"
    echo
    read -r -p "Choice [1]: " log_choice
    
    case "${log_choice:-1}" in
        1|"") LOGGING_ENABLED=1 ;;
        2)    LOGGING_ENABLED=0 ;;
        *)    
            echo "Error: Invalid selection." >&2
            exit 1
            ;;
    esac
}

# ────────────────────────────────────────────────
#  Client configuration generation
# ────────────────────────────────────────────────

generate_client_config() {
    local client_name=$1
    local client_ip_octet=$2
    local client_private_key client_public_key psk
    
    client_private_key=$(wg genkey)
    client_public_key=$(wg pubkey <<< "$client_private_key")
    psk=$(wg genpsk)
    
    # Add peer to server config
    {
        echo
        echo "# BEGIN_PEER $client_name"
        echo "[Peer]"
        echo "PublicKey = $client_public_key"
        echo "PresharedKey = $psk"
        echo "AllowedIPs = 10.7.0.$client_ip_octet/32"
        echo "# END_PEER $client_name"
    } >> /etc/wireguard/wg0.conf
    
    # Create client config file with secure permissions
    local client_config="$SCRIPT_DIR/${client_name}.conf"
    
    # Create file with secure permissions from the start
    # Use umask to ensure no other users can read the file during creation
    (
        umask 077
        cat > "$client_config" <<-EOF
[Interface]
Address = 10.7.0.$client_ip_octet/24
DNS = $DNS_SERVERS
PrivateKey = $client_private_key

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_ENDPOINT:$WG_PORT
PersistentKeepalive = 25
EOF
    )
    
    # Verify permissions (should be 600)
    chmod 600 "$client_config"
    
    # Also set secure permissions on the directory if needed
    chmod 700 "$SCRIPT_DIR" 2>/dev/null || true
    
    echo "$client_config"
}

# ────────────────────────────────────────────────
#  Firewall configuration
# ────────────────────────────────────────────────

configure_firewall() {
    local server_ip=$1
    local port=$2
    
    if systemctl is-active --quiet firewalld.service; then
        # firewalld configuration
        firewall-cmd --quiet --add-port="$port/udp"
        firewall-cmd --quiet --zone=trusted --add-source=10.7.0.0/24
        firewall-cmd --quiet --permanent --add-port="$port/udp"
        firewall-cmd --quiet --permanent --zone=trusted --add-source=10.7.0.0/24
        
        # NAT configuration
        firewall-cmd --quiet --direct --add-rule ipv4 nat POSTROUTING 0 \
            -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to "$server_ip"
        firewall-cmd --quiet --permanent --direct --add-rule ipv4 nat POSTROUTING 0 \
            -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to "$server_ip"
            
    elif hash iptables 2>/dev/null; then
        # iptables configuration with systemd service
        local iptables_path iptables_service
        
        iptables_path=$(command -v iptables)
        
        # Use iptables-legacy on OpenVZ if needed
        if [[ $(systemd-detect-virt) == "openvz" ]] && 
           readlink -f "$iptables_path" | grep -q "nft" && 
           hash iptables-legacy 2>/dev/null; then
            iptables_path=$(command -v iptables-legacy)
        fi
        
        iptables_service="/etc/systemd/system/wg-iptables.service"
        
        cat > "$iptables_service" <<-EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$iptables_path -w 5 -t nat -A POSTROUTING -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to $server_ip
ExecStart=$iptables_path -w 5 -I INPUT -p udp --dport $port -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -s 10.7.0.0/24 -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -w 5 -t nat -D POSTROUTING -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to $server_ip
ExecStop=$iptables_path -w 5 -D INPUT -p udp --dport $port -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -s 10.7.0.0/24 -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl enable --now wg-iptables.service
    fi
}

# ────────────────────────────────────────────────
#  QR code generation
# ────────────────────────────────────────────────

display_qr_code() {
    local config_file=$1
    
    if hash qrencode 2>/dev/null; then
        echo
        echo "Client configuration QR code:"
        echo "─────────────────────────────"
        qrencode -t ANSI256UTF8 < "$config_file"
        echo "─────────────────────────────"
        echo "↑ Scan this QR code with the WireGuard mobile app"
    else
        echo "Note: Install qrencode to generate QR codes for mobile clients."
    fi
}

# ────────────────────────────────────────────────
#  Verify file permissions
# ────────────────────────────────────────────────

verify_permissions() {
    local config_file=$1
    
    # Check if permissions are correct (600)
    local perms
    perms=$(stat -c "%a" "$config_file" 2>/dev/null || stat -f "%OLp" "$config_file" 2>/dev/null)
    
    if [[ "$perms" != "600" ]]; then
        echo "Warning: Fixing permissions on $config_file"
        chmod 600 "$config_file"
    fi
    
    # Verify owner is root
    local owner
    owner=$(stat -c "%U" "$config_file" 2>/dev/null || stat -f "%Su" "$config_file" 2>/dev/null)
    if [[ "$owner" != "root" ]]; then
        echo "Warning: Changing owner of $config_file to root"
        chown root:root "$config_file"
    fi
}

# ────────────────────────────────────────────────
#  Main installation
# ────────────────────────────────────────────────

if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    # First-time installation
    clear
    cat <<-EOF
	┌──────────────────────────────────────────────┐
	│     WireGuard Road Warrior Installer         │
	│     Modern version with privacy controls     │
	└──────────────────────────────────────────────┘
	EOF
    
    # Get logging preference
    configure_logging
    
    # Get server IP address
    available_ips=($(ip -4 addr | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.'))
    
    if (( ${#available_ips[@]} == 1 )); then
        SERVER_IP="${available_ips[0]}"
    else
        echo
        echo "Available IP addresses:"
        for i in "${!available_ips[@]}"; do
            echo "  $((i+1))) ${available_ips[i]}"
        done
        read -r -p "Select IP address [1]: " ip_choice
        ip_choice=${ip_choice:-1}
        if [[ ! $ip_choice =~ ^[0-9]+$ ]] || (( ip_choice < 1 || ip_choice > ${#available_ips[@]} )); then
            echo "Error: Invalid selection." >&2
            exit 1
        fi
        SERVER_IP="${available_ips[$((ip_choice-1))]}"
    fi
    
    # Check if behind NAT
    if [[ $SERVER_IP =~ ^(10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168) ]]; then
        echo
        echo "Server appears to be behind NAT."
        echo "Detecting public IP address..."
        
        PUBLIC_IP=$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" 2>/dev/null || \
                    curl -m 10 -4s "http://ip1.dynupdate.no-ip.com/" 2>/dev/null || \
                    echo "")
        
        if [[ -n $PUBLIC_IP ]] && validate_ip "$PUBLIC_IP"; then
            echo "Detected public IP: $PUBLIC_IP"
            read -r -p "Use this public IP? [Y/n]: " use_public
            if [[ ! "$use_public" =~ ^[nN]$ ]]; then
                SERVER_ENDPOINT="$PUBLIC_IP"
            else
                read -r -p "Enter public IP or hostname: " custom_public
                if validate_ip "$custom_public" || validate_hostname "$custom_public"; then
                    SERVER_ENDPOINT="$custom_public"
                else
                    echo "Error: Invalid IP or hostname." >&2
                    exit 1
                fi
            fi
        else
            read -r -p "Enter public IP or hostname: " SERVER_ENDPOINT
            if ! validate_ip "$SERVER_ENDPOINT" && ! validate_hostname "$SERVER_ENDPOINT"; then
                echo "Error: Invalid IP or hostname." >&2
                exit 1
            fi
        fi
    else
        SERVER_ENDPOINT="$SERVER_IP"
    fi
    
    # Get WireGuard port
    echo
    read -r -p "WireGuard listen port [51820]: " WG_PORT
    WG_PORT=${WG_PORT:-51820}
    if ! validate_port "$WG_PORT"; then
        echo "Error: Invalid port number." >&2
        exit 1
    fi
    
    # Get first client name
    echo
    echo "First client configuration:"
    read -r -p "Client name [client]: " client_name
    client_name=${client_name:-client}
    client_name=$(sanitize_client_name "$client_name")
    
    # Get DNS servers
    select_dns
    
    # Install required packages
    echo
    echo "Installing required packages..."
    
    local packages=()
    if (( use_boringtun == 0 )); then
        packages+=("wireguard" "wireguard-tools" "qrencode")
    else
        packages+=("wireguard-tools" "qrencode" "ca-certificates" "tar")
        if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
            packages+=("cron")
        elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
            packages+=("cronie")
        fi
    fi
    
    # Add firewall package if needed
    if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
        if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
            packages+=("firewalld")
        elif [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
            packages+=("iptables")
        fi
    fi
    
    install_packages "${packages[@]}"
    
    # Install BoringTun if needed
    if (( use_boringtun == 1 )); then
        echo "Installing BoringTun (userspace WireGuard)..."
        tmp_dir=$(mktemp -d)
        cd "$tmp_dir"
        wget -qO- https://wg.nyr.be/1/latest/download | tar xz --wildcards 'boringtun-*/boringtun' --strip-components=1
        mv boringtun /usr/local/sbin/boringtun
        chmod 755 /usr/local/sbin/boringtun
        cd - >/dev/null
        rm -rf "$tmp_dir"
        
        # Configure wg-quick to use BoringTun
        mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
        cat > /etc/systemd/system/wg-quick@wg0.service.d/boringtun.conf <<-EOF
[Service]
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=boringtun
Environment=WG_SUDO=1
EOF
    fi
    
    # Set secure permissions for wireguard directory
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    
    # Generate server keys with secure permissions
    (
        umask 077
        SERVER_PRIVATE_KEY=$(wg genkey)
        SERVER_PUBLIC_KEY=$(wg pubkey <<< "$SERVER_PRIVATE_KEY")
        
        # Create server configuration
        cat > /etc/wireguard/wg0.conf <<-EOF
# WireGuard server configuration
# Generated on $(date)
# ENDPOINT $SERVER_ENDPOINT

[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.7.0.1/24
ListenPort = $WG_PORT

# Logging control
# SaveConfig = $LOGGING_ENABLED
EOF

        if (( LOGGING_ENABLED == 0 )); then
            echo "SaveConfig = false" >> /etc/wireguard/wg0.conf
        fi
    )
    
    # Verify server config permissions
    chmod 600 /etc/wireguard/wg0.conf
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-forward.conf
    sysctl -p /etc/sysctl.d/99-wireguard-forward.conf >/dev/null
    
    # Configure firewall
    configure_firewall "$SERVER_IP" "$WG_PORT"
    
    # Generate first client
    client_octet=$(get_free_octet)
    client_config=$(generate_client_config "$client_name" "$client_octet")
    
    # Verify client config permissions
    verify_permissions "$client_config"
    
    # Start WireGuard
    systemctl enable --now wg-quick@wg0.service
    
    # Display client information
    echo
    echo "✓ Installation complete!"
    echo "✓ Server endpoint: $SERVER_ENDPOINT:$WG_PORT"
    echo "✓ First client: $client_name"
    echo "✓ Client configuration: $client_config"
    echo "✓ Permissions: $(stat -c "%a %n" "$client_config" 2>/dev/null || stat -f "%OLp %N" "$client_config" 2>/dev/null)"
    
    display_qr_code "$client_config"
    
    echo
    echo "To add more clients, run this script again."
    echo
    echo "⚠️  IMPORTANT: Client configuration files contain private keys!"
    echo "   Store them securely and transfer only via encrypted channels."
    echo "   Current permissions: only root can read these files."
    
else
    # Management menu for existing installation
    clear
    echo "WireGuard is already installed."
    echo
    echo "Management Options:"
    echo "  1) Add new client"
    echo "  2) Remove existing client"
    echo "  3) List all clients"
    echo "  4) Fix permissions on all client files"
    echo "  5) Uninstall WireGuard"
    echo "  6) Exit"
    echo
    read -r -p "Select option [1-6]: " menu_choice
    
    case "$menu_choice" in
        1)
            # Add new client
            echo
            echo "Add New Client"
            echo "──────────────"
            read -r -p "Client name: " client_name
            
            if [[ -z "$client_name" ]]; then
                echo "Error: Client name cannot be empty." >&2
                exit 1
            fi
            
            client_name=$(sanitize_client_name "$client_name")
            
            if grep -q "^# BEGIN_PEER $client_name$" /etc/wireguard/wg0.conf; then
                echo "Error: Client '$client_name' already exists." >&2
                exit 1
            fi
            
            # Get DNS servers for new client
            select_dns
            
            # Generate client configuration
            client_octet=$(get_free_octet)
            client_config=$(generate_client_config "$client_name" "$client_octet")
            
            # Verify permissions
            verify_permissions "$client_config"
            
            # Add to live interface
            wg addconf wg0 <(sed -n "/^# BEGIN_PEER $client_name/,/^# END_PEER $client_name/p" /etc/wireguard/wg0.conf)
            
            echo
            echo "✓ Client '$client_name' added successfully!"
            echo "✓ Configuration: $client_config"
            echo "✓ Permissions: $(stat -c "%a %n" "$client_config" 2>/dev/null || stat -f "%OLp %N" "$client_config" 2>/dev/null)"
            
            display_qr_code "$client_config"
            ;;
            
        2)
            # Remove client
            clients=($(grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3))
            
            if (( ${#clients[@]} == 0 )); then
                echo "No clients configured."
                exit 0
            fi
            
            echo
            echo "Select client to remove:"
            for i in "${!clients[@]}"; do
                echo "  $((i+1))) ${clients[i]}"
            done
            echo
            read -r -p "Client number: " client_num
            
            if [[ ! $client_num =~ ^[0-9]+$ ]] || (( client_num < 1 || client_num > ${#clients[@]} )); then
                echo "Error: Invalid selection." >&2
                exit 1
            fi
            
            client_to_remove="${clients[$((client_num-1))]}"
            
            echo
            read -r -p "Remove client '$client_to_remove'? [y/N]: " confirm
            
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                # Get peer public key
                peer_pubkey=$(sed -n "/^# BEGIN_PEER $client_to_remove$/,/^# END_PEER $client_to_remove$/p" \
                    /etc/wireguard/wg0.conf | grep '^PublicKey' | cut -d ' ' -f 3)
                
                # Remove from live interface
                wg set wg0 peer "$peer_pubkey" remove
                
                # Remove from configuration file
                sed -i "/^# BEGIN_PEER $client_to_remove$/,/^# END_PEER $client_to_remove$/d" \
                    /etc/wireguard/wg0.conf
                
                # Remove client config file securely (overwrite first)
                if [[ -f "$SCRIPT_DIR/$client_to_remove.conf" ]]; then
                    # Overwrite with random data before deletion (basic secure deletion)
                    dd if=/dev/urandom of="$SCRIPT_DIR/$client_to_remove.conf" bs=1k count=1 2>/dev/null || true
                    rm -f "$SCRIPT_DIR/$client_to_remove.conf"
                fi
                
                echo "✓ Client '$client_to_remove' removed."
            else
                echo "Removal cancelled."
            fi
            ;;
            
        3)
            # List all clients
            echo
            echo "Configured Clients"
            echo "──────────────────"
            clients=($(grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3))
            
            if (( ${#clients[@]} == 0 )); then
                echo "No clients configured."
            else
                for client in "${clients[@]}"; do
                    config_file="$SCRIPT_DIR/$client.conf"
                    if [[ -f "$config_file" ]]; then
                        perms=$(stat -c "%a" "$config_file" 2>/dev/null || stat -f "%OLp" "$config_file" 2>/dev/null)
                        echo "  • $client (permissions: $perms)"
                        if [[ "$perms" != "600" ]]; then
                            echo "    ⚠️  WARNING: Incorrect permissions!"
                        fi
                    else
                        echo "  • $client (config file missing)"
                    fi
                done
            fi
            ;;
            
        4)
            # Fix permissions
            echo
            echo "Fixing permissions on all client files..."
            
            # Fix wireguard directory
            chmod 700 /etc/wireguard
            
            # Fix server config
            if [[ -f /etc/wireguard/wg0.conf ]]; then
                chmod 600 /etc/wireguard/wg0.conf
                echo "✓ Fixed: /etc/wireguard/wg0.conf"
            fi
            
            # Fix all client configs
            for config in "$SCRIPT_DIR"/*.conf; do
                if [[ -f "$config" ]] && [[ "$config" != "/etc/wireguard/wg0.conf" ]]; then
                    chmod 600 "$config"
                    chown root:root "$config"
                    echo "✓ Fixed: $config"
                fi
            done
            
            echo "✓ Permissions fixed."
            ;;
            
        5)
            # Uninstall WireGuard
            echo
            echo "Uninstall WireGuard"
            echo "───────────────────"
            echo "This will remove WireGuard and all client configurations."
            echo
            read -r -p "Are you sure? [y/N]: " confirm
            
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                # Stop and disable services
                systemctl disable --now wg-quick@wg0.service 2>/dev/null || true
                systemctl disable --now wg-iptables.service 2>/dev/null || true
                
                # Remove firewall rules
                if systemctl is-active --quiet firewalld.service; then
                    port=$(grep '^ListenPort' /etc/wireguard/wg0.conf 2>/dev/null | cut -d ' ' -f 3)
                    if [[ -n "$port" ]]; then
                        firewall-cmd --quiet --remove-port="$port/udp" 2>/dev/null || true
                        firewall-cmd --quiet --permanent --remove-port="$port/udp" 2>/dev/null || true
                    fi
                    firewall-cmd --quiet --zone=trusted --remove-source=10.7.0.0/24 2>/dev/null || true
                    firewall-cmd --quiet --permanent --zone=trusted --remove-source=10.7.0.0/24 2>/dev/null || true
                fi
                
                # Remove systemd drop-in for BoringTun
                rm -rf /etc/systemd/system/wg-quick@wg0.service.d
                
                # Remove sysctl configuration
                rm -f /etc/sysctl.d/99-wireguard-forward.conf
                
                # Securely remove client config files
                if [[ -d "$SCRIPT_DIR" ]]; then
                    for config in "$SCRIPT_DIR"/*.conf; do
                        if [[ -f "$config" ]]; then
                            dd if=/dev/urandom of="$config" bs=1k count=1 2>/dev/null || true
                            rm -f "$config"
                        fi
                    done
                fi
                
                # Remove WireGuard files
                rm -rf /etc/wireguard
                
                # Remove BoringTun if present
                rm -f /usr/local/sbin/boringtun
                
                # Remove cron job for BoringTun updates
                crontab -l 2>/dev/null | grep -v 'boringtun-upgrade' | crontab - 2>/dev/null || true
                
                # Remove packages
                if (( use_boringtun == 0 )); then
                    case "$os" in
                        ubuntu|debian)
                            apt-get remove --purge -y wireguard wireguard-tools qrencode
                            ;;
                        centos|fedora)
                            dnf remove -y wireguard-tools qrencode
                            ;;
                    esac
                else
                    case "$os" in
                        ubuntu|debian)
                            apt-get remove --purge -y wireguard-tools qrencode
                            ;;
                        centos|fedora)
                            dnf remove -y wireguard-tools qrencode
                            ;;
                    esac
                fi
                
                echo "✓ WireGuard has been uninstalled."
            else
                echo "Uninstall cancelled."
            fi
            ;;
            
        6)
            exit 0
            ;;
            
        *)
            echo "Error: Invalid option." >&2
            exit 1
            ;;
    esac
fi
