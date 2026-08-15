$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Collection = "-collection:ingot=$Root"
$Guard = "-define:INGOT_FRAME_SCRATCH_GUARD=true"
$TimeoutSeconds = if ($env:INGOT_TEST_TIMEOUT_SECONDS) { $env:INGOT_TEST_TIMEOUT_SECONDS } else { "300" }
$OutputLimit = if ($env:INGOT_TEST_OUTPUT_LIMIT_BYTES) { $env:INGOT_TEST_OUTPUT_LIMIT_BYTES } else { "16777216" }
$LogDir = if ($env:INGOT_TEST_FAILURE_LOG_DIR) { $env:INGOT_TEST_FAILURE_LOG_DIR } else { Join-Path $env:TEMP "ingot-test-failures" }
$Manifest = Get-Content (Join-Path $PSScriptRoot "gate-manifest.json") | ConvertFrom-Json
$Supervisor = Join-Path $PSScriptRoot "test-supervisor.py"
$env:PYTHONDONTWRITEBYTECODE = "1"

function Invoke-Supervised {
    param([string]$Label, [string[]]$Command)
    & python $Supervisor --package $Label --timeout $TimeoutSeconds --output-limit $OutputLimit --log-dir $LogDir -- @Command
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

& "$PSScriptRoot/check-ui-state.ps1"
& python "$PSScriptRoot/check_gfx_context.py" "$Root"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
foreach ($Package in $Manifest.test_packages) {
    Write-Host "== testing $Package =="
    $Extra = @()
    if ($Package -eq "ui") { $Extra += "-define:ODIN_TEST_THREADS=1" }
    if ($Package -eq "term") {
        $Extra += "-define:INGOT_PTY_SIM=true"
        $Extra += "-define:ODIN_TEST_THREADS=1"
    }
    $Label = $Package.Replace("/", "-")
    $Command = @("odin", "test", "$Root/$Package", $Collection, $Guard, "-define:ODIN_TEST_FAIL_ON_EMPTY=true") + $Extra
    Invoke-Supervised $Label $Command
}
foreach ($TestName in $Manifest.windows_gfx_expected_assert_tests) {
    Write-Host "== testing isolated $TestName =="
    $Label = "gfx-expected-assert-" + $TestName.Replace("gfx.", "").Replace("_", "-")
    $Command = @(
        "odin", "test", "$Root/gfx", $Collection, $Guard,
        "-define:INGOT_GFX_EXPECTED_ASSERTS=true",
        "-define:ODIN_TEST_NAMES=$TestName",
        "-define:ODIN_TEST_THREADS=1",
        "-define:ODIN_TEST_FAIL_ON_EMPTY=true"
    )
    Invoke-Supervised $Label $Command
}
foreach ($Example in $Manifest.test_examples) {
    Write-Host "== testing examples/$Example =="
    $Label = $Example.Replace("_", "-") + "-example"
    $Command = @("odin", "test", "$Root/examples/$Example", $Collection, $Guard, "-define:ODIN_TEST_FAIL_ON_EMPTY=true")
    Invoke-Supervised $Label $Command
}
Write-Host "== replaying fuzz regression corpus =="
Invoke-Supervised "fuzz-corpus" @("python", "$PSScriptRoot/fuzz-corpus.py", "--root", $Root)
Write-Host "== testing native WSS loopback TLS =="
Invoke-Supervised "wss-loopback" @("python", "$PSScriptRoot/wss-loopback-test.py", "--fixture", "$Root/examples/wss_fixture", "--collection=$Collection")
foreach ($Package in $Manifest.compile_packages) {
    Write-Host "== checking $Package =="
    Invoke-Supervised "$Package-check" @("odin", "check", "$Root/$Package", $Collection, "-no-entry-point")
}
