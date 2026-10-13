param([Parameter(ValueFromRemainingArguments = $true)][string[]]$OdinFlags)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Collection = "-collection:ingot=$Root"
$Guard = "-define:INGOT_FRAME_SCRATCH_GUARD=true"
$Linker = "-linker:msvc"
$TimeoutSeconds = if ($env:INGOT_TEST_TIMEOUT_SECONDS) { $env:INGOT_TEST_TIMEOUT_SECONDS } else { "300" }
$OutputLimit = if ($env:INGOT_TEST_OUTPUT_LIMIT_BYTES) { $env:INGOT_TEST_OUTPUT_LIMIT_BYTES } else { "16777216" }
$LogDir = if ($env:INGOT_TEST_FAILURE_LOG_DIR) { $env:INGOT_TEST_FAILURE_LOG_DIR } else { Join-Path $env:TEMP "ingot-test-failures" }
$Manifest = Get-Content (Join-Path $PSScriptRoot "gate-manifest.json") | ConvertFrom-Json
$Supervisor = Join-Path $PSScriptRoot "test-supervisor.py"
$env:PYTHONDONTWRITEBYTECODE = "1"
& python "$PSScriptRoot/check_gfx_expected_asserts.py" $Root
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

function Invoke-Supervised {
    param([string]$Label, [string[]]$Command)
    & python $Supervisor --package $Label --timeout $TimeoutSeconds --output-limit $OutputLimit --log-dir $LogDir -- @Command
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Retries once when the compiler process itself crashed (an NTSTATUS exit such
# as 0xC0000005), never on exit 1 from diagnostics. Odin dev-2026-10:93f71c2
# has two data races that kill roughly one invocation in several hundred; see
# docs/testing.md. The supervised `odin test` runs below are not retried: a
# Windows exit code cannot separate a compiler crash from a test-binary crash.
function Invoke-Odin {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & odin @Arguments
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) { return }
    Write-Warning "odin $($Arguments[0]) exited with $LASTEXITCODE (known compiler race in $(& odin version), see docs/testing.md); retrying once"
    & odin @Arguments
}

& "$PSScriptRoot/check-ui-state.ps1"
$OdingateDir = Join-Path $env:TEMP "ingot-odingate"
New-Item -ItemType Directory -Force -Path $OdingateDir | Out-Null
$Odingate = Join-Path $OdingateDir "odingate.exe"
$OdingateFiles = Join-Path $OdingateDir "files.txt"
Invoke-Odin build "$Root/tools/odingate" $Collection $Linker "-out:$Odingate"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& git -C $Root ls-files "*.odin" | Set-Content -Encoding ascii $OdingateFiles
& $Odingate gfx-context --root $Root --files-from $OdingateFiles
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
foreach ($Package in $Manifest.test_packages) {
    Write-Host "== testing $Package =="
    $Extra = @()
    if ($Package -in @("gfx", "ui", "view")) { $Extra += "-define:ODIN_TEST_THREADS=1" }
    if ($Package -eq "term") {
        $Extra += "-define:INGOT_PTY_SIM=true"
        $Extra += "-define:ODIN_TEST_THREADS=1"
    }
    $Label = $Package.Replace("/", "-")
    $Command = @("odin", "test", "$Root/$Package", $Collection, $Guard, $Linker, "-define:ODIN_TEST_FAIL_ON_EMPTY=true") + $Extra + $OdinFlags
    Invoke-Supervised $Label $Command
}
foreach ($Suite in $Manifest.windows_expected_assert_suites) {
    foreach ($TestName in $Suite.tests) {
        Write-Host "== testing isolated $TestName =="
        $Package = $Suite.package
        $Label = "$Package-expected-assert-" + $TestName.Replace("$Package.", "").Replace("_", "-")
        $Command = @(
            "odin", "test", "$Root/$Package", $Collection, $Guard, $Linker,
            "-define:$($Suite.define)=true",
            "-define:ODIN_TEST_NAMES=$TestName",
            "-define:ODIN_TEST_THREADS=1",
            "-define:ODIN_TEST_FAIL_ON_EMPTY=true"
        ) + $OdinFlags
        Invoke-Supervised $Label $Command
    }
}
foreach ($Example in $Manifest.test_examples) {
    Write-Host "== testing examples/$Example =="
    $Label = $Example.Replace("_", "-") + "-example"
    $Command = @("odin", "test", "$Root/examples/$Example", $Collection, $Guard, $Linker, "-define:ODIN_TEST_FAIL_ON_EMPTY=true") + $OdinFlags
    Invoke-Supervised $Label $Command
}
Write-Host "== replaying fuzz regression corpus =="
Invoke-Supervised "fuzz-corpus" @("python", "$PSScriptRoot/fuzz-corpus.py", "--root", $Root, "--odin-flag=$Linker")
Write-Host "== testing native WSS loopback TLS =="
Invoke-Supervised "wss-loopback" @("python", "$PSScriptRoot/wss-loopback-test.py", "--fixture", "$Root/examples/wss_fixture", "--collection=$Collection", "--odin-flag=$Linker")
foreach ($Package in $Manifest.compile_packages) {
    Write-Host "== checking $Package =="
    $Command = @("odin", "check", "$Root/$Package", $Collection, "-no-entry-point") + $OdinFlags
    Invoke-Supervised "$Package-check" $Command
}
