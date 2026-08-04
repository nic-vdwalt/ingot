$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Collection = "-collection:ingot=$Root"
$Manifest = Get-Content (Join-Path $PSScriptRoot "gate-manifest.json") | ConvertFrom-Json
$env:PYTHONDONTWRITEBYTECODE = "1"

function Invoke-CheckedPython {
    param([string]$Script, [string[]]$Arguments = @())
    & python (Join-Path $PSScriptRoot $Script) @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "== Odin toolchain =="
Invoke-CheckedPython "check_toolchain_test.py"
Invoke-CheckedPython "check-toolchain.py"
Write-Host "== repository hygiene =="
Invoke-CheckedPython "check-repository-hygiene.py"
Write-Host "== gfx context ownership guard =="
Invoke-CheckedPython "check_gfx_context_test.py"
Invoke-CheckedPython "check_gfx_context.py" @("--baseline", "$PSScriptRoot/gfx_context_baseline.json", $Root)
Write-Host "== gfx @(init) ordering guard =="
Invoke-CheckedPython "check_init_order_test.py"
Invoke-CheckedPython "check_init_order.py" @($Root)
Write-Host "== assertion discipline =="
Invoke-CheckedPython "check_assertions_test.py"
Invoke-CheckedPython "check_assertions.py" @("--baseline", "$PSScriptRoot/assertion_baseline.json", $Root)
Write-Host "== UI API layers =="
Invoke-CheckedPython "check_ui_api_layers_test.py"
Invoke-CheckedPython "check_ui_api_layers.py" @($Root)
Write-Host "== UI design tokens =="
Invoke-CheckedPython "check_theme_tokens_test.py"
Invoke-CheckedPython "check_theme_tokens.py" @("--baseline", "$PSScriptRoot/theme_token_baseline.json", $Root)

foreach ($Package in $Manifest.check_packages) {
    Write-Host "== checking $Package =="
    & odin check "$Root/$Package" $Collection -vet -strict-style -vet-shadowing -no-entry-point
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
foreach ($Mode in $Manifest.simulation_modes) {
    $Package = $Mode[0]
    $Define = $Mode[1]
    Write-Host "== checking $Package ($Define) =="
    & odin test "$Root/$Package" $Collection "-define:$Define" -define:ODIN_TEST_NAMES=__compile_only__
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
foreach ($Package in $Manifest.binding_packages) {
    Write-Host "== checking binding $Package =="
    & odin check "$Root/$Package" $Collection -no-entry-point
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$ExampleOut = Join-Path $env:TEMP "ingot-example-check"
New-Item -ItemType Directory -Force -Path $ExampleOut | Out-Null
foreach ($Example in $Manifest.examples) {
    Write-Host "== building example $Example =="
    & odin build "$Root/examples/$Example" $Collection "-out:$ExampleOut/$Example.exe"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Write-Host "== Odin TigerStyle checks =="
Invoke-CheckedPython "check_odin_style_test.py"
Invoke-CheckedPython "check_odin_style.py" @("--baseline", "$PSScriptRoot/odin_style_baseline.json", $Root)
Write-Host "== wasm bloat guard tests =="
Invoke-CheckedPython "check_wasm_bloat_test.py"
Write-Host "== odinfmt (verify formatting) =="
$Files = & git -C $Root ls-files "*.odin"
foreach ($File in $Files) {
    $Source = Join-Path $Root $File
    $Formatted = & odinfmt $Source
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $Current = Get-Content -Raw $Source
    if (($Formatted -join "`n") + "`n" -ne $Current.Replace("`r`n", "`n")) {
        Write-Error "needs formatting: $File"
    }
}
