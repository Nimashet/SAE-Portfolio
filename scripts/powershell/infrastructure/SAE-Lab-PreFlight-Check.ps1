# File: SAE-Lab-PreFlight-Check.ps1
# Pre-flight checklist for SAE Lab hardening deployment

<#
.SYNOPSIS
    Pre-flight checklist for SAE Lab security hardening deployment

.DESCRIPTION
    Performs connectivity and prerequisite checks before SAE Lab deployments:
    - SSH connectivity testing to all target systems
    - Verification of required scripts and dependencies
    - Basic system health checks
    - Pre-deployment validation

.PARAMETER TargetSystems
    Array of target system names for connectivity testing

.PARAMETER SkipHealthCheck
    Skip basic health checks on target systems

.EXAMPLE
    .\SAE-Lab-PreFlight-Check.ps1
    Full pre-flight check with snapshots

.EXAMPLE
    .\SAE-Lab-PreFlight-Check.ps1 -TestOnly
    Connectivity test only

.EXAMPLE
    .\SAE-Lab-PreFlight-Check.ps1 -ProxmoxHost pve1
    Specify Proxmox host for snapshots

.NOTES
    - Run from Windows desktop before deployment scripts
    - Requires SSH connectivity to target systems
    - Validates environment readiness for automation
    - Use Manage-ProxmoxSnapshots.ps1 for backup operations
    - Place in: C:\dev\sae-portfolio\scripts\powershell\infrastructure\
#>

param(
    [string[]]$TargetSystems = @("control", "git", "docker", "siem", "ub24-tgt-01", "rl9-tgt-01", "ub20-tgt-01"),
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = 'Stop'

# Remove VM mapping and snapshot-related variables
# Pre-flight focuses on connectivity testing only

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    switch ($Level) {
        "ERROR"   { Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor Red }
        "SUCCESS" { Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green }
        "WARNING" { Write-Host "[$timestamp] [WARNING] $Message" -ForegroundColor Yellow }
        "INFO"    { Write-Host "[$timestamp] [INFO] $Message" -ForegroundColor Cyan }
        default   { Write-Host "[$timestamp] $Message" }
    }
}

function Test-Prerequisites {
    Write-Status "Checking prerequisites..." "INFO"
    
    # Check SSH/SCP availability
    try {
        Get-Command ssh | Out-Null
        Get-Command scp | Out-Null
        Write-Status "SSH/SCP tools available" "SUCCESS"
    } catch {
        Write-Status "SSH/SCP not found - install OpenSSH or Git for Windows" "ERROR"
        return $false
    }
    
    # Check hardening scripts exist
    $ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $HardeningScript = Join-Path $ScriptPath "..\bash\security\sae_lab_hardening.sh"
    $ValidationScript = Join-Path $ScriptPath "..\bash\security\sae_lab_validation.sh"
    
    if (!(Test-Path $HardeningScript)) {
        Write-Status "Hardening script not found: $HardeningScript" "ERROR"
        return $false
    }
    
    if (!(Test-Path $ValidationScript)) {
        Write-Status "Validation script not found: $ValidationScript" "ERROR"
        return $false
    }
    
    Write-Status "Required scripts found" "SUCCESS"
    return $true
}

