# File: Manage-ProxmoxSnapshots.ps1
# Proxmox VM snapshot management for SAE lab

<#
.SYNOPSIS
    Manage Proxmox VM snapshots with storage validation and cleanup

.DESCRIPTION
    Comprehensive snapshot management for SAE lab VMs:
    - Create snapshots with storage space validation
    - List existing snapshots with size information
    - Delete old snapshots with cleanup policies
    - Support for VM groups and individual VMs
    - Storage monitoring and alerts

.PARAMETER Action
    Action to perform: Create, List, Delete, Cleanup

.PARAMETER VMList
    Specific VMs to target (VM IDs or names)

.PARAMETER VMGroup
    Predefined VM groups: All, Linux, Windows, Infrastructure, Targets

.PARAMETER SnapshotName
    Custom snapshot name (default: auto-generated with timestamp)

.PARAMETER ProxmoxHost
    Proxmox host SSH alias (default: pve1)

.PARAMETER MaxAge
    Maximum age in days for cleanup operations (default: 7)

.PARAMETER DryRun
    Show what would be done without making changes

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Manage-ProxmoxSnapshots.ps1 -Action Create -VMGroup Linux
    Create snapshots for all Linux VMs

.EXAMPLE
    .\Manage-ProxmoxSnapshots.ps1 -Action Create -VMList @(5001, 5010, 5011) -SnapshotName "pre-laps"
    Create named snapshots for specific VMs

.EXAMPLE
    .\Manage-ProxmoxSnapshots.ps1 -Action List -VMGroup All
    List all snapshots across all VMs

.EXAMPLE
    .\Manage-ProxmoxSnapshots.ps1 -Action Cleanup -MaxAge 7 -DryRun
    Show old snapshots that would be deleted

.NOTES
    - Requires SSH access to Proxmox host
    - Validates storage space before creating snapshots
    - Place in: scripts/powershell/infrastructure/
    - Run from Windows desktop with SSH configured
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("Create", "List", "Delete", "Cleanup")]
    [string]$Action,
    
    [string[]]$VMList = @(),
    
    [ValidateSet("All", "Linux", "Windows", "Infrastructure", "Targets")]
    [string]$VMGroup = "",
    
    [string]$SnapshotName = "",
    
    [string]$ProxmoxHost = "pve1",
    
    [int]$MaxAge = 7,
    
    [switch]$DryRun,
    
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# VM definitions based on SAE lab
$VMGroups = @{
    "All" = @(5001, 5002, 5003, 5004, 5005, 5007, 5008, 5009, 5010, 5011)
    "Linux" = @(5001, 5002, 5003, 5005, 5007, 5008, 5009)
    "Windows" = @(5004, 5010, 5011)
    "Infrastructure" = @(5001, 5002, 5003, 5004, 5005)
    "Targets" = @(5007, 5008, 5009, 5010, 5011)
}

