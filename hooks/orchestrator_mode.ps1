#requires -Version 5.1
# orchestrator_mode.ps1 -- PreToolUse (matcher Write|Edit|MultiEdit|Bash|PowerShell): when "orchestrator
# mode" is ON, refuse a code write from the MAIN session and redirect to a delegated worker -- EXCEPT a
# small Edit/MultiEdit (new content <= $SmallEditLines lines total), which passes even on a code-extension
# file (owner decision 2026-09-18: the goal is token efficiency, not stopping Fable from writing code for
# its own sake -- a delegated worker costs roughly 50k tokens of cold start, so anything under 40 new
# lines is cheaper written inline than delegated; only build-sized writes get redirected.
# a Write is never small since a new file is never a small edit, and Bash/PowerShell writes never qualify).
# Motivation: HISTORY.md (2026-09-18 audit) -- sessions that opened with the phrase
# "orchestrate" still drifted back to writing code inline; a phrase alone isn't durable state.
# Per docs.claude.com/en/docs/claude-code/hooks, `agent_id` is present in the hook's stdin JSON ONLY
# when the call originates inside a subagent -- so its presence is how this hook tells "a worker is
# doing this" from "the main/orchestrating session is doing this" and exits 0 (never gates workers).
#
# ON/OFF state (spec agent-ladder-enforcement.md, package P4, decision D1 = option B):
#   ON  if %TEMP%\claude_orchestrator\<sid>.on exists (written by another hook when the owner says
#       "orchestrate" / runs the orchestrate skill; its content is the "HH:mm UTC" it was set), OR
#   ON  (auto) if the delegation-gate counter file for this session
#       (%TEMP%\claude_delegation_gate\<sid>.count) holds an integer >= 150 AND no
#       %TEMP%\claude_orchestrator\<sid>.off marker exists for this session -- in which case this
#       hook ALSO writes the .on flag (content: "auto, 150 inline code lines reached") so the state
#       is visible to the flag hook and future calls skip the counter re-check.
#   OFF otherwise.
#
# CONTRACT for orchestrate_flag.ps1 (owned by another worker): "go inline" / /orchestrate off must
# delete the .on flag file AND create the .off marker file
# (%TEMP%\claude_orchestrator\<sid>.off, any content) for that session_id. The .off marker is what
# stops the auto-on from immediately re-firing off the same counter value the next call -- it only
# re-engages if the counter keeps growing (the owner keeps writing inline) past 150 again; this hook does
# not delete .off itself, and does not re-check .off once .on exists.
#
# Session id is sanitized the same way as delegation_gate.ps1: [^A-Za-z0-9-] -> '_'.
# Escape hatch: say "go inline" (clears .on via orchestrate_flag.ps1) or run /orchestrate off.
# Fails open on any parse error or missing session_id.
#
# Bash/PowerShell detection (fixed 2026-09-18, spec P4): a command is refused only when it contains an
# actual WRITE OPERATOR whose target is a $CodeExt path -- a `>`/`>>` redirect (this also covers a
# heredoc-to-file like `cat <<'EOF' > foo.py`, since that's a heredoc PLUS a `>` redirect), a
# Set-Content/Out-File/Add-Content whose -Path/-LiteralPath or positional/piped target is a code path,
# sed -i / perl -pi whose target argument is a code path, or a `python -`/`python3 -` stdin heredoc whose
# body calls open(...,'w') or Path(...).write_text() on a code path. A bare token match (the command just
# MENTIONS a code-extension path somewhere -- running a script, git/grep/cat/sed -n on a code file, a
# code file in a test command) no longer trips this; only Write/Edit/MultiEdit whole-file-path matching
# keeps the old anchored bare match, since those tools always target exactly one file.

