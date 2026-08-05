param(
    # Build only, do not touch the board. Use this when the USB-JTAG bridge is
    # not available - the FPGA keeps running whatever is already in its flash,
    # so development does not have to stop just because the link is down.
    [switch]$NoUpload
)

$GOWIN_HOME = "C:\Gowin\Gowin_V1.9.11.03_Education_x64"

$GW_SH = "$GOWIN_HOME\IDE\bin\gw_sh.exe"
$PROGRAMMER = "$GOWIN_HOME\Programmer\bin\programmer_cli.exe"

# programmer_cli is a frozen-Python executable and refuses to start if
# PYTHONIOENCODING names an encoding its interpreter does not know
# ("Fatal Python error: Py_Initialize: can't initialize sys standard streams").
# Nothing in this repo sets it, but a shell that does would break the upload in
# a way that looks nothing like a USB problem. Clear it for this process only.
$env:PYTHONIOENCODING = ''

$DEVICE_NAME = "GW1NSR-4C"

$ROOT = Split-Path -Parent $PSScriptRoot
$PROJECT_FILE = $null

foreach ($CANDIDATE in @("hdmi_coin.prj", "hdmi_coin.gprj")) {
    $CANDIDATE_PATH = Join-Path $ROOT $CANDIDATE
    if (Test-Path $CANDIDATE_PATH) {
        $PROJECT_FILE = $CANDIDATE_PATH
        break
    }
}

if (-not $PROJECT_FILE) {
    Write-Host "Project file not found. Expected hdmi_coin.prj or hdmi_coin.gprj in: $ROOT"
    exit 1
}

if (-not (Test-Path $GW_SH)) {
    Write-Host "Gowin shell not found: $GW_SH"
    exit 1
}

if (-not (Test-Path $PROGRAMMER)) {
    Write-Host "Gowin programmer CLI not found: $PROGRAMMER"
    exit 1
}

$PROJECT_FILE_GW = $PROJECT_FILE -replace "\\", "/"

$TCL = @"
open_project "$PROJECT_FILE_GW"
run all
run close
"@

# Hand gw_sh a script FILE rather than piping the script into its stdin.
# Piping goes through PowerShell's $OutputEncoding, which on some machines
# prepends a UTF-8 BOM. gw_sh then reads the BOM as part of the first command
# and dies with:  invalid command name "<BOM>open_project"
# WriteAllText with ASCIIEncoding is BOM-free no matter how the shell is set up.
$TCL_FILE = Join-Path ([System.IO.Path]::GetTempPath()) "hdmi_coin_build.tcl"
[System.IO.File]::WriteAllText($TCL_FILE, $TCL, (New-Object System.Text.ASCIIEncoding))

Push-Location $ROOT
try {
    $GOWIN_OUTPUT = @(& $GW_SH $TCL_FILE | ForEach-Object {
        $LINE = $_.ToString()
        Write-Host $LINE
        $LINE
    })
    $GOWIN_EXIT_CODE = $LASTEXITCODE
} finally {
    Pop-Location
}

$HAS_GOWIN_ERROR = $GOWIN_OUTPUT | Select-String -Pattern '\bERROR\s*\(' -Quiet

if ($GOWIN_EXIT_CODE -ne 0 -or $HAS_GOWIN_ERROR) {
    Write-Host "Gowin build failed."
    exit [Math]::Max($GOWIN_EXIT_CODE, 1)
}

$PNR_DIR = Join-Path $ROOT "impl\pnr"
$FS_PATH = $null

foreach ($CANDIDATE in @("hdmi_coin.fs", "hdmi.fs")) {
    $CANDIDATE_PATH = Join-Path $PNR_DIR $CANDIDATE
    if (Test-Path $CANDIDATE_PATH) {
        $FS_PATH = $CANDIDATE_PATH
        break
    }
}

if (-not $FS_PATH -and (Test-Path $PNR_DIR)) {
    $FS_FILE = Get-ChildItem -Path $PNR_DIR -Filter "*.fs" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($FS_FILE) {
        $FS_PATH = $FS_FILE.FullName
    }
}

