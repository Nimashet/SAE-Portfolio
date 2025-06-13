<#
	# Check for missing .gitkeep files
	.\check-gitkeep.ps1

	# Check with verbose output (shows all directories)
	.\check-gitkeep.ps1 -Verbose

	# Automatically create missing .gitkeep files
	.\check-gitkeep.ps1 -CreateMissing

	# Check a specific directory
	.\check-gitkeep.ps1 -Path "C:\Dev\SAE-Portfolio"

	# Create missing files in specific directory
	.\check-gitkeep.ps1 -Path "C:\Dev\SAE-Portfolio" -CreateMissing
#>

# Check for directories missing .gitkeep files in SAE-Portfolio
param(
    [string]$Path = ".",
    [switch]$CreateMissing,
    [switch]$Verbose
)

# Function to check if directory should have .gitkeep
function Should-HaveGitKeep {
    param([System.IO.DirectoryInfo]$Directory)
    
    # Skip these directories (they typically have content or are meant to be empty)
    $skipDirs = @(
        '.git', 
        'node_modules', 
        '.vscode', 
        '.devcontainer',
        'inventory\backup',  # Has timestamped backups
        'ansible\logs',      # Runtime logs, should be in .gitignore
        'ansible\vault'      # May contain sensitive files
    )
    
    $relativePath = $Directory.FullName.Replace((Get-Location).Path, "").TrimStart('\')
    
    # Skip if in exclude list
    foreach ($skip in $skipDirs) {
        if ($relativePath -like "*$skip*") {
            return $false
        }
    }
    
    # Check if directory is empty or only contains subdirectories
    $files = $Directory.GetFiles()
    $hasOnlySubdirs = ($files.Count -eq 0) -and ($Directory.GetDirectories().Count -gt 0)
    $isEmpty = ($files.Count -eq 0) -and ($Directory.GetDirectories().Count -eq 0)
    
    return $isEmpty -or $hasOnlySubdirs
}

# Main script
Write-Host "🔍 Checking for missing .gitkeep files in SAE-Portfolio..." -ForegroundColor Cyan
Write-Host "📂 Path: $(Resolve-Path $Path)" -ForegroundColor Gray
Write-Host ""

$missingGitKeep = @()
$totalChecked = 0
$created = 0

# Get all directories recursively
Get-ChildItem -Path $Path -Directory -Recurse | ForEach-Object {
    $dir = $_
    $totalChecked++
    
    if (Should-HaveGitKeep -Directory $dir) {
        $gitkeepPath = Join-Path $dir.FullName ".gitkeep"
        $relativePath = $dir.FullName.Replace((Get-Location).Path, "").TrimStart('\')
        
        if (-not (Test-Path $gitkeepPath)) {
            $missingGitKeep += $relativePath
            
            if ($CreateMissing) {
                New-Item -Path $gitkeepPath -ItemType File -Force | Out-Null
                Write-Host "✅ Created: $relativePath\.gitkeep" -ForegroundColor Green
                $created++
            } else {
                Write-Host "❌ Missing: $relativePath\.gitkeep" -ForegroundColor Red
            }
        } elseif ($Verbose) {
            Write-Host "✅ Found: $relativePath\.gitkeep" -ForegroundColor Green
        }
    }
}

# Summary
Write-Host ""
Write-Host "📊 Summary:" -ForegroundColor Cyan
Write-Host "   Directories checked: $totalChecked" -ForegroundColor Gray
Write-Host "   Missing .gitkeep files: $($missingGitKeep.Count)" -ForegroundColor $(if ($missingGitKeep.Count -eq 0) { "Green" } else { "Yellow" })

if ($CreateMissing -and $created -gt 0) {
    Write-Host "   Files created: $created" -ForegroundColor Green
    Write-Host ""
    Write-Host "💡 Don't forget to commit the new .gitkeep files:" -ForegroundColor Yellow
    Write-Host "   git add ." -ForegroundColor Gray
    Write-Host "   git commit -m 'Add missing .gitkeep files'" -ForegroundColor Gray
}

if ($missingGitKeep.Count -gt 0 -and -not $CreateMissing) {
    Write-Host ""
    Write-Host "💡 To create missing .gitkeep files automatically:" -ForegroundColor Yellow
    Write-Host "   .\check-gitkeep.ps1 -CreateMissing" -ForegroundColor Gray
}

if ($missingGitKeep.Count -eq 0) {
    Write-Host ""
    Write-Host "🎉 All directories have appropriate .gitkeep files!" -ForegroundColor Green
}