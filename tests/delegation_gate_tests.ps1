# The shared isolated subprocess suite covers both hooks and cross-hook deduplication.
param([string]$HookRoot = (Join-Path $PSScriptRoot '../hooks'))
& (Join-Path $PSScriptRoot 'orchestrator_mode_tests.ps1') -HookRoot $HookRoot
