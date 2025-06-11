#!/bin/bash

# SAE Lab Hardening Validation Script
# Verifies that security hardening has been properly applied
# Usage: ./sae_lab_validation.sh [hostname]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Validation results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

HOSTNAME=${1:-$(hostname)}
VALIDATION_LOG="/tmp/sae_validation_${HOSTNAME}_$(date +%Y%m%d-%H%M%S).log"

# Function to perform a validation check
validate_check() {
    local check_name="$1"
    local check_command="$2"
    local expected_result="$3"
    local check_type="${4:-exact}"  # exact, contains, not_empty
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    echo -n "Checking ${check_name}... "
    
    # Execute the check command and capture result
    local result
    if result=$(eval "${check_command}" 2>/dev/null); then
        local validation_passed=false
        
        case "${check_type}" in
            "exact")
                [[ "${result}" == "${expected_result}" ]] && validation_passed=true
                ;;
            "contains")
                [[ "${result}" == *"${expected_result}"* ]] && validation_passed=true
                ;;
            "not_empty")
                [[ -n "${result}" ]] && validation_passed=true
                ;;
            "not_contains")
                [[ "${result}" != *"${expected_result}"* ]] && validation_passed=true
                ;;
        esac
        
        if [[ "${validation_passed}" == true ]]; then
            echo -e "${GREEN}PASS${NC}"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
            echo "[PASS] ${check_name}: ${result}" >> "${VALIDATION_LOG}"
        else
            echo -e "${RED}FAIL${NC}"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            echo "[FAIL] ${check_name}: Expected '${expected_result}', got '${result}'" >> "${VALIDATION_LOG}"
        fi
    else
        echo -e "${RED}ERROR${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        echo "[ERROR] ${check_name}: Command failed" >> "${VALIDATION_LOG}"
    fi
}

# Function to validate SSH security configuration
validate_ssh_security() {
    echo -e "\n${BLUE}=== SSH Security Validation ===${NC}"
    
    validate_check "SSH PasswordAuthentication disabled" \
        "sudo sshd -T | grep '^passwordauthentication' | awk '{print \$2}'" \
        "no" \
        "exact"
    
    validate_check "SSH PermitRootLogin disabled" \
        "sudo sshd -T | grep '^permitrootlogin' | awk '{print \$2}'" \
        "no" \
        "exact"
    
    validate_check "SSH PubkeyAuthentication enabled" \
        "sudo sshd -T | grep '^pubkeyauthentication' | awk '{print \$2}'" \
        "yes" \
        "exact"
    
    validate_check "SSH MaxAuthTries set to 3" \
        "sudo sshd -T | grep '^maxauthtries' | awk '{print \$2}'" \
        "3" \
        "exact"
    
    validate_check "SSH X11Forwarding disabled" \
        "sudo sshd -T | grep '^x11forwarding' | awk '{print \$2}'" \
        "no" \
        "exact"
    
    validate_check "SSH service running" \
        "systemctl is-active sshd" \
        "active" \
        "exact"
}

# Function to validate fail2ban configuration
validate_fail2ban() {
    echo -e "\n${BLUE}=== fail2ban Validation ===${NC}"
    
    validate_check "fail2ban service running" \
        "systemctl is-active fail2ban" \
        "active" \
        "exact"
    
    validate_check "fail2ban service enabled" \
        "systemctl is-enabled fail2ban" \
        "enabled" \
        "exact"
    
    validate_check "fail2ban sshd jail active" \
        "sudo fail2ban-client status sshd | grep 'Status for the jail: sshd' | awk '{print \$6}'" \
        "active" \
        "contains"
    
    validate_check "fail2ban configuration file exists" \
        "test -f /etc/fail2ban/jail.d/sae-ssh.conf && echo 'exists'" \
        "exists" \
        "exact"
}

# Function to validate UFW firewall
validate_firewall() {
    echo -e "\n${BLUE}=== UFW Firewall Validation ===${NC}"
    
    validate_check "UFW firewall active" \
        "sudo ufw status | head -1 | awk '{print \$2}'" \
        "active" \
        "exact"
    
    validate_check "UFW default incoming deny" \
        "sudo ufw status verbose | grep 'Default:' | grep 'incoming' | awk '{print \$2}'" \
        "deny" \
        "exact"
    
    validate_check "UFW default outgoing allow" \
        "sudo ufw status verbose | grep 'Default:' | grep 'outgoing' | awk '{print \$2}'" \
        "allow" \
        "exact"
    
    validate_check "SSH allowed through firewall" \
        "sudo ufw status | grep -E '22/tcp|SSH'" \
        "ALLOW" \
        "contains"
}

# Function to validate system logging
validate_logging() {
    echo -e "\n${BLUE}=== System Logging Validation ===${NC}"
    
    validate_check "rsyslog service running" \
        "systemctl is-active rsyslog" \
        "active" \
        "exact"
    
    validate_check "rsyslog service enabled" \
        "systemctl is-enabled rsyslog" \
        "enabled" \
        "exact"
    
    validate_check "auth.log exists and recent" \
        "test -f /var/log/auth.log && find /var/log/auth.log -mtime -1 | wc -l" \
        "1" \
        "exact"
    
    validate_check "SAE logrotate configuration exists" \
        "test -f /etc/logrotate.d/sae-security && echo 'exists'" \
        "exists" \
        "exact"
}

