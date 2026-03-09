# 🔒 Secure & Anonymous WireGuard Installer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%20|%20Debian%20|%20CentOS%20|%20Fedora-blue)](https://github.com/yourusername/wireguard-secure-installer)
[![Security](https://img.shields.io/badge/security-600%20permissions-brightgreen)](https://github.com/yourusername/wireguard-secure-installer)

**Ultra-secure, privacy-focused WireGuard installer with mandatory logging control and strict file permissions.**  
No telemetry, no tracking, no connection logs (optional). Just pure VPN with maximum security defaults.

---

## 📋 Table of Contents
- [Key Features](#-key-features)
- [Quick Install](#-quick-install)
- [Requirements](#-requirements)
- [Usage](#-usage)
- [Security Features](#-security-features)
- [Comparison](#-comparison)
- [Output Files](#-output-files)
- [Manual Configuration](#-manual-configuration)
- [Security Best Practices](#-security-best-practices)
- [Troubleshooting](#-troubleshooting)
- [FAQ](#-faq)
- [License](#-license)

---

## 🎯 Key Features

| Feature | Description |
|---------|-------------|
| **🚫 Mandatory Logging Control** | Choose at install: keep logs (default) or **COMPLETELY disable all connection logging** (`SaveConfig=false`) |
| **🔐 Maximum Security** | All config files forced to `600` (root-only access), private keys never exposed to other users |
| **📱 QR Code Support** | Generate ANSI QR codes for mobile clients (iOS/Android) - scan and connect instantly |
| **🌍 Universal Compatibility** | Works on Ubuntu 22.04+, Debian 11+, CentOS 9+, AlmaLinux, Rocky Linux, Fedora 36+ |
| **🛡️ Container Support** | Auto-detects containers (LXC/Docker), falls back to BoringTun if kernel module missing |
| **🔧 Easy Management** | Interactive menu for add/remove clients, fix permissions, secure uninstall with data overwrite |
| **✅ Input Validation** | All inputs sanitized - no command injection, no path traversal vulnerabilities |
| **🔄 Secure Deletion** | Config files overwritten with random data before removal (basic secure deletion) |

---

## 🚀 Quick Install

```bash
# Method 1: Download and run (recommended)
curl -O https://raw.githubusercontent.com/ERM073/wireguard-easy/refs/heads/main/wireguard-install.sh
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh

# Method 2: Direct pipe (only from trusted sources!)
curl -sS https://raw.githubusercontent.com/ERM073/wireguard-easy/refs/heads/main/wireguard-install.sh | sudo bash

# Method 3: Clone repository
git clone https://github.com/ERM073/wireguard-easy.git
cd wireguard-easy
sudo ./wireguard-install.sh
