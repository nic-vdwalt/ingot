param([Parameter(ValueFromRemainingArguments = $true)][string[]]$OdinFlags)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Collection = "-collection:ingot=$Root"
$Linker = "-linker:msvc"
$Manifest = Get-Content (Join-Path $PSScriptRoot "gate-manifest.json") | ConvertFrom-Json
$env:PYTHONDONTWRITEBYTECODE = "1"

function Invoke-CheckedPython {
    param([string]$Script, [string[]]$Arguments = @())
    & python (Join-Path $PSScriptRoot $Script) @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# tools/odingate is the Odin-source gate on core:odin/parser: style, assertion
# discipline, gfx context routing, UI API layers, and @(init) order all run
# on the AST instead of regexes over masked text.
$OdingateDir = Join-Path $env:TEMP "ingot-odingate"
New-Item -ItemType Directory -Force -Path $OdingateDir | Out-Null
$Odingate = Join-Path $OdingateDir "odingate.exe"
$OdingateFiles = Join-Path $OdingateDir "files.txt"
$env:INGOT_ODINGATE = $Odingate

function Invoke-Odingate {
    param([string[]]$Arguments)
    & $Odingate @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Retries once when the compiler process itself crashed (an NTSTATUS exit such
# as 0xC0000005), never on exit 1 from diagnostics. Odin dev-2026-10:93f71c2
# has two data races that kill roughly one invocation in several hundred; see
# docs/testing.md. $LASTEXITCODE is left at the final attempt's status.
function Invoke-Odin {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & odin @Arguments
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) { return }
    Write-Warning "odin $($Arguments[0]) exited with $LASTEXITCODE (known compiler race in $(& odin version), see docs/testing.md); retrying once"
    & odin @Arguments
}

Write-Host "== Odin toolchain =="
Invoke-CheckedPython "check_toolchain_test.py"
Invoke-CheckedPython "check-toolchain.py"
Write-Host "== building tools/odingate =="
Invoke-Odin build "$Root/tools/odingate" $Collection $Linker "-out:$Odingate" @OdinFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& git -C $Root ls-files "*.odin" | Set-Content -Encoding ascii $OdingateFiles
Write-Host "== odingate tests =="
Invoke-Odin test "$Root/tools/odingate" $Collection $Linker "-define:ODIN_TEST_THREADS=1" @OdinFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "== repository hygiene =="
Invoke-CheckedPython "check_repository_hygiene_test.py"
Invoke-CheckedPython "check-repository-hygiene.py"
Write-Host "== consumer script contract =="
Invoke-CheckedPython "consumer_contract_test.py"
Write-Host "== gfx context ownership guard =="
Invoke-Odingate @("gfx-context", "--root", $Root, "--files-from", $OdingateFiles)
Write-Host "== gfx @(init) ordering guard =="
Invoke-Odingate @("init-order", "--root", $Root, "--files-from", $OdingateFiles)
Write-Host "== gfx expected-assert isolation guard =="
Invoke-CheckedPython "check_gfx_expected_asserts_test.py"
Invoke-CheckedPython "check_gfx_expected_asserts.py" @($Root)
Write-Host "== assertion discipline =="
Invoke-Odingate @("assertions", "--root", $Root, "--files-from", $OdingateFiles)
Write-Host "== UI API layers =="
Invoke-Odingate @("ui-api-layers", "--root", $Root, "--files-from", $OdingateFiles)
Write-Host "== widget capabilities =="
Invoke-CheckedPython "check_widget_capabilities_test.py"
Invoke-CheckedPython "check_widget_capabilities.py"
Write-Host "== UI design tokens =="
Invoke-CheckedPython "check_theme_tokens_test.py"
Invoke-CheckedPython "check_theme_tokens.py" @("--baseline", "$PSScriptRoot/theme_token_baseline.json", $Root)

foreach ($Package in $Manifest.check_packages) {
    Write-Host "== checking $Package =="
    Invoke-Odin check "$Root/$Package" $Collection -vet -strict-style -vet-shadowing -no-entry-point @OdinFlags
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Write-Host "== checking net (INGOT_WS_SIM=true, vet) =="
Invoke-Odin check "$Root/net" $Collection -vet -strict-style -vet-shadowing -no-entry-point "-define:INGOT_WS_SIM=true" @OdinFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "== checking ui_gfx (INGOT_ACCESSKIT=false, vet) =="
Invoke-Odin check "$Root/ui_gfx" $Collection -vet -strict-style -vet-shadowing -no-entry-point "-define:INGOT_ACCESSKIT=false" @OdinFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
foreach ($Mode in $Manifest.simulation_modes) {
    $Package = $Mode[0]
    $Define = $Mode[1]
    Write-Host "== checking $Package ($Define) =="
    Invoke-Odin test "$Root/$Package" $Collection $Linker "-define:$Define" "-define:ODIN_TEST_NAMES=__compile_only__" @OdinFlags
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
foreach ($Package in $Manifest.binding_packages) {
    Write-Host "== checking binding $Package =="
    Invoke-Odin check "$Root/$Package" $Collection -no-entry-point @OdinFlags
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$ExampleOut = Join-Path $env:TEMP "ingot-example-check"
New-Item -ItemType Directory -Force -Path $ExampleOut | Out-Null
foreach ($Example in $Manifest.examples) {
    Write-Host "== building example $Example =="
    Invoke-Odin build "$Root/examples/$Example" $Collection $Linker "-out:$ExampleOut/$Example.exe" @OdinFlags
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
foreach ($Package in $Manifest.hot_reload_packages) {
    Write-Host "== building example hot_reload/$Package =="
    $Arguments = @("build", "$Root/examples/hot_reload/$Package", $Collection, $Linker)
    if ($Package -eq "game") {
        $Arguments += "-build-mode:dll"
        $Arguments += "-out:$ExampleOut/hot_reload_game.dll"
    } else {
        $Arguments += "-out:$ExampleOut/hot_reload_host.exe"
    }
    $Arguments += $OdinFlags
    Invoke-Odin @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Write-Host "== gate manifest =="
Invoke-CheckedPython "gate_manifest_test.py"
Write-Host "== Odin TigerStyle checks =="
Invoke-Odingate @("style", "--root", $Root, "--files-from", $OdingateFiles, "--baseline", "$PSScriptRoot/odin_style_baseline.json")
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
