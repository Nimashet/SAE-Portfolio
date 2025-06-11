#!/bin/bash

# SAE Lab Server Hardening Script
# Based on SAE Lab VM Setup SOP
# Usage: ./sae_lab_hardening.sh [hostname]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/sae_hardening.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_message() {
    echo -e "${GREEN}[${TIMESTAMP}]${NC} $1"
    echo "[${TIMESTAMP}] $1" | sudo tee -a "${LOG_FILE}" > /dev/null
}

error_message() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[${TIMESTAMP}] ERROR: $1" | sudo tee -a "${LOG_FILE}" > /dev/null
}

warning_message() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[${TIMESTAMP}] WARNING: $1" | sudo tee -a "${LOG_FILE}" > /dev/null
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   error_message "This script should not be run as root. Run as labrat or automation user with sudo."
   exit 1
fi

HOSTNAME=${1:-$(hostname)}
log_message "Starting SAE Lab hardening for ${HOSTNAME}"

# Function to backup configuration files
backup_config() {
    local config_file=$1
    if [[ -f "${config_file}" ]]; then
        sudo cp "${config_file}" "${config_file}.backup.$(date +%Y%m%d-%H%M%S)" 
        log_message "Backed up ${config_file}"
    fi
}

# Function to configure SSH security
configure_ssh_security() {
    log_message "Configuring SSH security settings..."
    
    # Backup original SSH config
    backup_config "/etc/ssh/sshd_config"
    
    # Create SSH security configuration
    sudo tee /etc/ssh/sshd_config.d/sae-security.conf > /dev/null <<EOF
# SAE Lab Security Configuration
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
Protocol 2
EOF

    # Test SSH configuration
    if sudo sshd -t; then
        log_message "SSH configuration syntax is valid"
        sudo systemctl restart sshd
        log_message "SSH service restarted with new configuration"
    else
        error_message "SSH configuration has syntax errors. Restoring backup."
        sudo cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
        exit 1
    fi
}

# Function to install and configure fail2ban
configure_fail2ban() {
    log_message "Installing and configuring fail2ban..."
    
    # Install fail2ban
    sudo apt update
    sudo apt install -y fail2ban
    
    # Create fail2ban jail configuration for SSH
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

    # Start and enable fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    log_message "fail2ban configured and started"
}

# Function to configure UFW firewall
configure_firewall() {
    log_message "Configuring UFW firewall..."
    
    # Install ufw if not present
    sudo apt install -y ufw
    
    # Reset UFW to defaults
    sudo ufw --force reset
    
    # Set default policies
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # Allow SSH (critical - don't lock ourselves out)
    sudo ufw allow ssh
    
    # Allow specific services based on server role
    case "${HOSTNAME}" in
        *control*)
            log_message "Configuring firewall for control node"
            # Control node may need additional ports for Ansible
            ;;
        *git*)
            log_message "Configuring firewall for git server"
            sudo ufw allow 80/tcp   # HTTP for GitLab
            sudo ufw allow 443/tcp  # HTTPS for GitLab
            ;;
        *docker*)
            log_message "Configuring firewall for docker server"
            sudo ufw allow 2376/tcp # Docker daemon (secure)
            ;;
        *siem*)
            log_message "Configuring firewall for SIEM server"
            sudo ufw allow 514/tcp  # Syslog
            sudo ufw allow 514/udp  # Syslog UDP
            ;;
        *)
            log_message "Configuring firewall for target system"
            # Target systems: minimal ports only
            ;;
    esac
    
    # Enable firewall
    sudo ufw --force enable
    log_message "UFW firewall configured and enabled"
}

# Function to configure system logging
configure_logging() {
    log_message "Configuring system logging..."
    
    # Install rsyslog if not present
    sudo apt install -y rsyslog
    
    # Enable and start rsyslog
    sudo systemctl enable rsyslog
    sudo systemctl start rsyslog
    
    # Configure log rotation for security logs
    sudo tee /etc/logrotate.d/sae-security > /dev/null <<EOF
/var/log/auth.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 syslog adm
}

/var/log/sae_hardening.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF

    log_message "System logging configured"
}

# Function to apply additional security hardening
apply_additional_hardening() {
    log_message "Applying additional security hardening..."
    
    # Disable unnecessary services
    local unnecessary_services=("telnet" "ftp" "rsh-server" "finger")
    for service in "${unnecessary_services[@]}"; do
        if systemctl is-enabled "${service}" 2>/dev/null; then
            sudo systemctl disable "${service}"
            sudo systemctl stop "${service}"
            log_message "Disabled unnecessary service: ${service}"
        fi
    done
    
    # Set secure file permissions on critical files
    local critical_files=(
        "/etc/passwd:644:root:root"
        "/etc/shadow:640:root:shadow"
        "/etc/sudoers:440:root:root"
        "/etc/ssh/sshd_config:600:root:root"
    )
    
    for file_spec in "${critical_files[@]}"; do
        IFS=':' read -r file_path perms owner group <<< "${file_spec}"
        if [[ -f "${file_path}" ]]; then
            sudo chmod "${perms}" "${file_path}"
            sudo chown "${owner}:${group}" "${file_path}"
            log_message "Set permissions ${perms} ${owner}:${group} on ${file_path}"
        fi
    done
    
    # Update system packages
    log_message "Updating system packages..."
    sudo apt update
    sudo apt upgrade -y
    
    # Install additional security tools
    sudo apt install -y \
        aide \
        chkrootkit \
        rkhunter \
        lynis \
        unattended-upgrades
    
    # Configure automatic security updates
    sudo dpkg-reconfigure -plow unattended-upgrades
    
    log_message "Additional security hardening applied"
}

# Function to configure passwordless sudo for automation accounts
configure_automation_sudo() {
    log_message "Configuring passwordless sudo for automation accounts..."
    
    # Configure based on hostname/server type
    case "${HOSTNAME}" in
        *control*)
            if id "ansible" &>/dev/null; then
                echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ansible > /dev/null
                log_message "Configured passwordless sudo for ansible user"
            fi
            ;;
        *)
            if id "automation" &>/dev/null; then
                echo "automation ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/automation > /dev/null
                log_message "Configured passwordless sudo for automation user"
            fi
            ;;
    esac
    
    # Ensure labrat user has passwordless sudo (for manual administration)
    if id "labrat" &>/dev/null; then
        echo "labrat ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/labrat > /dev/null
        log_message "Configured passwordless sudo for labrat user"
    fi
}

# Main execution flow
main() {
    log_message "=== Starting SAE Lab Server Hardening ==="
    log_message "Hostname: ${HOSTNAME}"
    log_message "User: $(whoami)"
    log_message "Date: $(date)"
    
    # Execute hardening steps
    configure_ssh_security
    configure_fail2ban
    configure_firewall
    configure_logging
    apply_additional_hardening
    configure_automation_sudo
    
    # Final status
    log_message "=== SAE Lab Server Hardening Completed Successfully ==="
    log_message "Hardening log saved to: ${LOG_FILE}"
    
    # Display summary
    echo ""
    echo -e "${GREEN}=== HARDENING SUMMARY ===${NC}"
    echo "✅ SSH security configured"
    echo "✅ fail2ban installed and configured"
    echo "✅ UFW firewall enabled"
    echo "✅ System logging configured"
    echo "✅ Additional security hardening applied"
    echo "✅ Automation sudo configured"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Test SSH connections: ssh homelab-${HOSTNAME}"
    echo "2. Verify automation access: ssh sae-${HOSTNAME}"
    echo "3. Run validation script to confirm hardening"
    echo "4. Review log file: ${LOG_FILE}"
}

# Execute main function
main "$@"