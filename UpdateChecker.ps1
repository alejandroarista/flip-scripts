# UpdateChecker.ps1
# Checks for new version, downloads and extracts zip, installs files,
# reconciles scheduled tasks, runs maintenance instructions.
# Supports URL migration with fallback chain.
# Runs silently - log only.
#
# Hosted at: https://raw.githubusercontent.com/alejandroarista/flip-scripts/main/UpdateChecker.txt

# -- Configuration -------------------------------------------------------------
$BootstrapUrl    = "https://raw.githubusercontent.com/alejandroarista/flip-scripts/main"
$LocalFolder     = "$env:APPDATA\FlipInversiones\Scripts"
$LogFolder       = "$env:APPDATA\FlipInversiones\Logs"
$ZipPassword     = "Z1pFl1P@2026`$`$%"
$VersionFile     = "$LocalFolder\last_version.txt"
$CurrentUrlFile  = "$LocalFolder\current_url.txt"
$PreviousUrlFile = "$LocalFolder\previous_url.txt"
$MaintLogFile    = "$LocalFolder\maintenance_log.txt"
$MaxRetries      = 3
$RetryDelay      = 5

# -- Force TLS 1.2 (required for HTTPS on older Windows versions) -------------
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# -- Ensure folders exist ------------------------------------------------------
foreach ($folder in @($LocalFolder, $LogFolder)) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}

# -- Logging -------------------------------------------------------------------
$LogFile = "$LogFolder\UpdateChecker_$(Get-Date -Format 'yyyy-MM').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
}

function Purge-OldLogs {
    $cutoff = (Get-Date).AddDays(-30)
    Get-ChildItem $LogFolder -Filter "UpdateChecker_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

# -- Helper: download with retries ---------------------------------------------
function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -UserAgent "Mozilla/5.0" -ErrorAction Stop
            return $true
        }
        catch {
            Write-Log "Download attempt $i/$MaxRetries failed for ${Url}: $_" "WARN"
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelay }
        }
    }
    return $false
}

# -- Helper: fetch version.txt from a base URL ---------------------------------
function Get-RemoteVersion {
    param([string]$BaseUrl)
    $tempFile = "$LocalFolder\version_temp.txt"
    if (-not (Invoke-Download -Url "$BaseUrl/version.txt" -OutFile $tempFile)) { return $null }
    $ver = (Get-Content $tempFile -ErrorAction SilentlyContinue).Trim()
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($ver)) { return $null }
    return $ver
}

# -- Helper: parse a value from any ini-style config ---------------------------
function Get-ConfigValue {
    param([string[]]$Lines, [string]$Section, [string]$Key)
    $inSection = $false
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\[(.+)\]$') {
            $inSection = $matches[1].Trim() -eq $Section
            continue
        }
        if ($inSection -and $line -match "^$Key\s*=\s*(.+)$") { return $matches[1].Trim() }
    }
    return $null
}

# -- Helper: check if maintenance ID already ran -------------------------------
function Test-MaintenanceDone {
    param([string]$Id)
    if (-not (Test-Path $MaintLogFile)) { return $false }
    return (Get-Content $MaintLogFile -ErrorAction SilentlyContinue) -match "^$Id\|"
}

# -- Helper: log completed maintenance instruction -----------------------------
function Write-MaintenanceLog {
    param([string]$Id, [string]$Action, [string]$Status)
    $entry = "$Id|$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|$Action|$Status"
    Add-Content -Path $MaintLogFile -Value $entry
}

# -- Helper: register a scheduled task ----------------------------------------
function Register-FlipTask {
    param([string]$TaskName, [string]$ScriptPath, [string]$Time)
    try {
        $taskUser    = "$env:USERDOMAIN\$env:USERNAME"
        $triggerTime = [datetime]::ParseExact($Time, "HH:mm", $null)
        $fullArgs    = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $action      = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $fullArgs
        $trigger     = New-ScheduledTaskTrigger -Daily -At $triggerTime
        $settings    = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 60) `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew
        $principal   = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest

        Register-ScheduledTask `
            -TaskName    $TaskName `
            -Action      $action `
            -Trigger     $trigger `
            -Settings    $settings `
            -Principal   $principal `
            -Description "Managed by FlipInversiones UpdateChecker." `
            | Out-Null

        Write-Log "  Registered task: $TaskName at $Time"
        return $true
    }
    catch {
        Write-Log "  Failed to register task '$TaskName': $_" "ERROR"
        return $false
    }
}

