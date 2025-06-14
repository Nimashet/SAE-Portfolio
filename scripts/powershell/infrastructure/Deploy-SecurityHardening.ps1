# File: Deploy-SecurityHardening.ps1
# Deploy security hardening to Linux systems in SAE lab

<#
.SYNOPSIS
    Deploy security hardening to Linux systems in SAE lab

.DESCRIPTION
    Orchestrates security hardening deployment across Linux infrastructure.
    Copies hardening scripts, executes them, validates results, and cleans up.
    
    Uses SSH config aliases for connectivity (homelab-{system}).
    Only targets Linux systems - Windows systems are excluded.

.PARAMETER TargetSystems
    Array of target system names. Script constructs SSH aliases as homelab-{system}.
    Default includes all deployed Linux systems in SAE lab.

.PARAMETER ValidateOnly
    Skip hardening deployment, only run security validation

.PARAMETER SkipValidation
    Deploy hardening but skip validation step

.PARAMETER LogPath
    Log file location. Default: C:\temp\security-hardening-{timestamp}.log

.EXAMPLE
    .\Deploy-SecurityHardening.ps1
    Deploy hardening to all Linux systems with validation

.EXAMPLE
    .\Deploy-SecurityHardening.ps1 -TargetSystems @("control", "ub24-tgt-01")
    Deploy to specific systems only

.EXAMPLE
    .\Deploy-SecurityHardening.ps1 -ValidateOnly
    Run validation only, no changes

.NOTES
    - Requires SSH connectivity via homelab-{system} aliases
    - Requires bash scripts: scripts/bash/security/sae_lab_hardening.sh
                           scripts/bash/security/sae_lab_validation.sh
    - Cleans up remote scripts after execution
    - Continues on failure, provides summary at end
#>

param(
    [string[]]$TargetSystems = @("control", "git", "docker", "siem", "ub24-tgt-01", "rl9-tgt-01", "ub20-tgt-01"),
    [switch]$ValidateOnly,
    [switch]$SkipValidation,
    [string]$LogPath = "C:\temp\security-hardening-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

$ErrorActionPreference = 'Stop'

# Script locations relative to this PowerShell script
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$HardeningScript = Join-Path $ScriptPath "scripts\bash\security\sae_lab_hardening.sh"
$ValidationScript = Join-Path $ScriptPath "scripts\bash\security\sae_lab_validation.sh"

# Simple logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        default   { Write-Host $logEntry }
    }
    
    try {
        $logEntry | Out-File -FilePath $LogPath -Append
    } catch {
        Write-Warning "Failed to write to log: $($_.Exception.Message)"
    }
}

# Test SSH connectivity
function Test-SSHConnection {
    param([string]$HostAlias)
    
    try {
        $result = ssh $HostAlias "echo 'test'" 2>&1
        return $result -eq "test"
    } catch {
        return $false
    }
}

# Deploy hardening to single system
function Deploy-Hardening {
    param([string]$System)
    
    $hostAlias = "homelab-$System"
    Write-Log "Deploying hardening to $System"
    
    # Test connectivity
    if (!(Test-SSHConnection $hostAlias)) {
        Write-Log "Cannot connect to $hostAlias" "ERROR"
        return $false
    }
    
    # Copy and execute hardening script
    try {
        scp $HardeningScript "${hostAlias}:~/sae_lab_hardening.sh" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "SCP failed" }
        
        ssh $hostAlias "chmod +x ~/sae_lab_hardening.sh && ./sae_lab_hardening.sh $System" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Hardening execution failed" }
        
        Write-Log "Hardening completed on $System" "SUCCESS"
        return $true
    } catch {
        Write-Log "Hardening failed on $System`: $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        # Cleanup
        ssh $hostAlias "rm -f ~/sae_lab_hardening.sh" 2>&1 | Out-Null
    }
}

# Validate hardening on single system
function Test-Hardening {
    param([string]$System)
    
    $hostAlias = "homelab-$System"
    Write-Log "Validating hardening on $System"
    
    # Test connectivity
    if (!(Test-SSHConnection $hostAlias)) {
        Write-Log "Cannot connect to $hostAlias" "ERROR"
        return $false
    }
    
    # Copy and execute validation script
    try {
        scp $ValidationScript "${hostAlias}:~/sae_lab_validation.sh" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "SCP failed" }
        
        ssh $hostAlias "chmod +x ~/sae_lab_validation.sh && ./sae_lab_validation.sh $System" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { 
            Write-Log "Validation found issues on $System" "WARNING"
            return $false
        }
        
        Write-Log "Validation passed on $System" "SUCCESS"
        return $true
    } catch {
        Write-Log "Validation failed on $System`: $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        # Cleanup
        ssh $hostAlias "rm -f ~/sae_lab_validation.sh" 2>&1 | Out-Null
    }
}

# Main execution
Write-Log "Starting security hardening deployment"
Write-Log "Target systems: $($TargetSystems -join ', ')"

# Basic validation
try {
    Get-Command ssh | Out-Null
    Get-Command scp | Out-Null
} catch {
    Write-Log "SSH/SCP not found. Install OpenSSH or Git for Windows" "ERROR"
    exit 1
}

if (!(Test-Path $HardeningScript)) {
    Write-Log "Hardening script not found: $HardeningScript" "ERROR"
    exit 1
}

if (!(Test-Path $ValidationScript)) {
    Write-Log "Validation script not found: $ValidationScript" "ERROR"
    exit 1
}

# Create log directory
$logDir = Split-Path -Parent $LogPath
if (!(Test-Path $logDir)) {
    try {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    } catch {
        Write-Log "Cannot create log directory: $logDir" "ERROR"
        exit 1
    }
}

# Process each system
$results = @{}
foreach ($system in $TargetSystems) {
    Write-Log "Processing $system"
    
    $hardeningSuccess = $true
    $validationSuccess = $true
    
    # Deploy hardening (unless validation-only)
    if (!$ValidateOnly) {
        $hardeningSuccess = Deploy-Hardening -System $system
    }
    
    # Run validation (unless skipped or hardening failed)
    if (!$SkipValidation -and $hardeningSuccess) {
        $validationSuccess = Test-Hardening -System $system
    }
    
    $results[$system] = @{
        Hardening = $hardeningSuccess
        Validation = $validationSuccess
    }
}

# Summary
Write-Log "=== SUMMARY ===" 
$successful = 0
$total = $TargetSystems.Count

foreach ($system in $TargetSystems) {
    $result = $results[$system]
    $issues = @()
    
    if (!$result.Hardening) { $issues += "Hardening Failed" }
    if (!$result.Validation) { $issues += "Validation Failed" }
    
    if ($issues.Count -eq 0) {
        Write-Log "$system`: SUCCESS" "SUCCESS"
        $successful++
    } else {
        Write-Log "$system`: FAILED ($($issues -join ', '))" "ERROR"
    }
}

Write-Log "Success rate: $successful/$total systems"

if ($successful -eq $total) {
    Write-Log "All systems processed successfully" "SUCCESS"
    exit 0
} else {
    Write-Log "Some systems failed processing" "WARNING"
    exit 1
}