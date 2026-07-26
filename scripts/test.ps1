$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Collection = "-collection:ingot=$Root"

& "$PSScriptRoot/check-ui-state.ps1"
$env:PYTHONDONTWRITEBYTECODE = "1"
& python "$PSScriptRoot/check_gfx_context.py" --baseline "$PSScriptRoot/gfx_context_baseline.json" "$Root"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
foreach ($Package in @("gfx", "ui", "ui_gfx", "libvterm", "term", "prefs", "net")) {
    Write-Host "== testing $Package =="
    & odin test "$Root/$Package" $Collection -define:INGOT_FRAME_SCRATCH_GUARD=true -define:ODIN_TEST_FAIL_ON_EMPTY=true
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Write-Host "== testing native WSS loopback TLS =="
& python "$PSScriptRoot/wss-loopback-test.py" --fixture "$Root/examples/wss_fixture" "--collection=$Collection"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
foreach ($Package in @("sys", "pty", "accesskit", "testx")) {
    Write-Host "== checking $Package =="
    & odin check "$Root/$Package" $Collection -no-entry-point
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
