# --- Config & Setup ---
$configFile = "$PSScriptRoot\steam_config.ini"
$defaultSteamCmd = "C:\steamcmd\steamcmd.exe"
$defaultSteamPath = "C:\Program Files (x86)\Steam"

function Get-Config {
    $hash = @{ "LibraryPaths" = "" } 
    if (Test-Path $configFile) {
        Get-Content $configFile | ForEach-Object {
            $parts = $_ -split '=', 2
            if ($parts.Count -eq 2) { $hash[$parts[0].Trim()] = $parts[1].Trim() }
        }
    }
    return $hash
}

$config = Get-Config
$steamCmd = $config["SteamCmdPath"]
$username = $config["SteamUser"]
$libraryPathsString = $config["LibraryPaths"]

# 1. STEAMCMD CHECK
if (-not $steamCmd -or -not (Test-Path $steamCmd)) {
    if (Test-Path $defaultSteamCmd) { $steamCmd = $defaultSteamCmd } 
    else { $steamCmd = Read-Host "SteamCMD not found. Enter full path to steamcmd.exe" }
    "SteamCmdPath=$steamCmd" | Out-File $configFile
}

# 2. USERNAME CHECK
if (-not $username) { 
    $username = Read-Host "Enter your Steam Username"
    "SteamUser=$username" | Out-File $configFile -Append 
}

# 3. LIBRARY DETECTION
$libraryPaths = @()
if ([string]::IsNullOrWhiteSpace($libraryPathsString)) {
    $vdfPath = "$defaultSteamPath\steamapps\libraryfolders.vdf"
    if (Test-Path $vdfPath) {
        $vdfContent = Get-Content $vdfPath -Raw
        $matches = [regex]::Matches($vdfContent, '"path"\s+"([^"]+)"')
        foreach ($match in $matches) {
            $p = $match.Groups[1].Value.Replace("\\", "\")
            $fullPath = Join-Path $p "steamapps"
            if (Test-Path $fullPath) { $libraryPaths += $fullPath }
        }
    }
    if ($libraryPaths.Count -eq 0) { $libraryPaths += "$defaultSteamPath\steamapps" }
    "LibraryPaths=$($libraryPaths -join ',')" | Out-File $configFile -Append
} else {
    $libraryPaths = $libraryPathsString -split ","
}

# --- PROCESSING ---
$allManifests = foreach ($lib in $libraryPaths) {
    if (Test-Path $lib) { Get-ChildItem -Path $lib -Filter "appmanifest_*.acf" }
}

$total = $allManifests.Count
$current = 0
$startTime = Get-Date

Write-Host "Press Ctrl+C at any time to stop the script after the current game finishes." -ForegroundColor Gray

foreach ($file in $allManifests) {
    $current++
    $content = Get-Content $file.FullName -Raw
    if ($content -match '"appid"\s+"(\d+)"') { $appid = $Matches[1] }
    if ($content -match '"name"\s+"([^"]+)"') { $name = $Matches[1] }

    # Update Title
    $percent = [math]::Round(($current / $total) * 100)
    $Host.UI.RawUI.WindowTitle = "[$percent%] Steam Verifier - $name"

    Write-Host "`n====================================================" -ForegroundColor Gray
    Write-Host " ITEM $current OF $total ($percent%)" -ForegroundColor Yellow
    Write-Host " Validating: $name (ID: $appid)" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Gray

    # Using Start-Process allows the script to remain "in control" of the window
    # so that Ctrl+C can actually break the loop.
    $process = Start-Process -FilePath $steamCmd -ArgumentList "+login $username", "+app_update $appid validate", "+quit" -NoNewWindow -PassThru -Wait
    
    if ($process.ExitCode -eq 0) {
        Write-Host "Successfully verified $name" -ForegroundColor Green
    }
}

$elapsed = (Get-Date) - $startTime
$Host.UI.RawUI.WindowTitle = "Steam Verification Complete"
Write-Host "`n[FINISHED] Total time: $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
pause
