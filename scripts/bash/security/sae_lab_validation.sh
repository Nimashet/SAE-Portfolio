#!/bin/bash

# File: sae_lab_validation.sh
# SAE Lab Hardening Validation Script
# Validates security baseline configuration
# Usage: ./sae_lab_validation.sh [hostname]

set -euo pipefail

HOSTNAME=${1:-$(hostname)}
PASSED=0
FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test function
test_check() {
    local description="$1"
    local command="$2"
    local expected="$3"
    
    echo -n "Checking $description... "
    
    if result=$(eval "$command" 2>/dev/null); then
        if [[ "$result" == "$expected" ]] || [[ "$result" == *"$expected"* ]]; then
            echo -e "${GREEN}PASS${NC}"
            ((PASSED++))
            return 0
        fi
    fi
    
    echo -e "${RED}FAIL${NC}"
    ((FAILED++))
    return 1
}

# Validate users and sudo configuration
validate_users() {
    echo -e "\n=== User Configuration ==="
    
    # Check required users exist
    test_check "labrat user exists" "id labrat" "labrat"
    test_check "automation user exists" "id automation" "automation"
    
    # Check ansible user on control node
    if [[ "$HOSTNAME" == *"control"* ]]; then
        test_check "ansible user exists" "id ansible" "ansible"
    fi
    
    # Check sudo configuration
    test_check "labrat passwordless sudo" "sudo -l -U labrat | grep NOPASSWD" "NOPASSWD"
    test_check "automation passwordless sudo" "sudo -l -U automation | grep NOPASSWD" "NOPASSWD"
    
    if [[ "$HOSTNAME" == *"control"* ]]; then
        test_check "ansible passwordless sudo" "sudo -l -U ansible | grep NOPASSWD" "NOPASSWD"
    fi
}

# Validate SSH security
validate_ssh() {
    echo -e "\n=== SSH Security ==="
    
    test_check "SSH PasswordAuthentication disabled" \
        "sudo sshd -T | grep '^passwordauthentication'" \
        "passwordauthentication no"
    
    test_check "SSH PermitRootLogin disabled" \
        "sudo sshd -T | grep '^permitrootlogin'" \
        "permitrootlogin no"
    
    test_check "SSH PubkeyAuthentication enabled" \
        "sudo sshd -T | grep '^pubkeyauthentication'" \
        "pubkeyauthentication yes"
    
    test_check "SSH MaxAuthTries set to 3" \
        "sudo sshd -T | grep '^maxauthtries'" \
        "maxauthtries 3"
    
    test_check "SSH service running" \
        "systemctl is-active sshd" \
        "active"
}

# Validate firewall
validate_firewall() {
    echo -e "\n=== Firewall Configuration ==="
    
    test_check "UFW firewall active" \
        "sudo ufw status | head -1" \
        "Status: active"
    
    test_check "UFW default deny incoming" \
        "sudo ufw status verbose | grep 'Default:.*incoming'" \
        "deny"
    
    test_check "SSH allowed" \
        "sudo ufw status | grep -E '22/tcp|SSH'" \
        "ALLOW"
    
    # Role-specific port checks
    case "$HOSTNAME" in
        *git*)
            test_check "HTTP port allowed" "sudo ufw status | grep '80/tcp'" "ALLOW"
            test_check "HTTPS port allowed" "sudo ufw status | grep '443/tcp'" "ALLOW"
            ;;
        *docker*)
            test_check "Docker daemon port allowed" "sudo ufw status | grep '2376/tcp'" "ALLOW"
            ;;
        *siem*)
            test_check "Syslog TCP allowed" "sudo ufw status | grep '514/tcp'" "ALLOW"
            test_check "Syslog UDP allowed" "sudo ufw status | grep '514/udp'" "ALLOW"
            ;;
    esac
}

# Validate security tools
validate_security_tools() {
    echo -e "\n=== Security Tools ==="
    
    test_check "fail2ban service running" \
        "systemctl is-active fail2ban" \
        "active"
    
    test_check "fail2ban service enabled" \
        "systemctl is-enabled fail2ban" \
        "enabled"
    
    test_check "fail2ban SSH jail configured" \
        "test -f /etc/fail2ban/jail.d/sae-ssh.conf && echo configured" \
        "configured"
    
    test_check "rsyslog service running" \
        "systemctl is-active rsyslog" \
        "active"
    
    test_check "unattended-upgrades installed" \
        "dpkg -l | grep unattended-upgrades" \
        "unattended-upgrades"
}

# Validate file permissions
validate_permissions() {
    echo -e "\n=== File Permissions ==="
    
    test_check "/etc/passwd permissions" \
        "stat -c '%a' /etc/passwd" \
        "644"
    
    test_check "/etc/shadow permissions" \
        "stat -c '%a' /etc/shadow" \
        "640"
    
    test_check "/etc/sudoers permissions" \
        "stat -c '%a' /etc/sudoers" \
        "440"
    
    test_check "/etc/ssh/sshd_config permissions" \
        "stat -c '%a' /etc/ssh/sshd_config" \
        "600"
}

# Validate network security
validate_network() {
    echo -e "\n=== Network Security ==="
    
    test_check "SSH port listening" \
        "netstat -tuln | grep ':22' | wc -l" \
        "1"
    
    test_check "No telnet port listening" \
        "netstat -tuln | grep ':23' | wc -l" \
        "0"
    
    test_check "No FTP port listening" \
        "netstat -tuln | grep ':21' | wc -l" \
        "0"
}

# Generate summary report
generate_summary() {
    local total=$((PASSED + FAILED))
    local success_rate=$((PASSED * 100 / total))
    
    echo -e "\n=== VALIDATION SUMMARY ==="
    echo "Hostname: $HOSTNAME"
    echo "Date: $(date)"
    echo "Total Checks: $total"
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo "Success Rate: $success_rate%"
    
    if [[ $FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}ALL SECURITY CHECKS PASSED${NC}"
        echo -e "${GREEN}Server $HOSTNAME meets SAE Lab security baseline${NC}"
        exit 0
    else
        echo -e "\n${YELLOW}SOME CHECKS FAILED${NC}"
        echo -e "${YELLOW}Review failed checks and re-run hardening if needed${NC}"
        exit 1
    fi
}

# Main execution
main() {
    echo "SAE Lab Security Validation"
    echo "Server: $HOSTNAME"
    echo "Started: $(date)"
    
    validate_users
    validate_ssh
    validate_firewall
    validate_security_tools
    validate_permissions
    validate_network
    
    generate_summary
}

main "$@"