function Test-SSHConnectivity {
    Write-Status "Testing SSH connectivity to target systems..." "INFO"
    
    $failedHosts = @()
    $successfulHosts = @()
    
    foreach ($system in $TargetSystems) {
        $hostAlias = "homelab-$system"
        Write-Host "  Testing $hostAlias... " -NoNewline
        
        try {
            $result = ssh -o ConnectTimeout=10 -o BatchMode=yes $hostAlias "echo 'connection-test' && whoami" 2>$null
            if ($result -like "*connection-test*") {
                Write-Host "SUCCESS" -ForegroundColor Green
                $successfulHosts += $system
            } else {
                Write-Host "FAILED" -ForegroundColor Red
                $failedHosts += $system
            }
        } catch {
            Write-Host "FAILED" -ForegroundColor Red
            $failedHosts += $system
        }
    }
    
    Write-Status "SSH connectivity results:" "INFO"
    Write-Status "  Successful: $($successfulHosts.Count)/$($TargetSystems.Count) systems" "SUCCESS"
    
    if ($failedHosts.Count -gt 0) {
        Write-Status "  Failed connections: $($failedHosts -join ', ')" "WARNING"
        Write-Status "Troubleshooting failed connections:" "INFO"
        Write-Host "    1. Verify SSH keys deployed: ssh-copy-id automation@<ip>"
        Write-Host "    2. Test manual connection: ssh homelab-<system>"
        Write-Host "    3. Check SSH service: systemctl status sshd"
        Write-Host "    4. Verify firewall allows SSH"
        return $false
    }
    
    return $true
}

# Remove Proxmox connectivity and snapshot functions
# Use Manage-ProxmoxSnapshots.ps1 for backup operations

function Get-SystemHealthCheck {
    if ($SkipHealthCheck) {
        Write-Status "Health check skipped" "INFO"
        return
    }
    
    Write-Status "Performing basic system health checks..." "INFO"
    
    $healthIssues = @()
    
    foreach ($system in $TargetSystems) {
        $hostAlias = "homelab-$system"
        Write-Host "  Checking $system... " -NoNewline
        
        try {
            # Check disk space
            $diskSpace = ssh $hostAlias "df / | tail -1 | awk '{print \$5}' | sed 's/%//'" 2>$null
            if ([int]$diskSpace -gt 90) {
                $healthIssues += "$system`: Disk usage ${diskSpace}% (high)"
            }
            
            # Check if system needs reboot
            $rebootRequired = ssh $hostAlias "test -f /var/run/reboot-required && echo 'yes' || echo 'no'" 2>$null
            if ($rebootRequired -eq "yes") {
                $healthIssues += "$system`: Reboot required"
            }
            
            Write-Host "OK" -ForegroundColor Green
        } catch {
            Write-Host "FAILED" -ForegroundColor Red
            $healthIssues += "$system`: Health check failed"
        }
    }
    
    if ($healthIssues.Count -gt 0) {
        Write-Status "Health check issues found:" "WARNING"
        foreach ($issue in $healthIssues) {
            Write-Host "    - $issue" -ForegroundColor Yellow
        }
    } else {
        Write-Status "All systems passed health checks" "SUCCESS"
    }
}

function Show-PreFlightSummary {
    Write-Status "=== PRE-FLIGHT CHECK SUMMARY ===" "INFO"
    Write-Host ""
    Write-Host "Target Systems: $($TargetSystems -join ', ')"
    Write-Host "Timestamp: $(Get-Date)"
    Write-Host ""
    
    Write-Status "CONNECTIVITY VERIFIED: Ready for deployment" "SUCCESS"
    
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "1. Create snapshots: .\Manage-ProxmoxSnapshots.ps1 -Action Create -VMGroup Linux"
    Write-Host "2. Run deployment: .\Deploy-SecurityHardening.ps1"
    Write-Host "3. If issues occur, restore from snapshots"
    Write-Host ""
}

# Main execution
Write-Host "SAE Lab Pre-Flight Check" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

# Run all checks
$allChecksPass = $true

$allChecksPass = Test-Prerequisites -and $allChecksPass
$allChecksPass = Test-SSHConnectivity -and $allChecksPass

if ($allChecksPass) {
    Get-SystemHealthCheck
    Show-PreFlightSummary
    
    Write-Status "PRE-FLIGHT CHECK COMPLETED SUCCESSFULLY" "SUCCESS"
    exit 0
} else {
    Write-Status "PRE-FLIGHT CHECK FAILED - DO NOT PROCEED" "ERROR"
    Write-Host "Fix the issues above before running deployment scripts"
    exit 1
}