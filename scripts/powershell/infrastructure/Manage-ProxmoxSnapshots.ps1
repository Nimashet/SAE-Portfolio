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
    "All" = @(5001, 5002, 5003, 5004, 5005, 5006, 5007, 5008, 5009, 5010, 5011)
    "Linux" = @(5001, 5002, 5003, 5005, 5006, 5007, 5008, 5009)
    "Windows" = @(5004, 5010, 5011)
    "Infrastructure" = @(5001, 5002, 5003, 5004, 5005)
    "Targets" = @(5006, 5007, 5008, 5009, 5010, 5011)
}

$VMNames = @{
    5001 = "ub24-control-01"
    5002 = "ub24-git-01"
    5003 = "ub24-docker-01"
    5004 = "ws22-dc-01"
    5005 = "ub24-siem-01"
    5006 = "kali-sec-01"
    5007 = "ub24-tgt-01"
    5008 = "rl9-tgt-01"
    5009 = "ub20-tgt-01"
    5010 = "ws22-tgt-01"
    5011 = "w11-tgt-01"
}

# Core utility functions for robust operations
function Invoke-ProxmoxCommand {
    param([string]$Command, [int]$TimeoutSeconds = 30)
    
    try {
        $result = ssh -o ConnectTimeout=$TimeoutSeconds $ProxmoxHost $Command 2>&1
        $exitCode = $LASTEXITCODE
        
        return @{
            Success = ($exitCode -eq 0)
            Output = $result
            ExitCode = $exitCode
            Command = $Command
        }
    } catch {
        return @{
            Success = $false
            Output = $_.Exception.Message
            ExitCode = -1
            Command = $Command
        }
    }
}

function Test-Prerequisites {
    $issues = @()
    
    # Check SSH config
    if (-not (Test-Path "~/.ssh/config")) {
        $issues += "SSH config file not found at ~/.ssh/config"
    }
    
    # Test SSH connectivity with timeout
    try {
        $result = Invoke-ProxmoxCommand "pveversion"
        if (-not $result.Success) {
            $issues += "Cannot connect to Proxmox host '$ProxmoxHost'. Check SSH configuration."
        }
    } catch {
        $issues += "SSH connection failed: $($_.Exception.Message)"
    }
    
    # Check for required tools
    try {
        $null = Get-Command ssh -ErrorAction Stop
    } catch {
        $issues += "SSH client not found or not in PATH"
    }
    
    return $issues
}

