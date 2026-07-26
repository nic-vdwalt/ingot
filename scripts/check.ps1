$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Collection = "-collection:ingot=$Root"
foreach ($Package in @("gfx", "ui", "ui_gfx", "term", "prefs", "net", "sys", "pty", "testx")) {
    Write-Host "== checking $Package =="
    & odin check "$Root/$Package" $Collection -vet -strict-style -vet-shadowing -no-entry-point
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
foreach ($Package in @("libvterm", "accesskit")) {
    & odin check "$Root/$Package" $Collection -no-entry-point
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
foreach ($Example in @("gallery", "breakout", "idle_demo", "chart_demo", "render_fixture", "multi_context_fixture")) {
    & odin build "$Root/examples/$Example" $Collection
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