# -- Helper: expand environment variables in a string -------------------------
function Expand-EnvVars {
    param([string]$Value)
    return [System.Environment]::ExpandEnvironmentVariables($Value)
}

# -- Helper: parse all [maintenance] blocks from a config file ----------------
function Get-MaintenanceBlocks {
    param([string]$FilePath)
    $blocks  = [System.Collections.ArrayList]@()
    $current = $null
    foreach ($line in (Get-Content $FilePath -ErrorAction SilentlyContinue)) {
        $line = $line.Trim()
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\[instruction\]$') {
            if ($current) { [void]$blocks.Add($current) }
            $current = @{ Params = @{} }
            continue
        }
        if ($line -match '^\[params\]$') { continue }
        if ($current -and $line -match '^(.+?)\s*=\s*(.+)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            switch ($key) {
                "id"     { $current.Id     = $val }
                "action" { $current.Action = $val }
                "users"  { $current.Users  = $val }
                default  { $current.Params[$key] = $val }
            }
        }
    }
    if ($current) { [void]$blocks.Add($current) }
    return $blocks
}

# ==============================================================================
# MAIN
# ==============================================================================
Write-Log "---- Update check started ----"
Purge-OldLogs

try {
    # -- Resolve URL chain: current -> previous -> bootstrap -------------------
    $currentUrl  = if (Test-Path $CurrentUrlFile)  { (Get-Content $CurrentUrlFile  -ErrorAction SilentlyContinue).Trim() } else { $null }
    $previousUrl = if (Test-Path $PreviousUrlFile) { (Get-Content $PreviousUrlFile -ErrorAction SilentlyContinue).Trim() } else { $null }

    $urlChain = [System.Collections.ArrayList]@()
    if ($currentUrl)                                          { [void]$urlChain.Add($currentUrl) }
    if ($previousUrl -and $previousUrl -ne $currentUrl)      { [void]$urlChain.Add($previousUrl) }
    if ($BootstrapUrl -notin $urlChain)                      { [void]$urlChain.Add($BootstrapUrl) }

    $activeUrl     = $null
    $remoteVersion = $null

    foreach ($url in $urlChain) {
        Write-Log "Trying URL: $url"
        $ver = Get-RemoteVersion -BaseUrl $url
        if ($ver) {
            $activeUrl     = $url
            $remoteVersion = $ver
            Write-Log "Reachable. Remote version: $remoteVersion"
            break
        }
        Write-Log "Unreachable: $url" "WARN"
    }

    if (-not $activeUrl) {
        Write-Log "All URLs unreachable. Using local version." "WARN"
        exit 0
    }

    # -- Compare versions ------------------------------------------------------
    $localVersion = if (Test-Path $VersionFile) { (Get-Content $VersionFile -ErrorAction SilentlyContinue).Trim() } else { "" }
    Write-Log "Local version: $(if ($localVersion) { $localVersion } else { '(none)' })"

    if ($remoteVersion -eq $localVersion) {
        Write-Log "Already up to date."
        if ($activeUrl -ne $currentUrl) {
            if ($currentUrl) { Set-Content $PreviousUrlFile $currentUrl -ErrorAction SilentlyContinue }
            Set-Content $CurrentUrlFile $activeUrl -ErrorAction SilentlyContinue
            Write-Log "URL updated to active: $activeUrl"
        }
    }
    else {
        # -- Download zip ------------------------------------------------------
        $zipUrl   = "$activeUrl/$remoteVersion"
        $zipLocal = "$LocalFolder\$remoteVersion"

        Write-Log "Downloading $remoteVersion..."
        if (-not (Invoke-Download -Url $zipUrl -OutFile $zipLocal)) {
            Write-Log "Failed to download zip. Keeping current version." "ERROR"
            exit 1
        }

        $zipSize = (Get-Item $zipLocal -ErrorAction SilentlyContinue).Length
        if ($zipSize -lt 100) {
            Write-Log "Zip appears corrupt ($zipSize bytes). Aborting." "ERROR"
            Remove-Item $zipLocal -Force -ErrorAction SilentlyContinue
            exit 1
        }
        Write-Log "Download complete ($zipSize bytes)."

        # -- Extract zip using 7-Zip -----------------------------------------------
        $extractPath = "$LocalFolder\extract_temp"
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

        # Find 7-Zip executable
        $sevenZip = $null
        $sevenZipPaths = @(
            "C:\Program Files\7-Zip\7z.exe",
            "C:\Program Files (x86)\7-Zip\7z.exe"
        )
        foreach ($path in $sevenZipPaths) {
            if (Test-Path $path) { $sevenZip = $path; break }
        }

        # If 7-Zip not found, download and install silently
        if (-not $sevenZip) {
            Write-Log "7-Zip not found. Downloading installer..."
            $szInstaller = "$LocalFolder\7z-installer.exe"
            $szUrl = "https://www.7-zip.org/a/7z2409-x64.exe"
            try {
                Invoke-WebRequest -Uri $szUrl -OutFile $szInstaller -UseBasicParsing -UserAgent "Mozilla/5.0" -ErrorAction Stop
                Write-Log "Installing 7-Zip silently..."
                Start-Process -FilePath $szInstaller -ArgumentList "/S" -Wait -NoNewWindow
                Remove-Item $szInstaller -Force -ErrorAction SilentlyContinue
                foreach ($path in $sevenZipPaths) {
                    if (Test-Path $path) { $sevenZip = $path; break }
                }
                if (-not $sevenZip) { throw "7-Zip installation failed." }
                Write-Log "7-Zip installed successfully."
            }
            catch {
                Write-Log "Could not install 7-Zip: $_" "ERROR"
                Remove-Item $zipLocal    -Force -ErrorAction SilentlyContinue
                Remove-Item $extractPath -Force -ErrorAction SilentlyContinue
                exit 1
            }
        }

        Write-Log "Extracting with 7-Zip..."
        try {
            $szArgs = "x `"$zipLocal`" -o`"$extractPath`" -p`"$ZipPassword`" -y"
            $proc   = Start-Process -FilePath $sevenZip -ArgumentList $szArgs -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -ne 0) { throw "7-Zip exited with code $($proc.ExitCode)." }

            $extracted = @(Get-ChildItem $extractPath -Recurse -File -ErrorAction SilentlyContinue)
            if ($extracted.Count -eq 0) { throw "Extraction produced no files." }
            Write-Log "Extracted $($extracted.Count) file(s)."
        }
        catch {
            Write-Log "Extraction failed: $_" "ERROR"
            Remove-Item $zipLocal    -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item $extractPath -Force -Recurse -ErrorAction SilentlyContinue
            exit 1
        }

        # -- Install files preserving folder structure -------------------------
        Write-Log "Installing files..."
        Get-ChildItem $extractPath -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($extractPath.Length).TrimStart('\')
            $dest         = Join-Path $LocalFolder $relativePath
            $destDir      = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            try {
                Copy-Item $_.FullName -Destination $dest -Force -ErrorAction Stop
                Write-Log "  Installed: $relativePath"
            }
            catch {
                Write-Log "  Failed to install $relativePath : $_" "ERROR"
            }
        }

        # -- Check config.txt for URL migration --------------------------------
        $configPath = "$LocalFolder\config.txt"
        if (Test-Path $configPath) {
            $configLines  = Get-Content $configPath -ErrorAction SilentlyContinue
            $configNewUrl = Get-ConfigValue -Lines $configLines -Section "defaults" -Key "BaseUrl"
            if ($configNewUrl -and $configNewUrl -ne $activeUrl) {
                Write-Log "New BaseUrl in config: $configNewUrl - validating..."
                $testVer = Get-RemoteVersion -BaseUrl $configNewUrl
                if ($testVer) {
                    Write-Log "New URL reachable. Promoting: $activeUrl -> $configNewUrl"
                    Set-Content $PreviousUrlFile $activeUrl    -ErrorAction SilentlyContinue
                    Set-Content $CurrentUrlFile  $configNewUrl -ErrorAction SilentlyContinue
                }
                else {
                    Write-Log "New URL unreachable. Keeping: $activeUrl" "WARN"
                    Set-Content $CurrentUrlFile $activeUrl -ErrorAction SilentlyContinue
                }
            }
            else {
                Set-Content $CurrentUrlFile $activeUrl -ErrorAction SilentlyContinue
            }
        }

        # -- Save new version --------------------------------------------------
        Set-Content $VersionFile $remoteVersion -ErrorAction SilentlyContinue
        Write-Log "Version updated: $(if ($localVersion) { $localVersion } else { '(none)' }) -> $remoteVersion"

        # -- Cleanup -----------------------------------------------------------
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zipLocal    -Force         -ErrorAction SilentlyContinue
        if ($localVersion -and $localVersion -ne $remoteVersion) {
            $oldZip = "$LocalFolder\$localVersion"
            if (Test-Path $oldZip) {
                Remove-Item $oldZip -Force -ErrorAction SilentlyContinue
                Write-Log "Removed old zip: $localVersion"
            }
        }

        Write-Log "Update complete."
    }

    # -- Reconcile scheduled tasks from tasks.json ----------------------------
    $tasksJsonPath = "$LocalFolder\tasks.json"
    if (Test-Path $tasksJsonPath) {
        Write-Log "Reconciling scheduled tasks..."
        try {
            $taskDefs = Get-Content $tasksJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($taskDef in $taskDefs) {
                $existing = Get-ScheduledTask -TaskName $taskDef.Name -ErrorAction SilentlyContinue
                if ($existing) {
                    Write-Log "  Task exists: $($taskDef.Name)"
                }
                else {
                    $scriptPath = "$LocalFolder\$($taskDef.Script)"
                    Register-FlipTask -TaskName $taskDef.Name -ScriptPath $scriptPath -Time $taskDef.Time
                }
            }
        }
        catch {
            Write-Log "Failed to process tasks.json: $_" "ERROR"
        }
    }

    # -- Run maintenance instructions ------------------------------------------
    $maintFolder = "$LocalFolder\maintenance"
    if (Test-Path $maintFolder) {
        Write-Log "Processing maintenance instructions..."
        Get-ChildItem $maintFolder -Filter "*.config.txt" -ErrorAction SilentlyContinue | ForEach-Object {
            $blocks = Get-MaintenanceBlocks -FilePath $_.FullName
            foreach ($block in $blocks) {
                $id     = $block.Id
                $action = $block.Action
                $users  = $block.Users
                $params = $block.Params

                if (-not $id -or -not $action) {
                    Write-Log "  Skipping incomplete instruction in $($_.Name)" "WARN"
                    continue
                }

                # Check if already ran
                if (Test-MaintenanceDone -Id $id) {
                    Write-Log "  [$id] Already completed - skipping."
                    continue
                }

                # Check user match
                $userMatch = ($users -eq "*") -or ($users.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $env:USERNAME })
                if (-not $userMatch) {
                    Write-Log "  [$id] Not targeted at user '$env:USERNAME' - skipping."
                    continue
                }

                Write-Log "  [$id] Running: $action"
                $actionScript = "$LocalFolder\modules\$action"

                if (-not (Test-Path $actionScript)) {
                    Write-Log "  [$id] Script not found: $actionScript" "ERROR"
                    Write-MaintenanceLog -Id $id -Action $action -Status "ERROR: script not found"
                    continue
                }

                # Build parameter string
                $paramString = ($params.GetEnumerator() | ForEach-Object {
                    $val = Expand-EnvVars $_.Value
                    "-$($_.Key) `"$val`""
                }) -join " "

                try {
                    $result = & powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass `
                        -File $actionScript $paramString 2>&1
                    Write-Log "  [$id] Completed successfully."
                    Write-MaintenanceLog -Id $id -Action $action -Status "OK"
                }
                catch {
                    Write-Log "  [$id] Failed: $_" "ERROR"
                    Write-MaintenanceLog -Id $id -Action $action -Status "ERROR: $_"
                }
            }
        }
    }
}
catch {
    Write-Log "Unexpected error: $_" "ERROR"
    exit 1
}
finally {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Write-Log "---- Update check finished ----"
}
