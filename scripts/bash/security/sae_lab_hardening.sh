#!/bin/bash

# File: sae_lab_hardening.sh
# SAE Lab Server Hardening Script
# Establishes security baseline before application deployment
# Usage: ./sae_lab_hardening.sh [hostname]

set -euo pipefail

# Basic logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
}

# Check if running as non-root user
if [[ $EUID -eq 0 ]]; then
   error "Run as labrat or automation user with sudo, not root"
   exit 1
fi

HOSTNAME=${1:-$(hostname)}
log "Starting SAE Lab hardening for $HOSTNAME"

# Verify and create automation users
setup_users() {
    log "Setting up automation users..."
    
    # Create automation user if missing
    if ! id "automation" &>/dev/null; then
        sudo useradd -m -s /bin/bash automation
        log "Created automation user"
    else
        log "automation user exists"
    fi
    
    # Configure passwordless sudo for required users
    local users=("labrat" "automation")
    
    # Add ansible user only on control node
    if [[ "$HOSTNAME" == *"control"* ]]; then
        if ! id "ansible" &>/dev/null; then
            sudo useradd -m -s /bin/bash ansible
            log "Created ansible user"
        fi
        users+=("ansible")
    fi
    
    # Configure sudo for each user
    for user in "${users[@]}"; do
        if id "$user" &>/dev/null; then
            echo "$user ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$user" > /dev/null
            sudo chmod 440 "/etc/sudoers.d/$user"
            log "Configured passwordless sudo for $user"
        fi
    done
}

# Configure SSH security
configure_ssh() {
    log "Configuring SSH security..."
    
    # Backup original config
    if [[ -f /etc/ssh/sshd_config ]] && [[ ! -f /etc/ssh/sshd_config.backup ]]; then
        sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    fi
    
    # Create security configuration
    sudo tee /etc/ssh/sshd_config.d/sae-security.conf > /dev/null <<EOF
# SAE Lab Security Configuration
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
PermitEmptyPasswords no
EOF

    # Test and restart SSH
    if sudo sshd -t; then
        sudo systemctl restart sshd
        log "SSH security configured and restarted"
    else
        error "SSH configuration invalid, check syntax"
        exit 1
    fi
}

# Configure firewall
configure_firewall() {
    log "Configuring UFW firewall..."
    
    # Install and reset firewall
    sudo apt update -qq
    sudo apt install -y ufw
    sudo ufw --force reset
    
    # Set defaults
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # Always allow SSH
    sudo ufw allow ssh
    
    # Configure role-specific ports
    case "$HOSTNAME" in
        *control*)
            log "Firewall: Control node (SSH only)"
            ;;
        *git*)
            log "Firewall: Git server (HTTP/HTTPS)"
            sudo ufw allow 80/tcp
            sudo ufw allow 443/tcp
            ;;
        *docker*)
            log "Firewall: Docker server (Docker daemon)"
            sudo ufw allow 2376/tcp
            ;;
        *siem*)
            log "Firewall: SIEM server (Syslog)"
            sudo ufw allow 514/tcp
            sudo ufw allow 514/udp
            ;;
        *tgt*)
            log "Firewall: Target system (SSH only)"
            ;;
        *)
            log "Firewall: Unknown role (SSH only)"
            ;;
    esac
    
    # Enable firewall
    sudo ufw --force enable
    log "UFW firewall enabled"
}

# Install security essentials
install_security_tools() {
    log "Installing security tools..."
    
    sudo apt update -qq
    sudo apt install -y \
        fail2ban \
        unattended-upgrades \
        rsyslog
    
    # Configure fail2ban for SSH
    sudo tee /etc/fail2ban/jail.d/sae-ssh.conf > /dev/null <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF

    # Start services
    sudo systemctl enable --now fail2ban
    sudo systemctl enable --now rsyslog
    
    # Configure automatic security updates
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' | sudo tee /etc/apt/apt.conf.d/50unattended-upgrades-sae > /dev/null
    
    log "Security tools configured"
}

# Set secure file permissions
secure_files() {
    log "Setting secure file permissions..."
    
    # Critical system files
    sudo chmod 644 /etc/passwd
    sudo chmod 640 /etc/shadow
    sudo chmod 440 /etc/sudoers
    
    # SSH configuration
    sudo chmod 600 /etc/ssh/sshd_config
    
    log "File permissions secured"
}

# Update system packages
update_system() {
    log "Updating system packages..."
    
    sudo apt update -qq
    sudo apt upgrade -y
    
    log "System packages updated"
}

# Main execution
main() {
    log "=== SAE Lab Server Hardening ==="
    log "Hostname: $HOSTNAME"
    log "User: $(whoami)"
    
    setup_users
    configure_ssh
    configure_firewall
    install_security_tools
    secure_files
    update_system
    
    log "=== Hardening completed successfully ==="
    echo ""
    echo "Users configured with passwordless sudo"
    echo "SSH security hardened" 
    echo "UFW firewall enabled with role-specific rules"
    echo "fail2ban protecting SSH"
    echo "Automatic security updates enabled"
    echo "File permissions secured"
    echo ""
    echo "Next steps:"
    echo "1. Test SSH: ssh homelab-$HOSTNAME"
    echo "2. Test automation: ssh sae-$HOSTNAME" 
    echo "3. Run validation script"
}

main "$@"