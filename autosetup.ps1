# Fetched fresh by every worker's permanent AutoSetup .bat on every run
# (GET /autosetup.ps1, see do_GET in bot.py) instead of this whole install
# sequence being baked into every personalized .bat file (2026-09-18). The
# .bat itself now only ever holds that one worker's -WorkerId and a tiny
# "download this file and run it" bootstrapper -- it never needs to be
# regenerated/redistributed again. Any future change to what AutoSetup
# actually DOES (new software, different defender settings, extra steps)
# only ever needs an edit HERE, same reasoning already established for
# launch_software.ps1/watcher.ps1 (see their own matching header comments).
param(
    [string]$WorkerId,
    # 2026-10-16: a CLIENT worker's bootstrapper passes its own watcher address
    # (http://<vps>:8765/client/w/<token>/event) + token. Empty = main bot.
    [string]$ServerUrl = '',
    [string]$Secret = ''
)
$IsClient = [bool]$ServerUrl
if (-not $ServerUrl) { $ServerUrl = 'miami2.visihost.in:2610/event' }
if (-not $Secret)    { $Secret    = '77d6522e7e2f05b4018d39f3290bf9f7c2ac250b27a473246a3143f95b66990b' }

# ===================== MANUAL MODE (2026-10-15) =====================
# $true  -> AutoSetup is OFF: this script shows a notice and exits, so NOTHING
#           installs or starts (no watcher/Python/Chrome/software) even if a
#           worker runs their AutoSetup .bat. Use this on manual-work days.
# $false -> normal AutoSetup.
# Toggle from Telegram: Admin menu -> Settings -> AutoSetup button (flips the
# flag line below). This flag line is the ONLY one at column 0 on purpose.
$MANUAL_MODE = $false
if ($MANUAL_MODE -and -not $IsClient) {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "     AAJ MANUAL KAAM HAI -- koi setup nahi chalana." -ForegroundColor Yellow
    Write-Host "     Emails bot par hi aayengi, wahi se kaam karo." -ForegroundColor Yellow
    Write-Host "     (AutoSetup band hai: kuch install/start nahi hoga.)" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host ""
    Start-Sleep -Seconds 6
    exit
}
# ====================================================================

# ------- AutoSetup components (2026-10-15) -------
# $true = install/run that part, $false = skip it. Toggle from Telegram:
# Admin menu -> Settings -> AutoSetup -> Components. Each is the ONLY
# column-0 line with its name (the bot flips it by regex).
$DO_WINRAR = $true
$DO_TELEGRAM = $true
$DO_PYTHON = $true
$DO_CHROME = $true
$DO_WKHTML = $true
$DO_WATCHER = $true
# -------------------------------------------------

