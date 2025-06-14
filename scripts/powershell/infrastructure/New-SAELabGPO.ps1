# File: New-SAELabGPO.ps1
# Create Group Policy Objects for SAE Lab automation

#Requires -Version 5.1
#Requires -Modules GroupPolicy, ActiveDirectory
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Create Group Policy Objects for SAE Lab automation
    
.DESCRIPTION
    Sets up GPOs for automation lab. Creates OUs and configures policies for:
    - WinRM/Ansible connectivity
    - PowerShell execution
    - Firewall rules
    - RDP access
    - Windows Updates
    
.PARAMETER Domain
    Target domain (default: lab.servers.lan)
    
.PARAMETER ReportDir
    Where to dump GPO reports (default: C:\Temp\GPO-Reports)
    
.PARAMETER Force
    Nuke existing GPOs and recreate
    
.EXAMPLE
    .\New-SAELabGPO.ps1 -Domain lab.servers.lan
    
.NOTES
    Run this on the DC. Make sure GPMC is installed.
    Move your boxes to the right OUs after running this.
    Place in: scripts/powershell/infrastructure/
#>

param(
    [string]$Domain = "lab.servers.lan",
    [string]$ReportDir = "C:\Temp\GPO-Reports",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Basic validation - keep it simple
Write-Host "Checking environment..." -ForegroundColor Green
try {
    $dcFeature = Get-WindowsFeature -Name AD-Domain-Services
    if ($dcFeature.InstallState -ne 'Installed') {
        throw "Need to run this on a DC"
    }
} catch {
    throw "Failed to check DC role: $($_.Exception.Message)"
}

try {
    Get-ADDomain $Domain | Out-Null
} catch {
    throw "Can't find domain '$Domain': $($_.Exception.Message)"
}

try {
    if (!(Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    }
} catch {
    throw "Failed to create report directory: $($_.Exception.Message)"
}

$DomainDN = "DC=" + $Domain.Replace('.', ',DC=')

# Create OUs if they don't exist
$OUs = @(
    @{Name="SAE-Lab"; Path=$DomainDN; Description="Lab Environment"},
    @{Name="SAE-Servers"; Path="OU=SAE-Lab,$DomainDN"; Description="Lab Servers"},
    @{Name="SAE-Workstations"; Path="OU=SAE-Lab,$DomainDN"; Description="Lab Workstations"},
    @{Name="SAE-Automation"; Path="OU=SAE-Lab,$DomainDN"; Description="Automation Systems"}
)

Write-Host "Creating OUs..." -ForegroundColor Green
foreach ($OU in $OUs) {
    try {
        $existingOU = Get-ADOrganizationalUnit -Filter "Name -eq '$($OU.Name)'" -SearchBase $OU.Path -SearchScope OneLevel
        Write-Host "  $($OU.Name) already exists"
    } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        try {
            New-ADOrganizationalUnit -Name $OU.Name -Path $OU.Path -Description $OU.Description
            Write-Host "  Created $($OU.Name)"
        } catch {
            Write-Warning "Failed to create OU '$($OU.Name)': $($_.Exception.Message)"
        }
    } catch {
        Write-Warning "Failed to check OU '$($OU.Name)': $($_.Exception.Message)"
    }
}

# GPO definitions
$GPOs = @(
    @{Name="SAE-Lab-Servers"; Comment="Server automation config"},
    @{Name="SAE-Lab-Workstations"; Comment="Workstation automation config"},
    @{Name="SAE-Lab-Automation"; Comment="Automation system config"}
)

Write-Host "Creating GPOs..." -ForegroundColor Green
foreach ($GPODef in $GPOs) {
    try {
        $existing = Get-GPO -Name $GPODef.Name
        
        if ($Force) {
            Remove-GPO -Name $GPODef.Name -Confirm:$false
            Write-Host "  Removed existing $($GPODef.Name)"
            
            try {
                New-GPO -Name $GPODef.Name -Comment $GPODef.Comment | Out-Null
                Write-Host "  Created $($GPODef.Name)"
            } catch {
                Write-Warning "Failed to create GPO '$($GPODef.Name)': $($_.Exception.Message)"
            }
        } else {
            Write-Host "  $($GPODef.Name) exists (use -Force to recreate)"
        }
    } catch [System.ArgumentException] {
        # GPO doesn't exist, create it
        try {
            New-GPO -Name $GPODef.Name -Comment $GPODef.Comment | Out-Null
            Write-Host "  Created $($GPODef.Name)"
        } catch {
            Write-Warning "Failed to create GPO '$($GPODef.Name)': $($_.Exception.Message)"
        }
    } catch {
        Write-Warning "Failed to check GPO '$($GPODef.Name)': $($_.Exception.Message)"
    }
}

# Registry settings - the meat and potatoes
$RegSettings = @{
    # WinRM config
    "HKLM\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service\AllowBasic" = @{Type="DWord"; Value=1}
    "HKLM\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service\AllowUnencryptedTraffic" = @{Type="DWord"; Value=1}
    "HKLM\SYSTEM\CurrentControlSet\Services\WinRM\Start" = @{Type="DWord"; Value=2}
    
    # PowerShell execution policy
    "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\EnableScripts" = @{Type="DWord"; Value=1}
    "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ExecutionPolicy" = @{Type="String"; Value="RemoteSigned"}
    
    # RDP settings
    "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections" = @{Type="DWord"; Value=0}
    "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp\UserAuthentication" = @{Type="DWord"; Value=1}
    
    # Windows Updates - install at 3 AM
    "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate" = @{Type="DWord"; Value=0}
    "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\AUOptions" = @{Type="DWord"; Value=4}
    "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\ScheduledInstallTime" = @{Type="DWord"; Value=3}
    
    # Basic auditing
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit\AuditAccountLogon" = @{Type="DWord"; Value=3}
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit\AuditLogonEvents" = @{Type="DWord"; Value=3}
}

# Firewall rules - simplified
$FirewallRules = @{
    "WinRM-HTTP" = "v2.30|Action=Allow|Active=TRUE|Dir=Inbound|Protocol=TCP|LPort=5985|Name=WinRM-HTTP"
    "SSH" = "v2.30|Action=Allow|Active=TRUE|Dir=Inbound|Protocol=TCP|LPort=22|Name=SSH"
    "RDP" = "v2.30|Action=Allow|Active=TRUE|Dir=Inbound|Protocol=TCP|LPort=3389|Name=RDP"
}

Write-Host "Configuring registry settings..." -ForegroundColor Green
foreach ($GPOName in $GPOs.Name) {
    Write-Host "  Configuring $GPOName"
    
    # Apply all common registry settings
    foreach ($RegPath in $RegSettings.Keys) {
        $PathParts = $RegPath -split '\\'
        $Key = ($PathParts[0..($PathParts.Count-2)] -join '\')
        $ValueName = $PathParts[-1]
        $Setting = $RegSettings[$RegPath]
        
        try {
            Set-GPRegistryValue -Name $GPOName -Key $Key -ValueName $ValueName -Type $Setting.Type -Value $Setting.Value -Context Computer
        } catch {
            Write-Warning "Failed to set $RegPath in $GPOName`: $($_.Exception.Message)"
        }
    }
    
    # Apply firewall rules
    foreach ($RuleName in $FirewallRules.Keys) {
        try {
            Set-GPRegistryValue -Name $GPOName -Key "HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall\FirewallRules" -ValueName $RuleName -Type String -Value $FirewallRules[$RuleName] -Context Computer
        } catch {
            Write-Warning "Failed to set firewall rule $RuleName in $GPOName`: $($_.Exception.Message)"
        }
    }
}

# Special settings for automation systems
Write-Host "Applying automation-specific settings..." -ForegroundColor Green
try {
    Set-GPRegistryValue -Name "SAE-Lab-Automation" -Key "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "EnableLUA" -Type DWord -Value 0 -Context Computer
    Set-GPRegistryValue -Name "SAE-Lab-Automation" -Key "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" -ValueName "LongPathsEnabled" -Type DWord -Value 1 -Context Computer
} catch {
    Write-Warning "Failed to apply automation-specific settings: $($_.Exception.Message)"
}

# Link GPOs to OUs
$Links = @{
    "SAE-Lab-Servers" = "OU=SAE-Servers,OU=SAE-Lab,$DomainDN"
    "SAE-Lab-Workstations" = "OU=SAE-Workstations,OU=SAE-Lab,$DomainDN"
    "SAE-Lab-Automation" = "OU=SAE-Automation,OU=SAE-Lab,$DomainDN"
}

Write-Host "Linking GPOs..." -ForegroundColor Green
foreach ($GPOName in $Links.Keys) {
    $TargetOU = $Links[$GPOName]
    
    try {
        $inheritance = Get-GPInheritance -Target $TargetOU
        $isLinked = $inheritance.GpoLinks | Where-Object {$_.DisplayName -eq $GPOName}
        
        if ($isLinked) {
            Write-Host "  $GPOName already linked to $TargetOU"
        } else {
            New-GPLink -Name $GPOName -Target $TargetOU -LinkEnabled Yes | Out-Null
            Write-Host "  Linked $GPOName to $TargetOU"
        }
    } catch {
        Write-Warning "Failed to link $GPOName to $TargetOU`: $($_.Exception.Message)"
    }
}

# Generate reports if requested
Write-Host "Generating reports..." -ForegroundColor Green
foreach ($GPOName in $GPOs.Name) {
    $ReportPath = Join-Path $ReportDir "$GPOName.html"
    try {
        Get-GPOReport -Name $GPOName -ReportType Html -Path $ReportPath
        Write-Host "  Report: $ReportPath"
    } catch {
        Write-Warning "Failed to generate report for $GPOName`: $($_.Exception.Message)"
    }
}

# Summary
Write-Host "`nDone. Next steps:" -ForegroundColor Yellow
Write-Host "1. Move computers to appropriate OUs:"
Write-Host "   Move-ADObject 'CN=ws22-tgt-01,CN=Computers,$DomainDN' -TargetPath 'OU=SAE-Servers,OU=SAE-Lab,$DomainDN'"
Write-Host "   Move-ADObject 'CN=w11-tgt-01,CN=Computers,$DomainDN' -TargetPath 'OU=SAE-Workstations,OU=SAE-Lab,$DomainDN'"
Write-Host "2. Force policy update: gpupdate /force"
Write-Host "3. Test Ansible: ansible windows_targets -m win_ping"
Write-Host "`nReports saved to: $ReportDir"