$CodeExtCore = 'py|ts|tsx|js|jsx|mjs|cjs|ps1|psm1|sh|bash|cmd|bat|rs|go|java|kt|cs|c|cpp|h|hpp|rb|php|lua|sql|toml|yaml|yml|json|css|scss|html|svelte|vue'
$CodeExt = "\.($CodeExtCore)$"
$CodeExtInline = "\.($CodeExtCore)(?=[""'\s]|$)"
$Threshold = 150
# Small-edit allowance (owner decision 2026-09-18, raised same day): an Edit/MultiEdit whose new content
# totals at most this many lines passes even on a code-extension file. Edit lines = line count of
# tool_input.new_string (empty string = a deletion = 0 lines); MultiEdit lines = sum across
# tool_input.edits[].new_string.
$SmallEditLines = 40

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if ($j.PSObject.Properties.Name -contains 'agent_id' -and -not [string]::IsNullOrWhiteSpace("$($j.agent_id)")) { exit 0 }

    $tool = "$($j.tool_name)"
    if ($tool -notin @('Write', 'Edit', 'MultiEdit', 'Bash', 'PowerShell')) { exit 0 }

    $sid = "$($j.session_id)"
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
    $safe = ($sid -replace '[^A-Za-z0-9-]', '_')

    $orchDir = Join-Path $env:TEMP 'claude_orchestrator'
    $onFile = Join-Path $orchDir "$safe.on"
    $offFile = Join-Path $orchDir "$safe.off"
    $gateDir = Join-Path $env:TEMP 'claude_delegation_gate'
    $counterFile = Join-Path $gateDir "$safe.count"

    $modeOn = $false
    $sinceText = ''

    if (Test-Path -LiteralPath $onFile) {
        $modeOn = $true
        $sinceText = (Get-Content -LiteralPath $onFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($sinceText)) { $sinceText = 'unknown time' }
    } elseif (-not (Test-Path -LiteralPath $offFile)) {
        $count = 0
        if (Test-Path -LiteralPath $counterFile) {
            $count = [int](Get-Content -LiteralPath $counterFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ($count -ge $Threshold) {
            $modeOn = $true
            $sinceText = 'auto, 150 inline code lines reached'
            if (-not (Test-Path -LiteralPath $orchDir)) { New-Item -ItemType Directory -Path $orchDir -Force | Out-Null }
            Set-Content -LiteralPath $onFile -Value $sinceText -Encoding ASCII
        }
    }

    if (-not $modeOn) { exit 0 }

    $isCodeWrite = $false
    $head = ''

    if ($tool -in @('Write', 'Edit', 'MultiEdit')) {
        $fp = [string]$j.tool_input.file_path
        if (-not [string]::IsNullOrWhiteSpace($fp) -and $fp -match "(?i)$CodeExt") {
            $isCodeWrite = $true
            $head = $fp

            if ($tool -in @('Edit', 'MultiEdit')) {
                $editLines = 0
                if ($tool -eq 'Edit') {
                    $ns = [string]$j.tool_input.new_string
                    if (-not [string]::IsNullOrEmpty($ns)) { $editLines = ($ns -split "`n").Count }
                } else {
                    foreach ($e in @($j.tool_input.edits)) {
                        $ns = [string]$e.new_string
                        if (-not [string]::IsNullOrEmpty($ns)) { $editLines += ($ns -split "`n").Count }
                    }
                }
                if ($editLines -le $SmallEditLines) { $isCodeWrite = $false }
            }
        }
    } else {
        $cmd = [string]$j.tool_input.command
        if (-not [string]::IsNullOrWhiteSpace($cmd)) {
            function Get-UnquotedToken([string]$s) {
                $s = $s.Trim()
                if ($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[-1] -eq '"') -or ($s[0] -eq "'" -and $s[-1] -eq "'"))) {
                    return $s.Substring(1, $s.Length - 2)
                }
                return $s
            }

            # `>` / `>>` redirect (also covers a heredoc-to-file, e.g. cat <<'EOF' > foo.py, which is
            # a heredoc PLUS this same redirect).
            foreach ($m in [regex]::Matches($cmd, "(?<!>)>{1,2}(?!>)\s*(`"[^`"]*`"|'[^']*'|[^\s;&|]+)")) {
                $tgt = Get-UnquotedToken $m.Groups[1].Value
                if ($tgt -match "(?i)$CodeExt") { $isCodeWrite = $true; break }
            }

            # Set-Content / Out-File / Add-Content: -Path / -LiteralPath, or the first positional
            # (piped) target -- not a bare mention of the cmdlet name elsewhere in the line.
            if (-not $isCodeWrite) {
                foreach ($m in [regex]::Matches($cmd, '(?i)(Set-Content|Out-File|Add-Content)\b([^;&|]*)')) {
                    $seg = $m.Groups[2].Value
                    $tgt = $null
                    $pm = [regex]::Match($seg, "(?i)-(?:Literal)?Path\s+(`"[^`"]*`"|'[^']*'|[^\s]+)")
                    if ($pm.Success) {
                        $tgt = $pm.Groups[1].Value
                    } else {
                        $tm = [regex]::Match($seg.Trim(), "^(`"[^`"]*`"|'[^']*'|[^\s-][^\s]*)")
                        if ($tm.Success) { $tgt = $tm.Groups[1].Value }
                    }
                    if ($tgt) {
                        $tgt = Get-UnquotedToken $tgt
                        if ($tgt -match "(?i)$CodeExt") { $isCodeWrite = $true; break }
                    }
                }
            }

            # sed -i / perl -pi: only refuse when its own target argument is a code path.
            if (-not $isCodeWrite) {
                foreach ($m in [regex]::Matches($cmd, '(?i)\b(sed\s+-i\S*|perl\s+-p?i\S*)\b([^;&|]*)')) {
                    $seg = $m.Groups[2].Value.Trim()
                    $toks = [regex]::Matches($seg, "`"[^`"]*`"|'[^']*'|\S+")
                    if ($toks.Count -gt 0) {
                        $tgt = Get-UnquotedToken $toks[$toks.Count - 1].Value
                        if ($tgt -match "(?i)$CodeExt") { $isCodeWrite = $true; break }
                    }
                }
            }

            # python/python3 stdin heredoc whose body writes to a code path via open(...,'w') or
            # Path(...).write_text(...).
            if (-not $isCodeWrite -and $cmd -match '(?i)python3?\s+-\s*<<') {
                $bodyMatch = [regex]::Match($cmd, "(?i)python3?\s+-\s*<<\s*['`"]?(\w+)['`"]?\r?\n(.*)", [System.Text.RegularExpressions.RegexOptions]::Singleline)
                if ($bodyMatch.Success) {
                    $body = $bodyMatch.Groups[2].Value
                    if ($body -match '(?i)(open\s*\(|\.write_text\s*\()' -and $body -match "(?i)$CodeExtInline") {
                        $isCodeWrite = $true
                    }
                }
            }

            if ($isCodeWrite) {
                $head = $cmd.Substring(0, [Math]::Min(60, $cmd.Length))
            }
        }
    }

    if (-not $isCodeWrite) { exit 0 }

    $target = if ($head) { $head } else { '(unknown)' }
    $msg = "[orchestrator] refused: mode ON since $sinceText and this is a code write from the main session ($target). " +
    "Hand it to a worker: Agent with model named (sonnet for mechanical, opus for anything that ships), brief = the exact change plus the acceptance command. " +
    "Under 41 lines? it would have passed. Bigger: ask the owner or hand it to a named-model worker."
    [Console]::Error.WriteLine($msg)
    exit 2
} catch {
    exit 0
}
