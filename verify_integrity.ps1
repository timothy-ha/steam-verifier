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
		$libMatches = [regex]::Matches($vdfContent, '"path"\s+"([^"]+)"')
		foreach ($match in $libMatches) {
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

# 4. RESULTS LOG
# Per-game steamcmd output goes to logs\<appid>.log, outcomes to logs\results.csv.
# Games already recorded as OK are skipped, so an interrupted run can be resumed.
$logDir = "$PSScriptRoot\logs"
$resultsFile = "$logDir\results.csv"
$steamCmdLog = Join-Path (Split-Path $steamCmd) "logs\console_log.txt"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$verified = @{}
if (Test-Path $resultsFile) {
	Import-Csv $resultsFile | Where-Object { $_.Result -eq "OK" } | ForEach-Object { $verified[$_.AppId] = $true }
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
	# Reset per game so an unreadable manifest can't reuse the previous game's values
	$appid = $null; $name = $null; $installDirName = $null
	$content = Get-Content $file.FullName -Raw
	if ($content -match '"appid"\s+"(\d+)"') { $appid = $Matches[1] }
	if ($content -match '"name"\s+"([^"]+)"') { $name = $Matches[1] }
	if ($content -match '"installdir"\s+"([^"]+)"') { $installDirName = $Matches[1] }
	if (-not $appid -or -not $installDirName) {
		Write-Host "`nSkipping unreadable manifest: $($file.FullName)" -ForegroundColor Red
		continue
	}
	if ($verified[$appid]) {
		Write-Host "`nAlready verified OK, skipping: $name (ID: $appid)" -ForegroundColor DarkGray
		continue
	}
	$parentLib = Split-Path $file.FullName
	$gamePath = Join-Path $parentLib "common\$installDirName"
	# steamcmd creates a steamapps\ folder inside force_install_dir; remove it afterwards if we created it
	$steamCmdDir = Join-Path $gamePath "steamapps"
	$steamCmdDirExisted = Test-Path $steamCmdDir
	$logStart = if (Test-Path $steamCmdLog) { (Get-Item $steamCmdLog).Length } else { 0 }

	# Update Title
	$percent = [math]::Round(($current / $total) * 100)
	$Host.UI.RawUI.WindowTitle = "[$percent%] Steam Verifier - $name"

	Write-Host "`n====================================================" -ForegroundColor Gray
	Write-Host " ITEM $current OF $total ($percent%)" -ForegroundColor Yellow
	Write-Host " Validating: $name (ID: $appid)" -ForegroundColor Cyan
	Write-Host "====================================================" -ForegroundColor Gray

	$process = $null
	try 	{
		$argList = "+force_install_dir `"$gamePath`"", "+login $username", "+app_update $appid validate", "+quit"
		$process = Start-Process -FilePath $steamcmd -ArgumentList $argList -NoNewWindow -PassThru
		$process | Wait-Process
	} 
	finally {
		if ($process -and -not $process.HasExited) {
            Write-Host "`nStopping SteamCMD..." -ForegroundColor Red
            $process | Stop-Process -Force
        }
		if (-not $steamCmdDirExisted -and (Test-Path $steamCmdDir)) {
			Remove-Item $steamCmdDir -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	# Pull this game's portion of steamcmd's console log and record the outcome
	$gameLog = ""
	if (Test-Path $steamCmdLog) {
		$stream = [System.IO.File]::Open($steamCmdLog, 'Open', 'Read', 'ReadWrite')
		try {
			$stream.Position = [math]::Min($logStart, $stream.Length)
			$gameLog = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
		} finally { $stream.Close() }
	}
	$gameLog | Out-File "$logDir\$appid.log"
	$detail = ([regex]::Matches($gameLog, "(Success! App '$appid'[^\r\n]*|Error! App '$appid'[^\r\n]*|FAILED[^\r\n]*)") | Select-Object -Last 1).Value
	$result = if ($detail -like "Success!*") { "OK" } else { "FAILED" }
	[pscustomobject]@{ AppId = $appid; Name = $name; Result = $result; Detail = $detail; Time = (Get-Date -Format s) } |
		Export-Csv $resultsFile -Append -NoTypeInformation
	$color = if ($result -eq "OK") { "Green" } else { "Red" }
	Write-Host " Result: $result $detail" -ForegroundColor $color

	# A failed login means every remaining game would fail too
	if ($gameLog -match "FAILED \(|Login Failure|Invalid Password") {
		Write-Host "`nSteam login failed - stopping. Run: steamcmd +login $username +quit" -ForegroundColor Red
		break
	}
}

$elapsed = (Get-Date) - $startTime
$Host.UI.RawUI.WindowTitle = "Steam Verification Complete"
Write-Host "`n[FINISHED] Total time: $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
$failed = @(Import-Csv $resultsFile | Group-Object AppId | ForEach-Object { $_.Group[-1] } | Where-Object { $_.Result -ne "OK" })
if ($failed.Count -gt 0) {
	Write-Host "`n$($failed.Count) game(s) did not report success:" -ForegroundColor Red
	$failed | ForEach-Object { Write-Host "  $($_.Name) (ID: $($_.AppId)) $($_.Detail)" -ForegroundColor Red }
} else {
	Write-Host "All games reported success. Results: $resultsFile" -ForegroundColor Green
}
pause
