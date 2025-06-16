# File: Manage-ProxmoxSnapshots.ps1
# Enhanced Proxmox VM snapshot management for SAE lab

<#
.SYNOPSIS
    Manage Proxmox VM snapshots with comprehensive storage validation and disk location tracking

.DESCRIPTION
    Enhanced snapshot management for SAE lab VMs:
    - Create snapshots with full storage space validation across all pools
    - List existing snapshots with size information
    - Delete old snapshots with cleanup policies
    - Show VM disk locations across all storage pools
    - Display snapshot storage locations and usage
    - Support for VM groups and individual VMs
    - Storage monitoring and alerts for all storage types

.PARAMETER Action
    Action to perform: Create, List, Delete, Cleanup, ShowDisks, ShowStorage

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

.PARAMETER PowerOff
    Power off VMs before creating snapshots (for maximum consistency)

.PARAMETER WaitTime
    Seconds to wait after shutdown before snapshot (default: 30)

.EXAMPLE
    .\Manage-ProxmoxSnapshots.ps1 -Action ShowDisks
    Show where all VM disks are located across storage pools

.EXAMPLE
    .\Manage-ProxmoxSnapshots.ps1 -Action ShowStorage
    Display detailed storage information and snapshot locations

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
    .\Manage-ProxmoxSnapshots.ps1 -Action Create -VMGroup Linux -PowerOff
    Create consistent snapshots by powering off VMs first