if (-not $FS_PATH) {
    Write-Host "Bitstream file not found under: $PNR_DIR"
    exit 1
}

if ($NoUpload) {
    Write-Host "Build finished (upload skipped: -NoUpload)."
    Write-Host "Bitstream: $FS_PATH"
    exit 0
}

Write-Host "Uploading bitstream: $FS_PATH"

# ---------------------------------------------------------------------------
# Defensive: clear ReadOnly on the bitstream.
#
# Gowin's place-and-route writes impl/pnr/*.fs with the ReadOnly attribute set.
# This is cheap insurance and does no harm, but do NOT read it as the cause of
# an upload failure - it was investigated as a suspect and NOT confirmed. The
# "Cost 0.01 second(s)" silent abort was later reproduced with `--run 0`, which
# takes no bitstream at all, at a moment when the board had dropped off USB.
# The attribute is almost certainly incidental.
# ---------------------------------------------------------------------------
if ((Get-Item $FS_PATH).IsReadOnly) {
    Set-ItemProperty -Path $FS_PATH -Name IsReadOnly -Value $false
}

# ---------------------------------------------------------------------------
# Pre-flight: is the board actually there?
#
# `--run 5` does NOT check. Given no board it prints
#
#     Target Cable: Gowin USB Cable(FT2CH)/0/None/null@2.5MHz
#     Target Device: GW1NSR-4C(0x0100981B)
#     Operation "embFlash Erase,Program" for device#1...
#     Cost 0.01 second(s)
#
# and exits, having done nothing. Both of those first two lines are echoed from
# the --device argument and Gowin's internal part table - they print with
# nothing plugged in and are NOT detection. The old script then reported a bare
# "Gowin upload failed.", which looks like a toolchain fault when it is a USB
# one.
#
# `--scan` does check, costs 0.03 s, and says "Error: No Gowin devices found!".
# Run it first so the failure explains itself.
#
# This matters here because the board drops off USB intermittently. Observed
# directly: --scan found the device, three --run 0 reads and two full
# erase+program cycles all succeeded, and then minutes later --scan found
# nothing and Windows listed no VID_0403 device at all, with nothing touched in
# between. Every "Cost 0.01 second(s)" abort lines up with a window where the
# bridge was gone. Without this pre-flight, those windows look like a broken
# toolchain instead of a dropped link.
# ---------------------------------------------------------------------------
# The bridge sometimes needs a moment (or a couple of pokes) to come back after
# a suspend, and the build above just spent minutes not touching it. Retry a
# few times before giving up rather than failing on a single blip.
$SCAN_ATTEMPTS = 5
$SCAN_FOUND_NOTHING = $true
$SCAN_OUTPUT = @()

for ($ATTEMPT = 1; $ATTEMPT -le $SCAN_ATTEMPTS; $ATTEMPT++) {
    $SCAN_OUTPUT = @(& $PROGRAMMER --scan 2>&1 | ForEach-Object { $_.ToString() })
    $SCAN_FOUND_NOTHING = $SCAN_OUTPUT | Select-String -Pattern 'No Gowin devices found|No cable|not found' -Quiet
    if (-not $SCAN_FOUND_NOTHING) { break }
    if ($ATTEMPT -lt $SCAN_ATTEMPTS) {
        Write-Host "Board not visible on USB (attempt $ATTEMPT of $SCAN_ATTEMPTS); retrying in 2 s..."
        Start-Sleep -Seconds 2
    }
}