function Wait-VMShutdown {
    param([int[]]$VMIDs, [int]$TimeoutSeconds = 120)
    
    if ($VMIDs.Count -eq 0) {
        return @{ Success = $true; StillRunning = @(); TimeoutReached = $false }
    }
    
    $startTime = Get-Date
    $stillRunning = $VMIDs
    
    Write-Status "Waiting for VMs to shutdown (timeout: ${TimeoutSeconds}s)..."
    
    while ($stillRunning.Count -gt 0 -and ((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 3
        $newStillRunning = @()
        
        foreach ($vmid in $stillRunning) {
            $result = Invoke-ProxmoxCommand "qm status $vmid"
            if ($result.Success -and $result.Output -like "*running*") {
                $newStillRunning += $vmid
            } else {
                Write-Status "  VM $vmid shutdown confirmed" "SUCCESS"
            }
        }
        $stillRunning = $newStillRunning
        
        if ($stillRunning.Count -gt 0) {
            Write-Host "  Still waiting for VMs: $($stillRunning -join ', ')" -ForegroundColor Yellow
        }
    }
    
    return @{
        Success = ($stillRunning.Count -eq 0)
        StillRunning = $stillRunning
        TimeoutReached = ((Get-Date) - $startTime).TotalSeconds -ge $TimeoutSeconds
    }
}

function Test-ValidSnapshotName {
    param([string]$Name)
    
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    
    # Allow letters, numbers, hyphens, underscores, and dots
    return $Name -match '^[a-zA-Z0-9\-_.]+$'
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
    
    $result = Invoke-ProxmoxCommand "pveversion"
    if ($result.Success) {
        Write-Status "Connected to Proxmox: $($result.Output)" "SUCCESS"
        return $true
    } else {
        Write-Status "Cannot connect to Proxmox host $ProxmoxHost" "ERROR"
        Write-Status "Error: $($result.Output)" "ERROR"
        return $false
    }
}

function Get-StorageInfo {
    param([switch]$ReturnData, [string]$Label = "")
    
    if ($Label) {
        Write-Status "$Label - Checking storage space across all pools..."
    } else {
        Write-Status "Checking storage space across all pools..."
    }
    
    try {
        $result = Invoke-ProxmoxCommand "pvesm status"
        if (-not $result.Success) {
            Write-Status "Failed to get storage status: $($result.Output)" "ERROR"
            return @{}
        }
        
        $storageData = @{}
        $lines = $result.Output -split "`n" | Select-Object -Skip 1
        
        $totalStorages = 0
        $warningCount = 0
        
        foreach ($line in $lines) {
            $fields = $line -split '\s+' | Where-Object { $_.Trim() -ne "" }
            
            # Validate we have enough fields and it's an active storage
            if ($fields.Count -ge 6 -and $fields[2] -eq "active") {
                $storageName = $fields[0]
                
                # Skip non-VM storage types unless explicitly included
                if ($storageName -notmatch "(local|nvme|ssd|lvm|zfs|ceph|nfs)") {
                    continue
                }
                
                try {
                    $total = [math]::Round([long]$fields[3] / 1GB, 2)
                    $used = [math]::Round([long]$fields[4] / 1GB, 2)
                    $available = [math]::Round([long]$fields[5] / 1GB, 2)
                    $percentUsed = if ($total -gt 0) { [math]::Round(($used / $total) * 100, 1) } else { 0 }
                    
                    # Store data for comparison
                    $storageData[$storageName] = @{
                        Total = $total
                        Used = $used
                        Available = $available
                        PercentUsed = $percentUsed
                    }
                    
                    if (!$ReturnData) {
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
                    }
                    
                    $totalStorages++
                    
                } catch {
                    Write-Status "Failed to parse storage data for $storageName" "WARNING"
                }
            }
        }
        
        if (!$ReturnData) {
            Write-Status "Checked $totalStorages storage pools, $warningCount warnings"
        }
        
        return $storageData
        
    } catch {
        Write-Status "Failed to check storage: $($_.Exception.Message)" "ERROR"
        return @{}
    }
}

function Get-VMSnapshotSizes {
    param([int[]]$VMIDs)
    
    $snapshotData = @{}
    
    foreach ($vmid in $VMIDs) {
        if (-not $VMNames.ContainsKey($vmid)) {
            Write-Status "Skipping unknown VM ID: $vmid" "WARNING"
            continue
        }
        
        $vmName = $VMNames[$vmid]
        $snapshotData[$vmid] = @{
            VMName = $vmName
            Snapshots = @()
            TotalSnapshotSize = 0
        }
        
        try {
            # Get LVM snapshot information for this VM
            $result = Invoke-ProxmoxCommand "lvs --noheadings -o lv_name,lv_size,data_percent --units g 2>/dev/null | grep 'snap_vm-$vmid-'"
            
            if ($result.Success -and $result.Output) {
                $snapLines = $result.Output -split "`n" | Where-Object { $_ -match "snap_vm-$vmid-" }
                
                foreach ($line in $snapLines) {
                    if ($line -match "\s*(\S+)\s+(\S+)\s+(\S+)") {
                        $snapName = $matches[1].Trim()
                        $size = $matches[2].Trim()
                        $usage = $matches[3].Trim()
                        
                        # Parse size (remove 'g' suffix and convert to GB)
                        $sizeGB = try {
                            [math]::Round([float]($size -replace '[^\d\.]', ''), 2)
                        } catch {
                            0
                        }
                        
                        $snapshotData[$vmid].Snapshots += @{
                            Name = $snapName
                            Size = $sizeGB
                            Usage = $usage
                        }
                        
                        $snapshotData[$vmid].TotalSnapshotSize += $sizeGB
                    }
                }
            }
        } catch {
            Write-Status "Failed to get snapshot sizes for VM $vmid`: $($_.Exception.Message)" "WARNING"
        }
    }
    
    return $snapshotData
}

function Show-StorageComparison {
    param($BeforeStorage, $AfterStorage)
    
    Write-Host "`nStorage Usage Comparison:" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    
    foreach ($storage in $BeforeStorage.Keys | Sort-Object) {
        if ($AfterStorage.ContainsKey($storage)) {
            $before = $BeforeStorage[$storage]
            $after = $AfterStorage[$storage]
            
            $usedDiff = $after.Used - $before.Used
            $availableDiff = $before.Available - $after.Available
            $percentDiff = $after.PercentUsed - $before.PercentUsed
            
            if ($before.Total -gt 1000) {
                # TB scale
                $beforeUsedTB = [math]::Round($before.Used / 1024, 3)
                $afterUsedTB = [math]::Round($after.Used / 1024, 3)
                $diffTB = [math]::Round($usedDiff / 1024, 3)
                
                Write-Host "$storage`:" -ForegroundColor White
                Write-Host "  Before: ${beforeUsedTB}TB used (${before.PercentUsed}%)" -ForegroundColor Gray
                Write-Host "  After:  ${afterUsedTB}TB used (${after.PercentUsed}%)" -ForegroundColor Gray
                
                if ([math]::Abs($diffTB) -gt 0.001) {
                    $color = if ($diffTB -gt 0) { "Yellow" } else { "Green" }
                    $sign = if ($diffTB -gt 0) { "+" } else { "" }
                    Write-Host "  Change: ${sign}${diffTB}TB (${sign}${percentDiff:F2}%)" -ForegroundColor $color
                } else {
                    Write-Host "  Change: No significant change" -ForegroundColor Green
                }
            } else {
                # GB scale
                Write-Host "$storage`:" -ForegroundColor White
                Write-Host "  Before: ${before.Used}GB used (${before.PercentUsed}%)" -ForegroundColor Gray
                Write-Host "  After:  ${after.Used}GB used (${after.PercentUsed}%)" -ForegroundColor Gray
                
                if ([math]::Abs($usedDiff) -gt 0.01) {
                    $color = if ($usedDiff -gt 0) { "Yellow" } else { "Green" }
                    $sign = if ($usedDiff -gt 0) { "+" } else { "" }
                    Write-Host "  Change: ${sign}${usedDiff:F2}GB (${sign}${percentDiff:F2}%)" -ForegroundColor $color
                } else {
                    Write-Host "  Change: No significant change" -ForegroundColor Green
                }
            }
            Write-Host ""
        }
    }
}

function Show-SnapshotSummary {
    param($BeforeSnapshots, $AfterSnapshots, $CreatedSnapshots, [string]$SnapshotName)
    
    Write-Host "`nSnapshot Creation Summary:" -ForegroundColor Cyan
    Write-Host "==========================" -ForegroundColor Cyan
    
    if ($CreatedSnapshots.Count -gt 0) {
        Write-Host "Successfully created snapshots:" -ForegroundColor Green
        foreach ($vmid in $CreatedSnapshots) {
            $vmName = $VMNames[$vmid]
            Write-Host "  ✓ VM $vmid ($vmName) - '$SnapshotName'" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    Write-Host "Snapshot Storage Analysis:" -ForegroundColor White
    Write-Host "-------------------------" -ForegroundColor White
    
    foreach ($vmid in ($BeforeSnapshots.Keys + $AfterSnapshots.Keys | Sort-Object -Unique)) {
        $vmName = $VMNames[$vmid]
        $beforeTotal = if ($BeforeSnapshots.ContainsKey($vmid)) { $BeforeSnapshots[$vmid].TotalSnapshotSize } else { 0 }
        $afterTotal = if ($AfterSnapshots.ContainsKey($vmid)) { $AfterSnapshots[$vmid].TotalSnapshotSize } else { 0 }
        $newSnapshotSize = $afterTotal - $beforeTotal
        
        Write-Host "VM $vmid ($vmName):" -ForegroundColor White
        
        if ($AfterSnapshots.ContainsKey($vmid)) {
            $snapCount = $AfterSnapshots[$vmid].Snapshots.Count
            Write-Host "  Total snapshots: $snapCount" -ForegroundColor Gray
            Write-Host "  Total snapshot storage: ${afterTotal:F2}GB" -ForegroundColor Gray
            
            if ($newSnapshotSize -gt 0) {
                Write-Host "  New snapshot size: ${newSnapshotSize:F2}GB" -ForegroundColor Yellow
            } else {
                Write-Host "  New snapshot size: No new snapshots" -ForegroundColor Gray
            }
        } else {
            Write-Host "  No snapshots found" -ForegroundColor Gray
        }
        Write-Host ""
    }
}

function Get-VMDiskLocations {
    Write-Status "Checking VM disk locations across all storage pools..."
    
    $storageDistribution = @{}
    
    foreach ($vmid in $VMGroups["All"]) {
        if (-not $VMNames.ContainsKey($vmid)) {
            Write-Status "Skipping unknown VM ID: $vmid" "WARNING"
            continue
        }
        
        $vmName = $VMNames[$vmid]
        Write-Host "VM $vmid ($vmName):"
        
        $result = Invoke-ProxmoxCommand "qm config $vmid"
        if ($result.Success) {
            $diskLines = $result.Output -split "`n" | Where-Object { 
                $_ -match "^(scsi|ide|virtio|sata)" -and $_ -notmatch "cdrom" 
            }
            
            if ($diskLines.Count -eq 0) {
                Write-Status "  No disk configuration found" "WARNING"
            } else {
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
            }
        } else {
            Write-Status "  Failed to get config for VM $vmid`: $($result.Output)" "ERROR"
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
        $result = Invoke-ProxmoxCommand "lvs --noheadings -o lv_name,vg_name,lv_size,data_percent 2>/dev/null | grep snap"
        
        if ($result.Success -and $result.Output) {
            Write-Host "LVM Snapshot Details:" -ForegroundColor Cyan
            Write-Host "=====================" -ForegroundColor Cyan
            
            $snapshots = $result.Output -split "`n" | Where-Object { $_ -match "snap" }
            if ($snapshots.Count -gt 0) {
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
                Write-Status "No LVM snapshots found"
            }
        } else {
            Write-Status "No LVM snapshots found or LVM not accessible"
        }
        
        # Get storage pool information for thin pools
        Write-Host "`nThin Pool Information:" -ForegroundColor Cyan
        Write-Host "======================" -ForegroundColor Cyan
        
        $thinResult = Invoke-ProxmoxCommand "lvs --noheadings -o lv_name,vg_name,data_percent,metadata_percent -S 'lv_attr=~twi'"
        if ($thinResult.Success -and $thinResult.Output) {
            $pools = $thinResult.Output -split "`n" | Where-Object { $_ -match "\w" }
            if ($pools.Count -gt 0) {
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
                Write-Status "No thin pools found"
            }
        } else {
            Write-Status "No thin pools found or not accessible"
        }
        
        # Show where snapshots would be created based on VM locations
        Write-Host "`nSnapshot Storage Mapping:" -ForegroundColor Cyan
        Write-Host "=========================" -ForegroundColor Cyan
        
        foreach ($vmid in $VMGroups["All"]) {
            if (-not $VMNames.ContainsKey($vmid)) {
                continue
            }
            
            $vmName = $VMNames[$vmid]
            $configResult = Invoke-ProxmoxCommand "qm config $vmid"
            if ($configResult.Success) {
                $diskLine = $configResult.Output -split "`n" | Where-Object { $_ -match "^scsi0:" } | Select-Object -First 1
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
                $vmid = [int]$_
                if ($VMNames.ContainsKey($vmid)) {
                    $vmid
                } else {
                    Write-Status "Invalid VM ID: $vmid. Valid IDs: $($VMNames.Keys -join ', ')" "ERROR"
                    $null
                }
            } else {
                $vmName = $_
                $vmId = $VMNames.GetEnumerator() | Where-Object { $_.Value -eq $vmName } | Select-Object -ExpandProperty Key
                if ($vmId) { 
                    $vmId 
                } else { 
                    Write-Status "Unknown VM name: $vmName. Valid names: $($VMNames.Values -join ', ')" "ERROR"
                    $null 
                }
            }
        } | Where-Object { $_ -ne $null }
        Write-Status "Using VM list: $($targetVMs.Count) VMs"
    } else {
        Write-Status "No VMs specified. Use -VMGroup or -VMList" "ERROR"
        return @()
    }
    
    # Final validation of resolved VMs
    $validVMs = $targetVMs | Where-Object { $VMNames.ContainsKey($_) }
    if ($validVMs.Count -ne $targetVMs.Count) {
        $invalidVMs = $targetVMs | Where-Object { -not $VMNames.ContainsKey($_) }
        Write-Status "Removing invalid VM IDs: $($invalidVMs -join ', ')" "WARNING"
    }
    
    return $validVMs
}

function New-VMSnapshot {
    param([int[]]$VMIDs, [string]$SnapName)
    
    # Validate snapshot name
    if (!$SnapName) {
        $SnapName = "snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    
    if (-not (Test-ValidSnapshotName $SnapName)) {
        throw "Invalid snapshot name '$SnapName'. Use only letters, numbers, hyphens, underscores, and dots."
    }
    
    # Validate all VM IDs before starting
    foreach ($vmid in $VMIDs) {
        if (-not $VMNames.ContainsKey($vmid)) {
            throw "Invalid VM ID: $vmid. Valid IDs: $($VMNames.Keys -join ', ')"
        }
    }
    
    # Capture before state
    Write-Status "Capturing pre-snapshot state..."
    $beforeStorage = Get-StorageInfo -ReturnData -Label "BEFORE"
    $beforeSnapshots = Get-VMSnapshotSizes -VMIDs $VMIDs
    
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
    $createdSnapshots = @()
    
    try {
        if ($PowerOff) {
            # Phase 1: Power off VMs and record their states
            Write-Status "Phase 1: Powering off VMs..."
            $vmsToShutdown = @()
            
            foreach ($vmid in $VMIDs) {
                $vmName = $VMNames[$vmid]
                
                # Check current state
                $statusResult = Invoke-ProxmoxCommand "qm status $vmid"
                if ($statusResult.Success) {
                    $isRunning = $statusResult.Output -like "*running*"
                    $vmStates[$vmid] = $isRunning
                    
                    if ($isRunning) {
                        Write-Host "  Shutting down VM $vmid ($vmName)... " -NoNewline
                        
                        if (!$DryRun) {
                            $shutdownResult = Invoke-ProxmoxCommand "qm shutdown $vmid"
                            if ($shutdownResult.Success) {
                                Write-Host "INITIATED" -ForegroundColor Yellow
                                $vmsToShutdown += $vmid
                            } else {
                                Write-Host "FAILED" -ForegroundColor Red
                                Write-Status "  Shutdown error: $($shutdownResult.Output)" "ERROR"
                            }
                        } else {
                            Write-Host "WOULD SHUTDOWN" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Status "  VM $vmid ($vmName) already stopped"
                    }
                } else {
                    Write-Status "  Failed to check status of VM $vmid`: $($statusResult.Output)" "ERROR"
                    $vmStates[$vmid] = $false
                }
            }
            
            if (!$DryRun -and $vmsToShutdown.Count -gt 0) {
                # Wait for VMs to shut down
                $shutdownResult = Wait-VMShutdown -VMIDs $vmsToShutdown -TimeoutSeconds $WaitTime
                
                if (-not $shutdownResult.Success) {
                    if ($shutdownResult.TimeoutReached) {
                        Write-Status "Shutdown timeout reached. Force stopping remaining VMs..." "WARNING"
                        foreach ($vmid in $shutdownResult.StillRunning) {
                            $vmName = $VMNames[$vmid]
                            Write-Status "  Force stopping VM $vmid ($vmName)" "WARNING"
                            $stopResult = Invoke-ProxmoxCommand "qm stop $vmid"
                            if (-not $stopResult.Success) {
                                Write-Status "  Failed to force stop VM $vmid`: $($stopResult.Output)" "ERROR"
                            }
                        }
                        # Give force stop a moment
                        Start-Sleep -Seconds 5
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
                $createdSnapshots += $vmid
                continue
            }
            
            $snapshotResult = Invoke-ProxmoxCommand "qm snapshot $vmid $SnapName"
            if ($snapshotResult.Success) {
                Write-Host "SUCCESS" -ForegroundColor Green
                $successful++
                $createdSnapshots += $vmid
            } else {
                Write-Host "FAILED" -ForegroundColor Red
                Write-Status "  Snapshot error: $($snapshotResult.Output)" "ERROR"
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
                    $startResult = Invoke-ProxmoxCommand "qm start $vmid"
                    if ($startResult.Success) {
                        Write-Host "SUCCESS" -ForegroundColor Green
                    } else {
                        Write-Host "FAILED" -ForegroundColor Red
                        Write-Status "  Start error: $($startResult.Output)" "ERROR"
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
    
    # Capture after state and show summary
    if (!$DryRun) {
        Write-Status "Analyzing post-snapshot state..."
        # Give LVM time to update
        Start-Sleep -Seconds 5
        
        $afterStorage = Get-StorageInfo -ReturnData -Label "AFTER"
        $afterSnapshots = Get-VMSnapshotSizes -VMIDs $VMIDs
        
        # Show comprehensive summary
        Show-StorageComparison -BeforeStorage $beforeStorage -AfterStorage $afterStorage
        Show-SnapshotSummary -BeforeSnapshots $beforeSnapshots -AfterSnapshots $afterSnapshots -CreatedSnapshots $createdSnapshots -SnapshotName $SnapName
    }
    
    return ($failed -eq 0)
}

function Get-VMSnapshots {
    param([int[]]$VMIDs)
    
    Write-Status "Listing snapshots..."
    
    $allSnapshots = @()
    
    foreach ($vmid in $VMIDs) {
        if (-not $VMNames.ContainsKey($vmid)) {
            Write-Status "Skipping unknown VM ID: $vmid" "WARNING"
            continue
        }
        
        $vmName = $VMNames[$vmid]
        
        $result = Invoke-ProxmoxCommand "qm listsnapshot $vmid"
        if ($result.Success) {
            if ($result.Output) {
                $snapLines = $result.Output -split "`n" | Where-Object { $_ -match "^\s*->" }
                
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
        } else {
            Write-Status "Failed to list snapshots for VM $vmid`: $($result.Output)" "ERROR"
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
    
    if (-not $VMNames.ContainsKey($VMID)) {
        Write-Status "Invalid VM ID: $VMID" "ERROR"
        return $false
    }
    
    if (-not (Test-ValidSnapshotName $SnapName)) {
        Write-Status "Invalid snapshot name: $SnapName" "ERROR"
        return $false
    }
    
    $vmName = $VMNames[$VMID]
    Write-Host "  Deleting snapshot '$SnapName' from VM $VMID ($vmName)... " -NoNewline
    
    if ($DryRun) {
        Write-Host "WOULD DELETE" -ForegroundColor Yellow
        return $true
    }
    
    $result = Invoke-ProxmoxCommand "qm delsnapshot $VMID $SnapName"
    if ($result.Success) {
        Write-Host "SUCCESS" -ForegroundColor Green
        return $true
    } else {
        Write-Host "FAILED" -ForegroundColor Red
        Write-Status "  Delete error: $($result.Output)" "ERROR"
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
        if (-not $VMNames.ContainsKey($vmid)) {
            Write-Status "Skipping unknown VM ID: $vmid" "WARNING"
            continue
        }
        
        $result = Invoke-ProxmoxCommand "qm listsnapshot $vmid"
        if ($result.Success -and $result.Output) {
            $snapLines = $result.Output -split "`n" | Where-Object { $_ -match "^\s*->" }
            
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
        } else {
            Write-Status "Failed to process snapshots for VM $vmid`: $($result.Output)" "ERROR"
            $errorCount++
        }
    }
    
    Write-Status "Cleanup complete: $deletedCount deleted, $errorCount errors"
}

# Main execution
Write-Host "Enhanced Proxmox Snapshot Management" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites first
$prereqIssues = Test-Prerequisites
if ($prereqIssues.Count -gt 0) {
    Write-Status "Prerequisites check failed:" "ERROR"
    foreach ($issue in $prereqIssues) {
        Write-Status "  - $issue" "ERROR"
    }
    exit 1
}

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
    $null = Get-StorageInfo
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