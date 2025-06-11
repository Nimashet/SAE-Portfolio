<#
.SYNOPSIS
    Orchestrates security hardening deployment across Linux infrastructure from Windows management workstation.

.DESCRIPTION
    This script automates the deployment of security hardening scripts to multiple Linux systems,
    executes the hardening procedures, and validates the security configuration. Demonstrates
    cross-platform automation and centralized management capabilities for Security Automation Engineer roles.

.PARAMETER TargetSystems
    Array of target system names to process. Default includes common lab systems.
    System names are used to construct SSH host aliases (homelab-{system}).

.PARAMETER ValidateOnly
    When specified, skips hardening deployment and only runs security validation.

.PARAMETER SkipValidation
    When specified, deploys hardening but skips the validation step.

.PARAMETER LogPath
    Full path to the log file. Default creates timestamped log in C:\temp directory.

.EXAMPLE
    .\Deploy-SecurityHardening.ps1
    Deploys security hardening to all default target systems with validation.

.EXAMPLE
    .\Deploy-SecurityHardening.ps1 -TargetSystems @("control", "docker") -LogPath "C:\logs\security.log"
    Deploys hardening to specific systems with custom log location.

.EXAMPLE
    .\Deploy-SecurityHardening.ps1 -ValidateOnly
    Runs security validation only without deploying changes.

.NOTES
    File Name      : Deploy-SecurityHardening.ps1
    Author         : Security Automation Engineer
    Prerequisite   : OpenSSH client, SSH key-based authentication configured
    Requirements   : - sae_lab_hardening.sh and sae_lab_validation.sh in ../bash/security/
                     - SSH connectivity to target systems via homelab-{system} aliases
                     - PowerShell 5.0 or later

.INPUTS
    None. You cannot pipe objects to this script.

.OUTPUTS
    System.Boolean. Returns $true if all systems processed successfully, $false otherwise.
    Detailed logs written to specified log file location.

.LINK
    Related bash scripts: sae_lab_hardening.sh, sae_lab_validation.sh
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false,
               HelpMessage="Array of target system names to process")]
    [ValidateNotNullOrEmpty()]
    [string[]]$TargetSystems = @("control", "git", "docker", "siem", "target-01"),
    
    [Parameter(Mandatory=$false,
               HelpMessage="Run validation only, skip hardening deployment")]
    [switch]$ValidateOnly,
    
    [Parameter(Mandatory=$false,
               HelpMessage="Deploy hardening but skip validation step")]
    [switch]$SkipValidation,
    
    [Parameter(Mandatory=$false,
               HelpMessage="Full path to log file location")]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = "C:\temp\security-hardening-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

# Script configuration
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$HardeningScript = Join-Path $ScriptPath "..\bash\security\sae_lab_hardening.sh"
$ValidationScript = Join-Path $ScriptPath "..\bash\security\sae_lab_validation.sh"

# Logging function with file write validation
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message, 
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console with color coding
    switch ($Level) {
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        default   { Write-Host $logEntry }
    }
    
    # Write to log file with error handling
    try {
        $logEntry | Out-File -FilePath $LogPath -Append -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $LogPath. Error: $_"
        # Continue execution but warn about logging issue
    }
}

# Test SSH connectivity
function Test-SSHConnectivity {
    param([string]$HostAlias)
    
    try {
        $result = ssh $HostAlias "echo 'connection-test'" 2>$null
        return $result -eq "connection-test"
    }
    catch {
        return $false
    }
}