if ($SCAN_FOUND_NOTHING) {
    $SCAN_OUTPUT | ForEach-Object { Write-Host $_ }
    Write-Host ""
    Write-Host "BUILD SUCCEEDED. Only the upload could not run:"
    Write-Host "the board was not found over USB after $SCAN_ATTEMPTS attempts."
    Write-Host ""
    Write-Host "Note: the FPGA keeps running whatever is already in its flash, so the"
    Write-Host "screen can look fine while the USB-JTAG bridge is absent. Those are"
    Write-Host "independent - a live display does NOT mean the board is connected."
    Write-Host ""
    Write-Host "The bitstream is ready at:"
    Write-Host "  $FS_PATH"
    Write-Host ""
    Write-Host "Check, in order:"
    Write-Host "  1. Unplug the board and plug it back in. This is the usual cure."
    Write-Host "  2. Ask Windows whether it sees the bridge at all:"
    Write-Host "       Get-PnpDevice -PresentOnly | Where-Object { `$_.InstanceId -match 'VID_0403' }"
    Write-Host "     Nothing listed = not enumerating; no toolchain setting can fix that."
    Write-Host "  3. USB selective suspend can put the bridge to sleep and it may not"
    Write-Host "     wake. In an ELEVATED PowerShell:"
    Write-Host "       powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0"
    Write-Host "       powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0"
    Write-Host "       powercfg /S SCHEME_CURRENT"
    Write-Host "  4. Plug straight into the PC, not a hub or a monitor port."
    Write-Host ""
    Write-Host "To rebuild without needing the board at all, run the 'build' task."
    exit 1
}

$PROGRAMMER_OUTPUT = @(& $PROGRAMMER --device $DEVICE_NAME --run 5 --fsFile $FS_PATH 2>&1 | ForEach-Object {
    $LINE = $_.ToString()
    Write-Host $LINE
    $LINE
})
$PROGRAMMER_EXIT_CODE = $LASTEXITCODE

$HAS_PROGRAMMER_ERROR = $PROGRAMMER_OUTPUT | Select-String -Pattern '\bERROR\b|\bFailed\b' -Quiet
$HAS_100 = $PROGRAMMER_OUTPUT | Select-String -Pattern '100%' -Quiet
$HAS_FINISHED = $PROGRAMMER_OUTPUT | Select-String -Pattern '\bFinished\.' -Quiet

if ($PROGRAMMER_EXIT_CODE -ne 0 -or $HAS_PROGRAMMER_ERROR -or -not ($HAS_100 -and $HAS_FINISHED)) {
    # ------------------------------------------------------------------
    # Do not trust the programmer's own verdict here.
    #
    # After erasing and programming to 100% it immediately reads the device
    # status back. The part is re-configuring from the freshly written flash
    # at that moment, so that read can land mid-reconfiguration and come back
    # as a bare "Error: Error found!" (exit 254) even though the flash is
    # correct. Observed exactly that: "Error found!" on the console, yet a
    # follow-up read reported the new User Code and a healthy status.
    #
    # So ask the device itself. A "Read Device Codes" that succeeds and
    # returns a User Code which is neither all-zeroes nor all-ones means the
    # part is configured and running.
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "Programmer reported a problem. Reading the device back to see whether it actually took..."

    $VERIFY = @(& $PROGRAMMER --device $DEVICE_NAME --run 0 2>&1 | ForEach-Object {
        $LINE = $_.ToString()
        Write-Host $LINE
        $LINE
    })
    $VERIFY_CODE = $LASTEXITCODE

    $USER_CODE_LINE = $VERIFY | Select-String -Pattern 'User Code is:\s*(0x[0-9A-Fa-f]+)'
    $USER_CODE = $null
    if ($USER_CODE_LINE) { $USER_CODE = $USER_CODE_LINE.Matches[0].Groups[1].Value }

    $DEVICE_OK = ($VERIFY_CODE -eq 0) -and $USER_CODE -and
                 ($USER_CODE -notmatch '^0x0+$') -and ($USER_CODE -notmatch '^0x[Ff]+$')

    if ($DEVICE_OK) {
        Write-Host ""
        Write-Host "Device reads back configured (User Code $USER_CODE)."
        Write-Host "The programmer's end-of-run status check fired early; the flash is good."
    } else {
        Write-Host ""
        Write-Host "Gowin upload failed: the device did not come back configured."
        exit [Math]::Max($PROGRAMMER_EXIT_CODE, 1)
    }
}

Write-Host "Build and upload finished."
