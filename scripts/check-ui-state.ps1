$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Forbidden = "default_ui|default_text_system|default_spell_system|ui_frame_current|ui_runtime_current"
$Matches = Get-ChildItem "$Root/ui" -Filter "*.odin" -Recurse | Select-String -Pattern $Forbidden
if ($Matches) {
    $Matches | ForEach-Object { Write-Error $_.ToString() }
    exit 1
}