# Deploy security hardening to a single system
function Deploy-SecurityHardening {
    param([string]$System)
    
    $hostAlias = "homelab-$System"
    Write-Log "Starting security hardening deployment for $System"
    
    # Test connectivity
    Write-Log "Testing SSH connectivity to $hostAlias"
    if (-not (Test-SSHConnectivity $hostAlias)) {
        Write-Log "Failed to connect to $System via $hostAlias" "ERROR"
        Write-Log "Verify SSH configuration and host accessibility" "ERROR"
        return $false
    }
    Write-Log "SSH connectivity confirmed for $hostAlias"
    
    # Copy hardening script
    Write-Log "Copying hardening script to $System"
    try {
        scp $HardeningScript "${hostAlias}:~/sae_lab_hardening.sh" 2>$null
        if ($LASTEXITCODE -ne 0) { 
            throw "SCP failed with exit code $LASTEXITCODE" 
        }
        Write-Log "Hardening script copied successfully"
    }
    catch {
        Write-Log "Failed to copy hardening script to $System`: $_" "ERROR"
        return $false
    }
    
    # Verify script was copied successfully
    try {
        $remoteFileCheck = ssh $hostAlias "test -f ~/sae_lab_hardening.sh && echo 'exists'" 2>$null
        if ($remoteFileCheck -ne "exists") {
            throw "Script file not found on remote system"
        }
        Write-Log "Confirmed script exists on remote system"
    }
    catch {
        Write-Log "Failed to verify script copy on $System`: $_" "ERROR"
        return $false
    }
    
    # Execute hardening
    Write-Log "Executing security hardening on $System"
    try {
        ssh $hostAlias "chmod +x ~/sae_lab_hardening.sh && ./sae_lab_hardening.sh $System" 2>$null
        if ($LASTEXITCODE -ne 0) { 
            throw "Hardening execution failed with exit code $LASTEXITCODE" 
        }
        Write-Log "Security hardening completed successfully on $System" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Security hardening failed on $System`: $_" "ERROR"
        return $false
    }
}

# Validate security hardening on a single system
function Test-SecurityHardening {
    param([string]$System)
    
    $hostAlias = "homelab-$System"
    Write-Log "Starting security validation for $System"
    
    # Test connectivity first
    Write-Log "Testing SSH connectivity to $hostAlias"
    if (-not (Test-SSHConnectivity $hostAlias)) {
        Write-Log "Failed to connect to $System via $hostAlias" "ERROR"
        return $false
    }
    
    # Copy validation script
    Write-Log "Copying validation script to $System"
    try {
        scp $ValidationScript "${hostAlias}:~/sae_lab_validation.sh" 2>$null
        if ($LASTEXITCODE -ne 0) { 
            throw "SCP failed with exit code $LASTEXITCODE" 
        }
        Write-Log "Validation script copied successfully"
    }
    catch {
        Write-Log "Failed to copy validation script to $System`: $_" "ERROR"
        return $false
    }
    
    # Verify script was copied successfully
    try {
        $remoteFileCheck = ssh $hostAlias "test -f ~/sae_lab_validation.sh && echo 'exists'" 2>$null
        if ($remoteFileCheck -ne "exists") {
            throw "Validation script file not found on remote system"
        }
        Write-Log "Confirmed validation script exists on remote system"
    }
    catch {
        Write-Log "Failed to verify validation script copy on $System`: $_" "ERROR"
        return $false
    }
    
    # Execute validation
    Write-Log "Executing security validation on $System"
    try {
        ssh $hostAlias "chmod +x ~/sae_lab_validation.sh && ./sae_lab_validation.sh $System" 2>$null
        if ($LASTEXITCODE -ne 0) { 
            Write-Log "Security validation found issues on $System (exit code: $LASTEXITCODE)" "WARNING"
            return $false
        }
        Write-Log "Security validation passed on $System" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Security validation failed on $System`: $_" "ERROR"
        return $false
    }
}

# Main execution
function Main {
    Write-Log "Starting security hardening orchestration"
    Write-Log "Target systems: $($TargetSystems -join ', ')"
    Write-Log "Log file: $LogPath"
    
    # Verify prerequisites
    Write-Log "Validating prerequisites..."
    
    # Check if ssh command is available
    try {
        $null = Get-Command ssh -ErrorAction Stop
        Write-Log "SSH client found"
    }
    catch {
        Write-Log "SSH client not found. Install OpenSSH client or Git for Windows" "ERROR"
        exit 1
    }
    
    # Check if scp command is available  
    try {
        $null = Get-Command scp -ErrorAction Stop
        Write-Log "SCP client found"
    }
    catch {
        Write-Log "SCP client not found. Install OpenSSH client or Git for Windows" "ERROR"
        exit 1
    }
    
    # Create and verify log directory and file access
    $logDir = Split-Path -Parent $LogPath
    if (-not (Test-Path $logDir)) {
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            Write-Log "Created log directory: $logDir"
        }
        catch {
            Write-Error "Failed to create log directory: $logDir. Error: $_"
            Write-Error "Ensure you have write permissions to the parent directory"
            exit 1
        }
    }
    
    # Test log file write access
    try {
        "# Security Hardening Log - $(Get-Date)" | Out-File -FilePath $LogPath -Force
        Write-Log "Log file initialized successfully: $LogPath"
    }
    catch {
        Write-Error "Cannot write to log file: $LogPath. Error: $_"
        Write-Error "Ensure you have write permissions to: $logDir"
        exit 1
    }
    
    # Verify script files exist
    if (-not (Test-Path $HardeningScript)) {
        Write-Log "Hardening script not found: $HardeningScript" "ERROR"
        Write-Log "Expected location: $HardeningScript" "ERROR"
        exit 1
    }
    
    if (-not (Test-Path $ValidationScript)) {
        Write-Log "Validation script not found: $ValidationScript" "ERROR"
        Write-Log "Expected location: $ValidationScript" "ERROR"
        exit 1
    }
    
    # Verify script files are readable
    try {
        $null = Get-Content $HardeningScript -TotalCount 1 -ErrorAction Stop
        Write-Log "Hardening script is readable"
    }
    catch {
        Write-Log "Cannot read hardening script: $HardeningScript" "ERROR"
        exit 1
    }
    
    try {
        $null = Get-Content $ValidationScript -TotalCount 1 -ErrorAction Stop  
        Write-Log "Validation script is readable"
    }
    catch {
        Write-Log "Cannot read validation script: $ValidationScript" "ERROR"
        exit 1
    }
    
    Write-Log "All prerequisites validated successfully"
    
    $results = @{}
    
    foreach ($system in $TargetSystems) {
        Write-Log "Processing system: $system"
        
        $hardeningSuccess = $true
        $validationSuccess = $true
        
        # Deploy hardening (unless validation-only mode)
        if (-not $ValidateOnly) {
            $hardeningSuccess = Deploy-SecurityHardening -System $system
        }
        
        # Run validation (unless skipped)
        if (-not $SkipValidation -and $hardeningSuccess) {
            $validationSuccess = Test-SecurityHardening -System $system
        }
        
        $results[$system] = @{
            Hardening = $hardeningSuccess
            Validation = $validationSuccess
        }
    }
    
    # Summary report
    Write-Log "=== DEPLOYMENT SUMMARY ==="
    $successCount = 0
    $totalCount = $TargetSystems.Count
    
    foreach ($system in $TargetSystems) {
        $status = $results[$system]
        $overallSuccess = $status.Hardening -and $status.Validation
        
        if ($overallSuccess) { 
            $successCount++
            Write-Log "$system: SUCCESS" "SUCCESS"
        } else {
            $statusDetails = @()
            if (-not $status.Hardening) { $statusDetails += "Hardening Failed" }
            if (-not $status.Validation) { $statusDetails += "Validation Failed" }
            Write-Log "$system: FAILED ($($statusDetails -join ', '))" "ERROR"
        }
    }
    
    Write-Log "Overall Success Rate: $successCount/$totalCount systems"
    
    if ($successCount -eq $totalCount) {
        Write-Log "All systems successfully hardened and validated" "SUCCESS"
        exit 0
    } else {
        Write-Log "Some systems failed hardening or validation" "WARNING"
        exit 1
    }
}

# Execute main function
Main