$VMNames = @{
    5001 = "ub24-control-01"
    5002 = "ub24-git-01"
    5003 = "ub24-docker-01"
    5004 = "ws22-dc-01"
    5005 = "ub24-siem-01"
    5007 = "ub24-tgt-01"
    5008 = "rl9-tgt-01"
    5009 = "ub20-tgt-01"
    5010 = "ws22-tgt-01"
    5011 = "w11-tgt-01"
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

function Test-ProxmoxConnection {
    Write-Status "Testing Proxmox connectivity..."
    
    try {
        $result = ssh -o ConnectTimeout=10 $ProxmoxHost "pveversion" 2>$null
        if ($result -like "*pve-manager*") {
            Write-Status "Connected to Proxmox: $result" "SUCCESS"
            return $true
        } else {
            Write-Status "Invalid response from Proxmox host" "ERROR"
            return $false
        }
    } catch {
        Write-Status "Cannot connect to Proxmox host $ProxmoxHost" "ERROR"
        return $false
    }
}

function Get-StorageInfo {
    Write-Status "Checking storage space..."
    
    try {
        $storageResult = ssh $ProxmoxHost "pvesm status" 2>$null
        
        if ($storageResult) {
            $storageLines = $storageResult -split "`n" | Where-Object { $_ -match "local|local-lvm" }
            
            foreach ($line in $storageLines) {
                if ($line -match "(\S+)\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)") {
                    $storageName = $matches[1]
                    $total = [math]::Round($matches[2] / 1GB, 2)
                    $used = [math]::Round($matches[3] / 1GB, 2)
                    $available = [math]::Round($matches[4] / 1GB, 2)
                    $percentUsed = [math]::Round(($used / $total) * 100, 1)
                    
                    Write-Status "Storage $storageName`: ${used}GB used / ${total}GB total (${percentUsed}% used, ${available}GB free)"
                    
                    if ($percentUsed -gt 90) {
                        Write-Status "Storage $storageName is critically low on space" "WARNING"
                    } elseif ($percentUsed -gt 80) {
                        Write-Status "Storage $storageName is getting low on space" "WARNING"
                    }
                }
            }
            return $true
        } else {
            Write-Status "Could not retrieve storage information" "WARNING"
            return $false
        }
    } catch {
        Write-Status "Failed to check storage: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Resolve-VMList {
    $targetVMs = @()
    
    if ($VMGroup -and $VMGroups.ContainsKey($VMGroup)) {
        $targetVMs = $VMGroups[$VMGroup]
        Write-Status "Using VM group '$VMGroup': $($targetVMs.Count) VMs"
    } elseif ($VMList.Count -gt 0) {
        $targetVMs = $VMList | ForEach-Object {
            if ($_ -match '^\d+$') {
                [int]$_
            } else {
                $vmName = $_
                $vmId = $VMNames.GetEnumerator() | Where-Object { $_.Value -eq $vmName } | Select-Object -ExpandProperty Key
                if ($vmId) { $vmId } else { Write-Status "Unknown VM: $vmName" "WARNING"; $null }
            }
        } | Where-Object { $_ -ne $null }
        Write-Status "Using VM list: $($targetVMs.Count) VMs"
    } else {
        Write-Status "No VMs specified. Use -VMGroup or -VMList" "ERROR"
        return @()
    }
    
    return $targetVMs
}

function New-VMSnapshot {
    param([int[]]$VMIDs, [string]$SnapName)
    
    if (!$SnapName) {
        $SnapName = "snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    
    Write-Status "Creating snapshots with name: $SnapName"
    
    $successful = 0
    $failed = 0
    
    foreach ($vmid in $VMIDs) {
        $vmName = $VMNames[$vmid]
        Write-Host "  Creating snapshot for VM $vmid ($vmName)... " -NoNewline
        
        if ($DryRun) {
            Write-Host "WOULD CREATE" -ForegroundColor Yellow
            continue
        }
        
        try {
            $result = ssh $ProxmoxHost "qm snapshot $vmid $SnapName" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "SUCCESS" -ForegroundColor Green
                $successful++
            } else {
                Write-Host "FAILED" -ForegroundColor Red
                Write-Status "  Error: $result" "ERROR"
                $failed++
            }
        } catch {
            Write-Host "FAILED" -ForegroundColor Red
            $failed++
        }
    }
    
    Write-Status "Snapshot creation complete: $successful successful, $failed failed"
    return ($failed -eq 0)
}

function Get-VMSnapshots {
    param([int[]]$VMIDs)
    
    Write-Status "Listing snapshots..."
    
    $allSnapshots = @()
    
    foreach ($vmid in $VMIDs) {
        $vmName = $VMNames[$vmid]
        
        try {
            $snapshots = ssh $ProxmoxHost "qm listsnapshot $vmid" 2>$null
            if ($snapshots) {
                $snapLines = $snapshots -split "`n" | Where-Object { $_ -match "^\s*->" }
                
                foreach ($line in $snapLines) {
                    if ($line -match "->\s+(\S+)\s+(.+)") {
                        $snapName = $matches[1]
                        $snapInfo = $matches[2]
                        
                        $allSnapshots += [PSCustomObject]@{
                            VMID = $vmid
                            VMName = $vmName
                            SnapshotName = $snapName
                            Info = $snapInfo
                        }
                    }
                }
            }
        } catch {
            Write-Status "Failed to list snapshots for VM $vmid" "ERROR"
        }
    }
    
    if ($allSnapshots.Count -gt 0) {
        Write-Status "Found $($allSnapshots.Count) snapshots:"
        $allSnapshots | Format-Table -AutoSize VMID, VMName, SnapshotName, Info
    } else {
        Write-Status "No snapshots found"
    }
    
    return $allSnapshots
}

function Remove-VMSnapshot {
    param([int]$VMID, [string]$SnapName)
    
    $vmName = $VMNames[$VMID]
    Write-Host "  Deleting snapshot '$SnapName' from VM $VMID ($vmName)... " -NoNewline
    
    if ($DryRun) {
        Write-Host "WOULD DELETE" -ForegroundColor Yellow
        return $true
    }
    
    try {
        $result = ssh $ProxmoxHost "qm delsnapshot $VMID $SnapName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "SUCCESS" -ForegroundColor Green
            return $true
        } else {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Status "  Error: $result" "ERROR"
            return $false
        }
    } catch {
        Write-Host "FAILED" -ForegroundColor Red
        return $false
    }
}

function Invoke-SnapshotCleanup {
    param([int[]]$VMIDs, [int]$MaxAgeDays)
    
    Write-Status "Cleaning up snapshots older than $MaxAgeDays days..."
    
    $cutoffDate = (Get-Date).AddDays(-$MaxAgeDays)
    Write-Status "Cutoff date: $cutoffDate"
    
    $deletedCount = 0
    $errorCount = 0
    
    foreach ($vmid in $VMIDs) {
        try {
            $snapshots = ssh $ProxmoxHost "qm listsnapshot $vmid" 2>$null
            if ($snapshots) {
                $snapLines = $snapshots -split "`n" | Where-Object { $_ -match "^\s*->" }
                
                foreach ($line in $snapLines) {
                    if ($line -match "->\s+(\S+)\s+(.+)") {
                        $snapName = $matches[1]
                        $snapInfo = $matches[2]
                        
                        # Try to parse date from snapshot name (format: snapshot-yyyyMMdd-HHmmss)
                        if ($snapName -match "(\d{8})-(\d{6})") {
                            $dateStr = $matches[1]
                            $timeStr = $matches[2]
                            
                            try {
                                $snapDate = [datetime]::ParseExact("$dateStr$timeStr", "yyyyMMddHHmmss", $null)
                                
                                if ($snapDate -lt $cutoffDate) {
                                    Write-Status "Found old snapshot: $snapName ($(Get-Date $snapDate -Format 'yyyy-MM-dd HH:mm:ss'))"
                                    
                                    if (Remove-VMSnapshot -VMID $vmid -SnapName $snapName) {
                                        $deletedCount++
                                    } else {
                                        $errorCount++
                                    }
                                }
                            } catch {
                                Write-Status "Could not parse date from snapshot name: $snapName" "WARNING"
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Status "Failed to process snapshots for VM $vmid" "ERROR"
            $errorCount++
        }
    }
    
    Write-Status "Cleanup complete: $deletedCount deleted, $errorCount errors"
}

# Main execution
Write-Host "Proxmox Snapshot Management" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

# Test connection
if (!(Test-ProxmoxConnection)) {
    exit 1
}

# Check storage if creating snapshots
if ($Action -eq "Create") {
    Get-StorageInfo | Out-Null
}

# Resolve target VMs
$targetVMs = Resolve-VMList
if ($targetVMs.Count -eq 0) {
    exit 1
}

# Show what will be affected
Write-Status "Target VMs:"
foreach ($vmid in $targetVMs) {
    $vmName = $VMNames[$vmid]
    Write-Host "  VM $vmid`: $vmName"
}

# Confirmation prompt (unless Force or DryRun)
if (!$Force -and !$DryRun -and $Action -ne "List") {
    Write-Host ""
    $confirmation = Read-Host "Continue with $Action action? (y/N)"
    if ($confirmation -ne "y" -and $confirmation -ne "Y") {
        Write-Status "Operation cancelled"
        exit 0
    }
}

Write-Host ""

# Execute action
switch ($Action) {
    "Create" {
        New-VMSnapshot -VMIDs $targetVMs -SnapName $SnapshotName
    }
    "List" {
        Get-VMSnapshots -VMIDs $targetVMs
    }
    "Cleanup" {
        Invoke-SnapshotCleanup -VMIDs $targetVMs -MaxAgeDays $MaxAge
    }
}

Write-Status "Operation completed"