function Show-Progress($step, $total, $msg) {
    $pct = [int](($step / $total) * 100)
    $bar = '#' * [int]($pct / 5)
    $empty = '-' * (20 - $bar.Length)
    Write-Host "`r  [$bar$empty] $pct%  $msg                              " -NoNewline -ForegroundColor Cyan
}
function Download-File($url, $dest) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -UserAgent 'Mozilla/5.0' | Out-Null
}
function Start-DownloadJob($url, $dest) {
    return Start-Job -ScriptBlock {
        param($u, $d)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $u -OutFile $d -UseBasicParsing -UserAgent 'Mozilla/5.0'
    } -ArgumentList $url, $dest
}
function Install-Silent($installer, $installArgs) {
    Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -WindowStyle Hidden | Out-Null
}
$pyLatest = '3.14.8'
function Get-PythonCmd {
    # Latest install first, so after an update we use it even if an older
    # Python sits earlier on the PATH.
    $p314 = "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe"
    if (Test-Path $p314) { return $p314 }
    foreach ($c in @('python', 'py', 'python3')) {
        try { $t = & $c --version 2>&1; if ($t -match 'Python 3') { return $c } } catch {}
    }
    foreach ($p in @("$env:LOCALAPPDATA\Programs\Python\Python311\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe", "C:\Python311\python.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}
function Test-PythonLatest($cmd) {
    try {
        $t = & $cmd --version 2>&1
        if ("$t" -match 'Python (\d+\.\d+\.\d+)') { return ([version]$matches[1] -ge [version]$pyLatest) }
    } catch {}
    return $false
}
function Test-DownloadOk($path) {
    return (Test-Path $path) -and ((Get-Item $path).Length -gt 100000)
}

$tempDir   = "$env:TEMP\autosetup"
$total     = 8
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

Clear-Host
Write-Host ''
Write-Host '  Auto Setup' -ForegroundColor White
Write-Host '  ----------' -ForegroundColor DarkGray
Write-Host ''

$workerId = $WorkerId

# Fresh-machine detection (2026-09-18) -- see the marker-write block near
# the end of this script for the full reasoning. Checked here (side-effect-
# free, just a Test-Path) so a mid-script failure that forces a re-run
# still sees "fresh" on retry -- the marker itself only gets WRITTEN once
# the whole setup has actually succeeded, at the bottom.
$ebInstallDir = Join-Path $env:LOCALAPPDATA "EmailBotWatcher"
$ebMarkerFile = Join-Path $ebInstallDir "autosetup_marker.txt"
$freshMachine = -not (Test-Path -LiteralPath $ebMarkerFile)

try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop } catch {}
try { Set-MpPreference -MAPSReporting Disabled -ErrorAction Stop } catch {}
try { Set-MpPreference -SubmitSamplesConsent NeverSend -ErrorAction Stop } catch {}
try { Set-MpPreference -PerformanceModeStatus Disabled -ErrorAction Stop } catch {}

Show-Progress 1 $total 'Checking installed software...'
$winrarInstalled = Test-Path 'C:\Program Files\WinRAR\WinRAR.exe'
$t1 = "$env:APPDATA\Telegram Desktop\Telegram.exe"
$t2 = "$env:LOCALAPPDATA\Telegram Desktop\Telegram.exe"
$telegramInstalled = (Test-Path $t1) -or (Test-Path $t2)
$pythonCmd = Get-PythonCmd
# Old Python counts as "not installed" -> latest gets installed alongside.
$pythonInstalled = [bool]$pythonCmd -and (Test-PythonLatest $pythonCmd)
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$chromeInstalled = [bool]($chromePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
$wkhtmlInstalled = (Test-Path 'C:\Program Files\wkhtmltopdf\bin\wkhtmltopdf.exe') -or (Test-Path 'C:\Program Files (x86)\wkhtmltopdf\bin\wkhtmltopdf.exe')

if ($DO_WATCHER) {
Show-Progress 1 $total 'Auto-tracker chalu kar raha hoon...'
$watcherStage = "$env:TEMP\emailbot_watcher_stage"
if (-not (Test-Path $watcherStage)) { New-Item -ItemType Directory -Path $watcherStage | Out-Null }
try {
    Download-File ($ServerUrl -replace '/event$', '/watcher.ps1') "$watcherStage\watcher.ps1"
    $watcherCfg = @{ user_id = $workerId; server_url = $ServerUrl; secret = $Secret } | ConvertTo-Json
    Set-Content -Path "$watcherStage\watcher_config.json" -Value $watcherCfg
    $q = '"'
    $vbsPath = "$watcherStage\launch_hidden.vbs"
    $vbsLine1 = 'Set objShell = CreateObject("WScript.Shell")'
    $vbsLine2 = 'objShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -File ' + $q + $q + "$watcherStage\watcher.ps1" + $q + $q + '", 0, False'
    Set-Content -Path $vbsPath -Value @($vbsLine1, $vbsLine2) -Encoding ASCII
    Start-Process wscript.exe -ArgumentList @($vbsPath)
} catch {
    $errMsg = $_.Exception.Message
    Add-Content -Path "$env:TEMP\watcher_setup_error.log" -Value $errMsg
    Write-Host ''
    Write-Host '  Watcher setup error: ' -NoNewline -ForegroundColor Red
    Write-Host $errMsg -ForegroundColor Red
    Start-Sleep -Seconds 4
}

}

$dlJobs = @{}
if ($DO_WINRAR -and -not $winrarInstalled) { $dlJobs['winrar'] = Start-DownloadJob 'https://www.win-rar.com/fileadmin/winrar-versions/winrar/winrar-x64-701.exe' "$tempDir\winrar.exe" }
if ($DO_TELEGRAM -and -not $telegramInstalled) { $dlJobs['telegram'] = Start-DownloadJob 'https://github.com/telegramdesktop/tdesktop/releases/download/v6.7.8/tsetup-x64.6.7.8.exe' "$tempDir\telegram.exe" }
if ($DO_PYTHON -and -not $pythonInstalled) { $dlJobs['python'] = Start-DownloadJob 'https://www.python.org/ftp/python/3.14.8/python-3.14.8-amd64.exe' "$tempDir\python.exe" }
# Google Chrome -- the small ONLINE stub installer (chrome_installer.exe,
# ~13 MB, needsadmin=prefers -> no-admin per-user install). 2026-10-22: was the
# 169 MB standalone offline installer, which timed out inside the shared 240 s
# parallel-download window on slow RDPs and got skipped. The 13 MB stub
# downloads fast; it fetches the full Chrome during the (un-timed) install.
if ($DO_CHROME -and -not $chromeInstalled) { $dlJobs['chrome'] = Start-DownloadJob 'https://dl.google.com/chrome/install/latest/chrome_installer.exe' "$tempDir\chrome.exe" }
# wkhtmltopdf + wkhtmltoimage -- official win64 installer (~28 MB, NSIS, silent /S)
if ($DO_WKHTML -and -not $wkhtmlInstalled) { $dlJobs['wkhtml'] = Start-DownloadJob 'https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox-0.12.6-1.msvc2015-win64.exe' "$tempDir\wkhtml.exe" }

$dlFailed = @{}
if ($dlJobs.Count -gt 0) {
    Show-Progress 1 $total 'Downloading installers (parallel)...'
    $dlJobs.Values | Wait-Job -Timeout 240 | Out-Null
    foreach ($key in @($dlJobs.Keys)) {
        $j = $dlJobs[$key]
        if ($j.State -eq 'Running') {
            $dlFailed[$key] = 'timed out'
            try { Stop-Job $j -ErrorAction SilentlyContinue } catch {}
        } else {
            try { Receive-Job $j -ErrorAction Stop | Out-Null } catch { $dlFailed[$key] = $_.Exception.Message }
        }
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
}

Show-Progress 2 $total 'Checking WinRAR...'
if ($DO_WINRAR -and -not $winrarInstalled) {
    if ($dlFailed.ContainsKey('winrar') -or -not (Test-DownloadOk "$tempDir\winrar.exe")) {
        Write-Host ''
        Write-Host '  x WinRAR download fail/incomplete -- skip kar raha hoon.' -ForegroundColor Red
    } else {
        Show-Progress 2 $total 'Installing WinRAR...'
        Install-Silent "$tempDir\winrar.exe" '/S'
    }
}

Show-Progress 3 $total 'Checking Telegram...'
if ($DO_TELEGRAM -and -not $telegramInstalled) {
    if ($dlFailed.ContainsKey('telegram') -or -not (Test-DownloadOk "$tempDir\telegram.exe")) {
        Write-Host ''
        Write-Host '  x Telegram download fail/incomplete -- skip kar raha hoon.' -ForegroundColor Red
    } else {
        Show-Progress 3 $total 'Installing Telegram...'
        Install-Silent "$tempDir\telegram.exe" '/VERYSILENT /NORESTART'
    }
}
$telegramExe = if (Test-Path "$env:APPDATA\Telegram Desktop\Telegram.exe") { "$env:APPDATA\Telegram Desktop\Telegram.exe" } else { "$env:LOCALAPPDATA\Telegram Desktop\Telegram.exe" }
$telegramShortcut = "$env:USERPROFILE\Desktop\Telegram.lnk"
if ((Test-Path $telegramExe) -and (-not (Test-Path $telegramShortcut))) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($telegramShortcut)
        $sc.TargetPath = $telegramExe
        $sc.Save()
    } catch {}
}

Show-Progress 4 $total 'Checking Python...'
if ($DO_PYTHON -and -not $pythonInstalled) {
    if ($dlFailed.ContainsKey('python') -or -not (Test-DownloadOk "$tempDir\python.exe")) {
        Write-Host ''
        Write-Host '  x Python download fail/incomplete -- skip kar raha hoon.' -ForegroundColor Red
    } else {
        Show-Progress 4 $total "Installing Python $pyLatest..."
        Start-Process -FilePath "$tempDir\python.exe" -ArgumentList '/quiet InstallAllUsers=0 PrependPath=1 Include_launcher=0' -Wait -WindowStyle Hidden
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        Start-Sleep -Seconds 3
        $pythonCmd = Get-PythonCmd
    }
}

Show-Progress 5 $total 'Updating Python tools...'
if ($DO_PYTHON) {
& $pythonCmd -m pip install --upgrade pip -q --disable-pip-version-check 2>&1 | Out-Null
}

# BM2/SendForge auto-install for EVERYONE removed 2026-10-02. Since
# 2026-10-09 they come back per team only, via Team Software (step 9).

Show-Progress 6 $total 'Checking Chrome...'
if ($DO_CHROME -and -not $chromeInstalled) {
    if ($dlFailed.ContainsKey('chrome') -or -not (Test-DownloadOk "$tempDir\chrome.exe")) {
        Write-Host ''
        Write-Host '  x Chrome download fail/incomplete -- skip kar raha hoon.' -ForegroundColor Red
    } else {
        Show-Progress 6 $total 'Installing Chrome...'
        # The stub downloads the full Chrome during install, so this can take
        # a while on a slow RDP -- bound it so a stuck/offline install never
        # hangs the whole AutoSetup (Chrome may still finish in background).
        try {
            $chromeProc = Start-Process -FilePath "$tempDir\chrome.exe" -ArgumentList '/silent /install' -WindowStyle Hidden -PassThru
            if (-not $chromeProc.WaitForExit(420000)) {
                Write-Host ''
                Write-Host '  Chrome install background mein chal raha hai, aage badh raha hoon.' -ForegroundColor DarkGray
            }
        } catch {
            Write-Host ''
            Write-Host '  x Chrome install start nahi hua -- skip.' -ForegroundColor Red
        }
    }
}

Show-Progress 7 $total 'Checking wkhtmltopdf...'
if ($DO_WKHTML -and -not $wkhtmlInstalled) {
    if ($dlFailed.ContainsKey('wkhtml') -or -not (Test-DownloadOk "$tempDir\wkhtml.exe")) {
        Write-Host ''
        Write-Host '  x wkhtmltopdf download fail/incomplete -- skip kar raha hoon.' -ForegroundColor Red
    } else {
        Show-Progress 7 $total 'Installing wkhtmltopdf...'
        try {
            $wkProc = Start-Process -FilePath "$tempDir\wkhtml.exe" -ArgumentList '/S' -WindowStyle Hidden -PassThru
            if (-not $wkProc.WaitForExit(180000)) {
                Write-Host ''
                Write-Host '  wkhtmltopdf install background mein chal raha hai, aage badh raha hoon.' -ForegroundColor DarkGray
            }
        } catch {
            Write-Host ''
            Write-Host '  x wkhtmltopdf install start nahi hua -- skip.' -ForegroundColor Red
        }
    }
}


# Fresh-machine marker + one-shot server ping (2026-09-18) -- ONLY written/
# sent here, after the whole setup above has actually run, so a mid-script
# failure that forces a re-run still sees "fresh" next time ($freshMachine
# was computed once at the top from this same marker's absence). Lets the
# server tell a genuine new-RDP setup apart from a worker just re-running
# autosetup on a machine that's already set up (marker already there ->
# $freshMachine was $false -> none of this runs) -- see
# _process_autosetup_fresh_event in bot.py for what the server does with
# this signal. Hidden+System attributes so it doesn't show up in a casual
# folder browse; even if a worker somehow deletes it, worst case is a
# harmless one-time re-check next time full autosetup happens to run again
# on this same machine (autosetup itself is not the every-day watcher
# restart -- that never touches this at all).
if ($freshMachine) {
    try {
        if (-not (Test-Path -LiteralPath $ebInstallDir)) {
            New-Item -ItemType Directory -Path $ebInstallDir -Force | Out-Null
        }
        Set-Content -LiteralPath $ebMarkerFile -Value (Get-Date -Format "o") -Encoding ASCII
        try { (Get-Item -LiteralPath $ebMarkerFile -Force).Attributes = 'Hidden, System' } catch {}
        $freshBody = @{
            secret  = $Secret
            user_id = $workerId
            events  = @(@{ type = "autosetupfresh"; data = "" })
        } | ConvertTo-Json -Depth 4 -Compress
        Invoke-WebRequest -Uri $ServerUrl -Method Post -Body $freshBody `
            -ContentType "application/json" -TimeoutSec 15 -UseBasicParsing | Out-Null
    } catch {}
}

Show-Progress 8 $total 'Ho gaya!'
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ''
Write-Host '  Done! Setup complete.' -ForegroundColor Green
Start-Sleep -Seconds 2