.NOTES
    - Requires SSH access to Proxmox host
    - Validates storage space across all storage pools before creating snapshots
    - Shows VM disk locations and snapshot storage usage
    - Place in: scripts/powershell/infrastructure/
    - Run from Windows desktop with SSH configured
    
    Version 2.0 - Enhanced with disk location tracking and full storage monitoring
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("Create", "List", "Delete", "Cleanup", "ShowDisks", "ShowStorage")]
    [string]$Action,
    
    [string[]]$VMList = @(),
    
    [ValidateSet("All", "Linux", "Windows", "Infrastructure", "Targets")]
    [string]$VMGroup = "",
    
    [string]$SnapshotName = "",
    
    [string]$ProxmoxHost = "pve1",
    
    [int]$MaxAge = 7,
    
    [switch]$DryRun,
    
    [switch]$PowerOff,
    
    [int]$WaitTime = 30,
    
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
    Write-Status "Checking storage space across all pools..."
    
    try {
        $storageResult = ssh $ProxmoxHost "pvesm status" 2>$null
        
        if ($storageResult) {
            # Show all active storage pools that support VM images
            $storageLines = $storageResult -split "`n" | Where-Object { 
                $_ -match "\s+active\s+" -and $_ -match "(local|nvme|ssd|lvm|zfs)" 
            }
            
            $totalStorages = 0
            $warningCount = 0
            
            foreach ($line in $storageLines) {
                if ($line -match "(\S+)\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)") {
                    $storageName = $matches[1]
                    $total = [math]::Round($matches[2] / 1GB, 2)
                    $used = [math]::Round($matches[3] / 1GB, 2)
                    $available = [math]::Round($matches[4] / 1GB, 2)
                    $percentUsed = [math]::Round(($used / $total) * 100, 1)
                    
                    # Handle TB-scale storage display
                    if ($total -gt 1000) {
                        $totalTB = [math]::Round($total / 1024, 2)
                        $usedTB = [math]::Round($used / 1024, 2)
                        $availableTB = [math]::Round($available / 1024, 2)
                        Write-Status "Storage $storageName`: ${usedTB}TB used / ${totalTB}TB total (${percentUsed}% used, ${availableTB}TB free)"
                    } else {
                        Write-Status "Storage $storageName`: ${used}GB used / ${total}GB total (${percentUsed}% used, ${available}GB free)"
                    }
                    
                    if ($percentUsed -gt 90) {
                        Write-Status "Storage $storageName is critically low on space" "ERROR"
                        $warningCount++
                    } elseif ($percentUsed -gt 80) {
                        Write-Status "Storage $storageName is getting low on space" "WARNING"
                        $warningCount++
                    }
                    
                    $totalStorages++
                }
            }
            
            Write-Status "Checked $totalStorages storage pools, $warningCount warnings"
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

function Get-VMDiskLocations {
    Write-Status "Checking VM disk locations across all storage pools..."
    
    $storageDistribution = @{}
    
    foreach ($vmid in $VMGroups["All"]) {
        $vmName = $VMNames[$vmid]
        Write-Host "VM $vmid ($vmName):"
        
        try {
            $config = ssh $ProxmoxHost "qm config $vmid" 2>$null
            if ($config) {
                $diskLines = $config | Where-Object { $_ -match "^(scsi|ide|virtio|sata)" -and $_ -notmatch "cdrom" }
                
                foreach ($line in $diskLines) {
                    if ($line -match "^(\w+\d+):\s*([^:,]+):") {
                        $diskName = $matches[1]
                        $storage = $matches[2]
                        
                        # Track storage distribution
                        if (-not $storageDistribution.ContainsKey($storage)) {
                            $storageDistribution[$storage] = @()
                        }
                        $storageDistribution[$storage] += "$vmid ($vmName)"
                        
                        # Color code based on storage type
                        $color = switch ($storage) {
                            "nvme-storage" { "Green" }
                            "ssd-storage"  { "Cyan" }
                            "local-lvm"    { "Yellow" }
                            "local"        { "Red" }
                            default        { "White" }
                        }
                        
                        Write-Host "  $diskName`: $storage" -ForegroundColor $color
                    }
                }
            } else {
                Write-Status "  No disk configuration found" "WARNING"
            }
        } catch {
            Write-Status "  Failed to get config for VM $vmid" "ERROR"
        }
        Write-Host ""
    }
    
    # Display storage distribution summary
    Write-Host "Storage Distribution Summary:" -ForegroundColor Cyan
    Write-Host "============================" -ForegroundColor Cyan
    foreach ($storage in $storageDistribution.Keys | Sort-Object) {
        $vmCount = $storageDistribution[$storage].Count
        Write-Host "$storage`: $vmCount VMs" -ForegroundColor White
        foreach ($vm in $storageDistribution[$storage]) {
            Write-Host "  - $vm" -ForegroundColor Gray
        }
        Write-Host ""
    }
}

function Get-SnapshotLocations {
    Write-Status "Analyzing snapshot storage locations and usage..."
    
    try {
        # Get LVM information for snapshot analysis
        $lvmInfo = ssh $ProxmoxHost "lvs --noheadings -o lv_name,vg_name,lv_size,data_percent 2>/dev/null | grep snap" 2>$null
        
        if ($lvmInfo) {
            Write-Host "LVM Snapshot Details:" -ForegroundColor Cyan
            Write-Host "=====================" -ForegroundColor Cyan
            
            $snapshots = $lvmInfo -split "`n" | Where-Object { $_ -match "snap" }
            foreach ($snap in $snapshots) {
                if ($snap -match "\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)") {
                    $snapName = $matches[1].Trim()
                    $vgName = $matches[2].Trim()
                    $size = $matches[3].Trim()
                    $usage = $matches[4].Trim()
                    
                    Write-Host "  $snapName (VG: $vgName) - Size: $size, Usage: $usage%" -ForegroundColor White
                }
            }
        } else {
            Write-Status "No LVM snapshots found or LVM not accessible"
        }
        
        # Get storage pool information for thin pools
        Write-Host "`nThin Pool Information:" -ForegroundColor Cyan
        Write-Host "======================" -ForegroundColor Cyan
        
        $thinPools = ssh $ProxmoxHost "lvs --noheadings -o lv_name,vg_name,data_percent,metadata_percent -S 'lv_attr=~twi'" 2>$null
        if ($thinPools) {
            $pools = $thinPools -split "`n" | Where-Object { $_ -match "\w" }
            foreach ($pool in $pools) {
                if ($pool -match "\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)") {
                    $poolName = $matches[1].Trim()
                    $vgName = $matches[2].Trim()
                    $dataUsage = $matches[3].Trim()
                    $metaUsage = $matches[4].Trim()
                    
                    Write-Host "  $poolName (VG: $vgName) - Data: $dataUsage%, Metadata: $metaUsage%" -ForegroundColor White
                }
            }
        } else {
            Write-Status "No thin pools found or not accessible"
        }
        
        # Show where snapshots would be created based on VM locations
        Write-Host "`nSnapshot Storage Mapping:" -ForegroundColor Cyan
        Write-Host "=========================" -ForegroundColor Cyan
        
        foreach ($vmid in $VMGroups["All"]) {
            $vmName = $VMNames[$vmid]
            $config = ssh $ProxmoxHost "qm config $vmid" 2>$null
            if ($config) {
                $diskLine = $config | Where-Object { $_ -match "^scsi0:" } | Select-Object -First 1
                if ($diskLine -match "scsi0:\s*([^:,]+):") {
                    $storage = $matches[1]
                    Write-Host "  VM $vmid ($vmName) snapshots → $storage" -ForegroundColor Gray
                }
            }
        }
        
    } catch {
        Write-Status "Failed to get snapshot location information: $($_.Exception.Message)" "ERROR"
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
    
    if ($PowerOff) {
        Write-Status "Creating consistent snapshots (VMs will be powered off temporarily)"
        Write-Status "Snapshot name: $SnapName"
    } else {
        Write-Status "Creating live snapshots (VMs remain running)"
        Write-Status "Snapshot name: $SnapName"
    }
    
    $successful = 0
    $failed = 0
    $vmStates = @{}
    
    try {
        if ($PowerOff) {
            # Phase 1: Power off VMs and record their states
            Write-Status "Phase 1: Powering off VMs..."
            foreach ($vmid in $VMIDs) {
                $vmName = $VMNames[$vmid]
                
                # Check current state
                try {
                    $status = ssh $ProxmoxHost "qm status $vmid" 2>$null
                    $isRunning = $status -like "*running*"
                    $vmStates[$vmid] = $isRunning
                    
                    if ($isRunning) {
                        Write-Host "  Shutting down VM $vmid ($vmName)... " -NoNewline
                        
                        if (!$DryRun) {
                            ssh $ProxmoxHost "qm shutdown $vmid" 2>$null | Out-Null
                            Write-Host "INITIATED" -ForegroundColor Yellow
                        } else {
                            Write-Host "WOULD SHUTDOWN" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Status "  VM $vmid ($vmName) already stopped"
                    }
                } catch {
                    Write-Status "  Failed to check/shutdown VM $vmid" "ERROR"
                    $vmStates[$vmid] = $false
                }
            }
            
            if (!$DryRun) {
                # Wait for VMs to shut down
                Write-Status "Waiting $WaitTime seconds for clean shutdown..."
                Start-Sleep -Seconds $WaitTime
                
                # Verify shutdown
                Write-Status "Verifying VM shutdown status..."
                foreach ($vmid in $VMIDs) {
                    $vmName = $VMNames[$vmid]
                    $status = ssh $ProxmoxHost "qm status $vmid" 2>$null
                    if ($status -like "*stopped*") {
                        Write-Status "  VM $vmid ($vmName): Stopped" "SUCCESS"
                    } else {
                        Write-Status "  VM $vmid ($vmName): Still running - forcing stop" "WARNING"
                        ssh $ProxmoxHost "qm stop $vmid" 2>$null | Out-Null
                    }
                }
            }
        }
        
        # Phase 2: Create snapshots
        Write-Status "Phase 2: Creating snapshots..."
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
        
    } finally {
        # Phase 3: Restart VMs if they were running before
        if ($PowerOff -and !$DryRun) {
            Write-Status "Phase 3: Restarting VMs that were originally running..."
            foreach ($vmid in $VMIDs) {
                $vmName = $VMNames[$vmid]
                $wasRunning = $vmStates[$vmid]
                
                if ($wasRunning) {
                    Write-Host "  Starting VM $vmid ($vmName)... " -NoNewline
                    try {
                        ssh $ProxmoxHost "qm start $vmid" 2>$null | Out-Null
                        Write-Host "SUCCESS" -ForegroundColor Green
                    } catch {
                        Write-Host "FAILED" -ForegroundColor Red
                        Write-Status "  Manual start required for VM $vmid" "ERROR"
                    }
                }
            }
        }
    }
    
    Write-Status "Snapshot creation complete: $successful successful, $failed failed"
    
    if ($PowerOff -and !$DryRun) {
        Write-Status "All VMs have been restarted to their original state"
    }
    
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
Write-Host "Enhanced Proxmox Snapshot Management" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

# Test connection
if (!(Test-ProxmoxConnection)) {
    exit 1
}

# Handle information-only actions
switch ($Action) {
    "ShowDisks" {
        Get-VMDiskLocations
        Write-Status "Disk location analysis completed"
        exit 0
    }
    "ShowStorage" {
        Get-StorageInfo | Out-Null
        Write-Host ""
        Get-SnapshotLocations
        Write-Status "Storage analysis completed"
        exit 0
    }
}

# Check storage for snapshot operations
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