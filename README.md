# 🔒 WireGuard Road Warrior Installer

Modernized version with privacy-focused logging control.
Secure, fast, and easy-to-use VPN setup for modern Linux distributions.

---

## 📋 Table of Contents
- [Features](#-features)
- [Quick Start](#-quick-start)
- [Requirements](#-requirements)
- [Usage](#-usage)
- [Security Features](#-security-features)
- [Management Options](#-management-options)
- [Technical Details](#-technical-details)
- [Troubleshooting](#-troubleshooting)

---

## 🎯 Features

* **Privacy-First Logging**: Choose to keep logs or disable completely (`SaveConfig=false`) for maximum privacy.
* **Secure File Permissions**: All configuration files are automatically set to `600` (root-only access).
* **SCP Integration**: Provides ready-to-use download commands after client creation.
* **QR Code Generation**: Instant mobile-friendly configuration using ANSI QR codes in the terminal.
* **Container Support**: Includes BoringTun fallback for LXC/OpenVZ/Docker environments.
* **Cross-Platform**: Supports Ubuntu ≥22.04, Debian ≥11, AlmaLinux/Rocky/CentOS ≥9, and Fedora.
* **Easy Management**: Simple menu to add/remove clients, fix permissions, or uninstall.

---

## 🚀 Quick Start

# Download and run the installer
curl -O https://raw.githubusercontent.com/ERM073/wireguard-easy/refs/heads/main/wireguard-install.sh
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh

---

## ⚙️ Requirements

* **Root privileges** (sudo access)
* **Supported Linux distribution** (Debian/RHEL families)
* **IPv4 connectivity** (Public IP recommended)
* **TUN device support** (Required for containerized environments)

---

## 📖 Usage

### First-Time Installation
The script guides you through a step-by-step setup:
1.  **Logging preference**: Enable or disable connection logging.
2.  **Server IP selection**: Choose from available network interfaces.
3.  **NAT handling**: Automatic public IP detection (or manual override).
4.  **Port configuration**: Default WireGuard port is `51820`.
5.  **DNS selection**: Choose from Google, Cloudflare, Quad9, AdGuard, or Custom DNS.
6.  **Client setup**: Automatic creation of the first client.

### Example Output
✓ Installation complete!
✓ Server endpoint: your-server.com:51820
✓ First client: client1
✓ Client configuration: /etc/wireguard/clients/client1.conf
✓ Permissions: 600

📥 To download this configuration to your local machine:
   scp -P 22 root@your-server.com:/etc/wireguard/clients/client1.conf ./

---

## 🔒 Security Features

### Privacy Controls
* **Option 1 (Default)**: Keep logs (Standard WireGuard behavior).
* **Option 2 (Privacy)**: Disable logging. Prevents runtime changes from being written back to disk, keeping your config "read-only" and clean.

### File Security
* **Permission Enforcement**: All sensitive files (`.conf`, private keys) use `600` permissions.
* **Sanitization**: Client names are sanitized to prevent directory traversal or injection.
* **Secure Deletion**: Configurations are overwritten/revoked before being removed.

---

## 🛠️ Management Options

After installation, run the script again to access the management menu:
1.  **Add New Client**: Generate unique keys and IPs for additional devices.
2.  **Remove Existing Client**: Revoke access and clean up config files.
3.  **List All Clients**: View current active peers and their status.
4.  **Fix Permissions**: Emergency repair for file security settings.
5.  **Uninstall WireGuard**: Complete removal of the service, configs, and firewall rules.

---

## 🔧 Technical Details

### Network Configuration
* **Server Subnet**: `10.7.0.1/24` (IPv4) / `fd42:42:42::1/64` (IPv6)
* **Client Range**: `10.7.0.2` to `10.7.0.254`
* **Routing**: Full tunnel (`0.0.0.0/0`, `::/0`) by default.

### Supported DNS Providers
* System Default / Google / Cloudflare / OpenDNS / Quad9 / Gcore / AdGuard / Custom

---

## 🐛 Troubleshooting

### Common Issues
* **Permission Errors**: Ensure you use `sudo` or a root shell (`su -`).
* **Container Limitations**: If using LXC, ensure `/dev/net/tun` is accessible.
* **Firewall Conflicts**: The script manages `iptables` rules, but ensure your cloud provider's security group allows UDP `51820`.

### Verification
# Check service status
sudo systemctl status wg-quick@wg0

# Show active peers and data usage
sudo wg show

---

## ❓ FAQ

**Q: Can I change logging after installation?** A: Yes. Edit `/etc/wireguard/wg0.conf` and change `SaveConfig` to `true` or `false`.

**Q: How many clients can I have?** A: The default subnet supports up to 253 clients.

**Q: Is IPv6 supported?** A: The configuration includes IPv6 routing, though the setup focuses on IPv4 primary connectivity.

---

## 📄 License
MIT License - See LICENSE file for details.

⚠️ **Security Note**: Client `.conf` files contain private keys. Never share them publicly and transfer them only over encrypted channels (like SCP/SFTP).
