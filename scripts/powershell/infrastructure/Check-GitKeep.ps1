<#
.SYNOPSIS
    Check and manage .gitkeep files in SAE Portfolio

.DESCRIPTION
    Validates .gitkeep files for proper git synchronization to remote dev containers.
    Uses conservative approach - only manages files in safe structural directories.
    
    SECURITY NOTE: This script will NOT auto-create .gitkeep files in directories
    that might contain sensitive data (secrets, credentials, logs, etc.)

.PARAMETER CreateMissing
    Auto-create missing .gitkeep files in safe directories

.PARAMETER Verbose
    Show all found .gitkeep files, not just missing ones

.EXAMPLE
    .\Check-GitKeep.ps1
    Check for issues without making changes

.EXAMPLE
    .\Check-GitKeep.ps1 -CreateMissing
    Create missing .gitkeep files in safe directories

.EXAMPLE
    .\Check-GitKeep.ps1 -Verbose
    Show detailed output including all found files

.NOTES
    - Must run from C:\dev\sae-portfolio root directory
    - Will NOT delete existing .gitkeep files (only warns about unsafe locations)
    - Only creates .gitkeep in empty directories within safe structural areas
    - Validates required .gitkeep files specified in .gitignore exceptions
    
    SAFE DIRECTORIES (auto-create allowed):
    - scripts/, docs/, examples/
    - terraform/modules/, ansible/playbooks/, ansible/roles/
    
    UNSAFE DIRECTORIES (warning only):
    - secrets/, credentials/, vault/, keys/, logs/, backup/
    - host_vars/, environments/, .git/, .vscode/, node_modules/
#>

param(
    [switch]$CreateMissing,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# Must run from C:\dev\sae-portfolio
if (!(Test-Path "ansible") -or !(Test-Path "scripts")) {
    throw "Run this from C:\dev\sae-portfolio root directory"
}

# Directories that should NEVER have auto-created .gitkeep (security risk)
$UnsafeDirs = @(
    'secrets', 'credentials', 'vault', 'keys', 'certs', 'ssl',
    'logs', 'log', 'tmp', 'temp', 'backup',
    'host_vars', 'environments',
    '.git', '.vscode', '.idea', 'node_modules'
)

# Required .gitkeep files (from .gitignore negations)
$RequiredGitKeep = @(
    'ansible\inventory\group_vars\environments\.gitkeep',
    'ansible\inventory\host_vars\.gitkeep'
)

# Safe structural directories where we can auto-create .gitkeep
$SafeDirs = @(
    'scripts', 'docs', 'examples', 'terraform\modules',
    'ansible\playbooks', 'ansible\roles'
)

Write-Host "Checking .gitkeep files in SAE Portfolio..." -ForegroundColor Green

$issues = 0
$created = 0

# Check required .gitkeep files first
Write-Host "`nValidating required .gitkeep files:" -ForegroundColor Yellow
foreach ($required in $RequiredGitKeep) {
    if (Test-Path $required) {
        if ($Verbose) { Write-Host "  Found: $required" -ForegroundColor Green }
    } else {
        Write-Host "  MISSING: $required" -ForegroundColor Red
        Write-Host "    This file is required by .gitignore exceptions" -ForegroundColor Gray
        $issues++
    }
}

# Check for .gitkeep in unsafe directories
Write-Host "`nChecking for .gitkeep in potentially unsafe directories:" -ForegroundColor Yellow
Get-ChildItem -Directory -Recurse | Where-Object {
    $dirPath = $_.FullName.Replace((Get-Location).Path, '').TrimStart('\')
    $unsafe = $false
    foreach ($unsafePattern in $UnsafeDirs) {
        if ($dirPath -like "*$unsafePattern*") {
            $unsafe = $true
            break
        }
    }
    $unsafe -and (Test-Path (Join-Path $_.FullName '.gitkeep'))
} | ForEach-Object {
    $relativePath = $_.FullName.Replace((Get-Location).Path, '').TrimStart('\')
    Write-Host "  WARNING: $relativePath\.gitkeep" -ForegroundColor Red
    Write-Host "    This directory might contain sensitive data" -ForegroundColor Gray
    $issues++
}

# Find empty directories in safe areas
Write-Host "`nChecking safe structural directories:" -ForegroundColor Yellow
foreach ($safeDir in $SafeDirs) {
    if (Test-Path $safeDir) {
        Get-ChildItem -Path $safeDir -Directory -Recurse | Where-Object {
            # Check if directory is completely empty
            $files = $_.GetFiles()
            $subdirs = $_.GetDirectories()
            ($files.Count -eq 0 -and $subdirs.Count -eq 0)
        } | ForEach-Object {
            $gitkeepPath = Join-Path $_.FullName '.gitkeep'
            $relativePath = $_.FullName.Replace((Get-Location).Path, '').TrimStart('\')
            
            if (Test-Path $gitkeepPath) {
                if ($Verbose) { Write-Host "  Found: $relativePath\.gitkeep" -ForegroundColor Green }
            } else {
                if ($CreateMissing) {
                    try {
                        New-Item -Path $gitkeepPath -ItemType File | Out-Null
                        Write-Host "  Created: $relativePath\.gitkeep" -ForegroundColor Green
                        $created++
                    } catch {
                        Write-Host "  Failed to create: $relativePath\.gitkeep" -ForegroundColor Red
                        $issues++
                    }
                } else {
                    Write-Host "  Missing: $relativePath\.gitkeep" -ForegroundColor Yellow
                    $issues++
                }
            }
        }
    }
}

# Summary
Write-Host "`nSummary:" -ForegroundColor Cyan
if ($issues -eq 0) {
    Write-Host "  All .gitkeep files are properly managed" -ForegroundColor Green
} else {
    Write-Host "  Issues found: $issues" -ForegroundColor Yellow
}

if ($created -gt 0) {
    Write-Host "  Files created: $created" -ForegroundColor Green
    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  git add ."
    Write-Host "  git commit -m 'Add missing .gitkeep files'"
}

if ($issues -gt 0 -and !$CreateMissing) {
    Write-Host "`nTo auto-create missing .gitkeep files:" -ForegroundColor Yellow
    Write-Host "  .\Check-GitKeep.ps1 -CreateMissing"
}