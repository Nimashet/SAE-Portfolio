# File: SAE-Lab-PreFlight-Check.ps1
# Pre-flight checklist for SAE Lab hardening deployment

<#
.SYNOPSIS
    Pre-flight checklist for SAE Lab security hardening deployment

.DESCRIPTION
    Performs comprehensive pre-deployment checks:
    - SSH connectivity testing to all target systems
    - Proxmox snapshot creation for rollback capability
    - Verification of required scripts and dependencies
    - System health checks before hardening

.PARAMETER TargetSystems
    Array of target system names (matches Deploy-SecurityHardening.ps1)

.PARAMETER ProxmoxHost
    Proxmox host IP address for snapshot management

.PARAMETER ProxmoxUser
    Proxmox username for SSH access (default: root)

.PARAMETER SkipSnapshots
    Skip automatic snapshot creation (not recommended)

.PARAMETER TestOnly
    Only run connectivity tests, skip snapshot creation

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
    - Run from Windows desktop before Deploy-SecurityHardening.ps1
    - Requires SSH access to Proxmox host for snapshots
    - Creates timestamped snapshots for easy identification
    - Place in: C:\dev\sae-portfolio\scripts\powershell\infrastructure\
#>

param(
    [string[]]$TargetSystems = @("control", "git", "docker", "siem", "ub24-tgt-01", "rl9-tgt-01", "ub20-tgt-01"),
    [string]$ProxmoxHost = "pve1",
    [string]$ProxmoxUser = "root",
    [switch]$SkipSnapshots,
    [switch]$TestOnly
)

$ErrorActionPreference = 'Stop'

# VM ID mapping based on your Proxmox datacenter
$VMMapping = @{
    "control" = 5001
    "git" = 5002
    "docker" = 5003
    "siem" = 5005
    "ub24-tgt-01" = 5007
    "rl9-tgt-01" = 5008
    "ub20-tgt-01" = 5009
}

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

function Test-ProxmoxConnectivity {
    if ($SkipSnapshots -or $TestOnly) {
        return $true
    }
    
    Write-Status "Testing Proxmox connectivity..." "INFO"
    
    try {
        $result = ssh -o ConnectTimeout=10 $ProxmoxUser@$ProxmoxHost "pveversion" 2>$null
        if ($result -like "*pve-manager*") {
            Write-Status "Proxmox connectivity confirmed" "SUCCESS"
            return $true
        } else {
            Write-Status "Proxmox connection failed - cannot create snapshots" "WARNING"
            return $false
        }
    } catch {
        Write-Status "Cannot connect to Proxmox host $ProxmoxHost" "WARNING"
        Write-Status "Snapshots will be skipped - manual backup recommended" "WARNING"
        return $false
    }
}

function New-SystemSnapshots {
    if ($SkipSnapshots -or $TestOnly) {
        Write-Status "Snapshot creation skipped" "INFO"
        return $true
    }
    
    Write-Status "Creating VM snapshots..." "INFO"
    
    $snapshotName = "pre-hardening-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $failedSnapshots = @()
    $successfulSnapshots = @()
    
    foreach ($system in $TargetSystems) {
        if ($VMMapping.ContainsKey($system)) {
            $vmid = $VMMapping[$system]
            Write-Host "  Creating snapshot for $system (VM $vmid)... " -NoNewline
            
            try {
                $result = ssh $ProxmoxUser@$ProxmoxHost "qm snapshot $vmid $snapshotName" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "SUCCESS" -ForegroundColor Green
                    $successfulSnapshots += $system
                } else {
                    Write-Host "FAILED" -ForegroundColor Red
                    $failedSnapshots += $system
                }
            } catch {
                Write-Host "FAILED" -ForegroundColor Red
                $failedSnapshots += $system
            }
        } else {
            Write-Status "  Unknown VM ID for $system - skipping snapshot" "WARNING"
            $failedSnapshots += $system
        }
    }
    
    Write-Status "Snapshot creation results:" "INFO"
    Write-Status "  Successful: $($successfulSnapshots.Count)/$($TargetSystems.Count) snapshots" "SUCCESS"
    
    if ($failedSnapshots.Count -gt 0) {
        Write-Status "  Failed snapshots: $($failedSnapshots -join ', ')" "WARNING"
        Write-Status "Consider manual snapshots for failed systems" "WARNING"
    }
    
    Write-Status "Snapshot name: $snapshotName" "INFO"
    return $true
}

function Get-SystemHealthCheck {
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
    Write-Host "Proxmox Host: $ProxmoxHost"
    Write-Host "Timestamp: $(Get-Date)"
    Write-Host ""
    
    if ($TestOnly) {
        Write-Status "TEST MODE: Connectivity verified, ready for hardening" "SUCCESS"
    } elseif ($SkipSnapshots) {
        Write-Status "SNAPSHOTS SKIPPED: Manual backup recommended" "WARNING"
    } else {
        Write-Status "SNAPSHOTS CREATED: Safe to proceed with hardening" "SUCCESS"
    }
    
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "1. Review any warnings above"
    Write-Host "2. Run: .\Deploy-SecurityHardening.ps1"
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
$allChecksPass = Test-ProxmoxConnectivity -and $allChecksPass

if ($allChecksPass) {
    New-SystemSnapshots | Out-Null
    Get-SystemHealthCheck
    Show-PreFlightSummary
    
    Write-Status "PRE-FLIGHT CHECK COMPLETED SUCCESSFULLY" "SUCCESS"
    exit 0
} else {
    Write-Status "PRE-FLIGHT CHECK FAILED - DO NOT PROCEED" "ERROR"
    Write-Host "Fix the issues above before running Deploy-SecurityHardening.ps1"
    exit 1
}