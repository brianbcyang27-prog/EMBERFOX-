$GOWIN_HOME = "C:\Gowin\Gowin_V1.9.11.03_Education_x64"

$GW_SH = "$GOWIN_HOME\IDE\bin\gw_sh.exe"
$PROGRAMMER = "$GOWIN_HOME\Programmer\bin\programmer_cli.exe"

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

Write-Host "Uploading bitstream: $FS_PATH"

$PROGRAMMER_OUTPUT = @(& $PROGRAMMER --device $DEVICE_NAME --run 5 --fsFile $FS_PATH | ForEach-Object {
    $LINE = $_.ToString()
    Write-Host $LINE
    $LINE
})
$PROGRAMMER_EXIT_CODE = $LASTEXITCODE

$HAS_PROGRAMMER_ERROR = $PROGRAMMER_OUTPUT | Select-String -Pattern '\bERROR\b|\bError\b|\bFailed\b|\bfailed\b' -Quiet
$HAS_100 = $PROGRAMMER_OUTPUT | Select-String -Pattern '100%' -Quiet
$HAS_FINISHED = $PROGRAMMER_OUTPUT | Select-String -Pattern '\bFinished\.' -Quiet

# Write-Host $PROGRAMMER_OUTPUT

if ($PROGRAMMER_EXIT_CODE -ne 0 -or $HAS_PROGRAMMER_ERROR -or -not ($HAS_100 -and $HAS_FINISHED)) {
    Write-Host "Gowin upload failed."
    exit [Math]::Max($PROGRAMMER_EXIT_CODE, 1)
}

Write-Host "Build and upload finished."