# Function to validate file permissions
validate_file_permissions() {
    echo -e "\n${BLUE}=== File Permissions Validation ===${NC}"
    
    validate_check "/etc/passwd permissions" \
        "stat -c '%a' /etc/passwd" \
        "644" \
        "exact"
    
    validate_check "/etc/shadow permissions" \
        "stat -c '%a' /etc/shadow" \
        "640" \
        "exact"
    
    validate_check "/etc/sudoers permissions" \
        "stat -c '%a' /etc/sudoers" \
        "440" \
        "exact"
    
    validate_check "/etc/ssh/sshd_config permissions" \
        "stat -c '%a' /etc/ssh/sshd_config" \
        "600" \
        "exact"
}

# Function to validate sudo configuration
validate_sudo_config() {
    echo -e "\n${BLUE}=== Sudo Configuration Validation ===${NC}"
    
    # Check labrat passwordless sudo
    if id "labrat" &>/dev/null; then
        validate_check "labrat passwordless sudo configured" \
            "test -f /etc/sudoers.d/labrat && echo 'configured'" \
            "configured" \
            "exact"
    fi
    
    # Check automation accounts based on hostname
    case "${HOSTNAME}" in
        *control*)
            if id "ansible" &>/dev/null; then
                validate_check "ansible passwordless sudo configured" \
                    "test -f /etc/sudoers.d/ansible && echo 'configured'" \
                    "configured" \
                    "exact"
            fi
            ;;
        *)
            if id "automation" &>/dev/null; then
                validate_check "automation passwordless sudo configured" \
                    "test -f /etc/sudoers.d/automation && echo 'configured'" \
                    "configured" \
                    "exact"
            fi
            ;;
    esac
}

# Function to validate security tools installation
validate_security_tools() {
    echo -e "\n${BLUE}=== Security Tools Validation ===${NC}"
    
    local security_tools=("aide" "chkrootkit" "rkhunter" "lynis" "unattended-upgrades")
    
    for tool in "${security_tools[@]}"; do
        validate_check "${tool} installed" \
            "dpkg -l | grep -E '^ii.*${tool}' | wc -l" \
            "1" \
            "exact"
    done
    
    validate_check "unattended-upgrades configured" \
        "test -f /etc/apt/apt.conf.d/20auto-upgrades && echo 'configured'" \
        "configured" \
        "exact"
}

# Function to validate unnecessary services are disabled
validate_disabled_services() {
    echo -e "\n${BLUE}=== Disabled Services Validation ===${NC}"
    
    local unnecessary_services=("telnet" "ftp" "rsh-server" "finger")
    
    for service in "${unnecessary_services[@]}"; do
        # Check if service exists and is disabled
        if systemctl list-unit-files | grep -q "${service}"; then
            validate_check "${service} service disabled" \
                "systemctl is-enabled ${service} 2>/dev/null || echo 'disabled'" \
                "disabled" \
                "contains"
        fi
    done
}

# Function to perform network security validation
validate_network_security() {
    echo -e "\n${BLUE}=== Network Security Validation ===${NC}"
    
    validate_check "No unnecessary ports listening" \
        "netstat -tuln | grep -E ':23|:21|:513|:514|:79' | wc -l" \
        "0" \
        "exact"
    
    validate_check "SSH port 22 listening" \
        "netstat -tuln | grep ':22' | wc -l" \
        "1" \
        "exact"
    
    # Role-specific port validation
    case "${HOSTNAME}" in
        *git*)
            validate_check "GitLab HTTP port accessible" \
                "netstat -tuln | grep ':80' | wc -l" \
                "1" \
                "exact"
            ;;
        *docker*)
            validate_check "Docker daemon port accessible" \
                "netstat -tuln | grep ':2376' | wc -l" \
                "1" \
                "exact"
            ;;
    esac
}

# Function to generate validation report
generate_report() {
    echo -e "\n${BLUE}=== VALIDATION REPORT ===${NC}"
    echo "Hostname: ${HOSTNAME}"
    echo "Date: $(date)"
    echo "Total Checks: ${TOTAL_CHECKS}"
    echo -e "Passed: ${GREEN}${PASSED_CHECKS}${NC}"
    echo -e "Failed: ${RED}${FAILED_CHECKS}${NC}"
    
    local success_rate=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))
    echo "Success Rate: ${success_rate}%"
    
    if [[ ${FAILED_CHECKS} -eq 0 ]]; then
        echo -e "\n${GREEN}✅ ALL SECURITY HARDENING CHECKS PASSED${NC}"
        echo -e "${GREEN}Server ${HOSTNAME} is properly hardened according to SAE Lab standards${NC}"
    else
        echo -e "\n${YELLOW}⚠️  SOME CHECKS FAILED${NC}"
        echo -e "${YELLOW}Review the validation log for details: ${VALIDATION_LOG}${NC}"
        echo -e "${YELLOW}Failed checks may indicate incomplete hardening${NC}"
    fi
    
    echo -e "\nDetailed log saved to: ${VALIDATION_LOG}"
}

# Main execution
main() {
    echo -e "${BLUE}SAE Lab Security Hardening Validation${NC}"
    echo "Validating server: ${HOSTNAME}"
    echo "Starting validation at: $(date)"
    echo "Log file: ${VALIDATION_LOG}"
    
    # Initialize log file
    echo "SAE Lab Security Validation Report" > "${VALIDATION_LOG}"
    echo "Server: ${HOSTNAME}" >> "${VALIDATION_LOG}"
    echo "Date: $(date)" >> "${VALIDATION_LOG}"
    echo "======================================" >> "${VALIDATION_LOG}"
    
    # Execute validation functions
    validate_ssh_security
    validate_fail2ban
    validate_firewall
    validate_logging
    validate_file_permissions
    validate_sudo_config
    validate_security_tools
    validate_disabled_services
    validate_network_security
    
    # Generate final report
    generate_report
}

# Execute main function
main "$@"