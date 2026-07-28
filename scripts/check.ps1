$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Collection = "-collection:ingot=$Root"
$env:PYTHONDONTWRITEBYTECODE = "1"
Write-Host "== Odin toolchain =="
& python "$PSScriptRoot/check_toolchain_test.py"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& python "$PSScriptRoot/check-toolchain.py"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "== gfx context ownership guard =="
& python "$PSScriptRoot/check_gfx_context_test.py"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& python "$PSScriptRoot/check_gfx_context.py" --baseline "$PSScriptRoot/gfx_context_baseline.json" "$Root"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
foreach ($Package in @("gfx", "ui", "ui_gfx", "term", "prefs", "net", "sys", "pty", "testx")) {
    Write-Host "== checking $Package =="
    & odin check "$Root/$Package" $Collection -vet -strict-style -vet-shadowing -no-entry-point
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
foreach ($Package in @("libvterm", "accesskit")) {
    & odin check "$Root/$Package" $Collection -no-entry-point
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$Examples = @(
    "hello",
    "gallery",
    "breakout",
    "idle_demo",
    "chart_demo",
    "render_fixture",
    "multi_context_fixture",
    "raylib_migration_fixture"
)
foreach ($Example in $Examples) {
    & odin build "$Root/examples/$Example" $Collection
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
