# verify_checkpoint_claims.ps1 -- close step 4.5: make the verify step fail as loudly as the cap check.
# Spec: agent-ladder/decisions/checkpoint-verification-enforcement-asymmetry.md (built 2026-08-12).
# Exit contract mirrors finish-checkpoint.ps1: 0 = clean, 2 = defects found (each named).
# Coverage (honest): dead paths = HARD FAIL; git-state claims = REVIEW block to reconcile;
# stale-dated / owner-gated threads = PROMPTS. Semantic staleness is NOT detected here.
param(
    [Parameter(Mandatory = $true)][string]$Checkpoint
)
$ErrorActionPreference = 'Stop'
try {
    $ckPath = (Resolve-Path -LiteralPath $Checkpoint).Path
} catch {
    Write-Output "[verify-checkpoint] ERROR: checkpoint not found: $Checkpoint"
    exit 2
}
$projRoot = Split-Path -Parent $ckPath
$text = [System.IO.File]::ReadAllText($ckPath)
$lines = [System.IO.File]::ReadAllLines($ckPath)
$defects = @()
$reviews = @()
$prompts = @()

# --- 1. Path existence -------------------------------------------------------
# Candidates: backticked tokens and markdown-link targets that look like paths.
# Changelog sections are HISTORY -- paths there describe past states; skip them.
$liveText = New-Object System.Text.StringBuilder
$inChangelog = $false
foreach ($ln in $lines) {
    if ($ln -match '^##\s') { $inChangelog = ($ln -match '^##\s+Harness changelog') }
    if ($inChangelog) { continue }
    # Dated changelog-shaped bullets ("- 2026-07-29 -- ...") are history regardless of which
    # section holds them (Health keeps its changelog under Next step) -- skip as history too.
    if ($ln -match '^\s*-\s+20\d{2}-\d{2}-\d{2}\s+--') { continue }
    [void]$liveText.AppendLine($ln)
}
$liveText = $liveText.ToString()
$cands = New-Object System.Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($liveText, '`([^`\r\n]{2,240})`'))   { [void]$cands.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($liveText, '\]\(([^)\r\n]{2,240})\)')) { [void]$cands.Add($m.Groups[1].Value) }
$missing = @(); $planned = @(); $checked = 0
# Optional per-project ignore list: <proj>/.checkpoint-verify-ignore, one wildcard per line,
# '#' comments allowed -- for external/deliberately-dead paths a heuristic can't classify
# (spec: checkpoint-tooling-false-exit2.md fix 3 alternative).
$ignoreGlobs = @()
$igPath = Join-Path $projRoot '.checkpoint-verify-ignore'
if (Test-Path -LiteralPath $igPath) {
    $ignoreGlobs = @([System.IO.File]::ReadAllLines($igPath) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_ -notmatch '^#' })
}
foreach ($c in $cands) {
    $t = $c.Trim().Trim('"').Trim("'")
    $skip = $false
    foreach ($g in $ignoreGlobs) { if ($t -like $g) { $skip = $true; break } }
    if ($skip) { continue }
    if ($t -match '^(https?|mailto|file):') { continue }
    if ($t -notmatch '[\\/]') { continue }                          # not path-shaped
    if ($t -match '[|<>*?{}]' ) { continue }                        # globs/braces/placeholders/pipes
    if ($t -match '\s-\w|\||;|&&') { continue }                     # command-looking
    if ($t -match '^\\\\') { continue }                             # UNC: out of scope
    if ($t -match "[^ -~]") { continue }                      # non-ASCII (ellipsis placeholders)
    if ($t -match '^/') { continue }                                # POSIX/remote/slash-cmd: not checkable here
    if ($t -match '^[^\\/]+[\\/]$') { continue }                    # bare "name/" concept mentions
    if ($t -match ':' -and $t -notmatch '^[A-Za-z]:[\\/]') { continue }  # code/field pairs, not drive paths
    if ($t -match '#') { $t = ($t -split '#')[0] }                  # strip anchors
    if ($t -eq '') { continue }
    $expanded = $t -replace '^~', $env:USERPROFILE
    $tries = @()
    if ($expanded -match '^[A-Za-z]:') { $tries += $expanded }
    else {
        $tries += (Join-Path $projRoot $expanded)
        $tries += (Join-Path (Split-Path -Parent $projRoot) $expanded)  # ../-style siblings written bare
        $tries += (Join-Path $env:USERPROFILE $expanded)                # home-relative shorthand
        $tries += (Join-Path "$env:USERPROFILE\Documents\Obsidian Vault" $expanded)  # vault-relative notes
        $tries += (Join-Path "$env:USERPROFILE\Documents\Claude" $expanded)          # workspace-root cross-project refs
        # One-level working subdirs (scripts often write paths relative to e.g. <proj>/pipeline/).
        # One level only, full-suffix match -- -Recurse would risk false negatives on same-named
        # files deep in unrelated subtrees (spec: checkpoint-tooling-false-exit2.md fix 1).
        foreach ($sub in (Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($sub.Name -notmatch '^(\.|archive$|node_modules$)') { $tries += (Join-Path $sub.FullName $expanded) }
        }
        # ...and one level into sibling projects (paths written relative to a sibling's subdir,
        # e.g. maps_timeline referencing homebase/dashboards.json under life-os/).
        foreach ($sib in (Get-ChildItem -LiteralPath (Split-Path -Parent $projRoot) -Directory -ErrorAction SilentlyContinue)) {
            if ($sib.FullName -ne $projRoot -and $sib.Name -notmatch '^(\.|archive$|node_modules$)') { $tries += (Join-Path $sib.FullName $expanded) }
        }
    }
    $found = $false
    foreach ($p in $tries) { if (Test-Path -LiteralPath $p) { $found = $true; break } }
    $checked++
    if (-not $found) {
        # Downgrades before DEAD PATH (spec: checkpoint-tooling-false-exit2.md fix 3):
        # (a) absolute path OUTSIDE the workspace root -- external Drive-account folders etc.
        #     the verifier can't reach; not provably dead from here.
        $expNorm = $expanded -replace '/', '\'
        $wsRoot  = "$env:USERPROFILE\Documents\Claude"
        $isExternal = ($expNorm -match '^[A-Za-z]:') -and -not $expNorm.StartsWith($wsRoot, [System.StringComparison]::OrdinalIgnoreCase)
        # (b) the source line describes the path as intentionally gone -- a deletion RECORD,
        #     not a broken pointer. Brittle by design; the ignore file is the robust lane.
        $srcRemoved = $false
        foreach ($ln in $lines) {
            if ($ln.IndexOf($t, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $ln -match '(?i)\b(deleted|removed|reverted|shelved|retired)\b') { $srcRemoved = $true; break }
        }
        if ($t -match '(^|[\\/])specs?[\\/]') { $planned += $t }    # spec-planned future paths: report, don't block
        elseif ($isExternal) { $reviews += "EXTERNAL PATH (outside workspace, not checkable here -- confirm it still exists where it lives): $t" }
        elseif ($srcRemoved) { $reviews += "PATH DESCRIBED AS REMOVED (deliberate-deletion record, confirm intentional): $t" }
        else { $missing += $t }
    }
}
if ($missing.Count -gt 0) {
    $defects += "DEAD PATHS ($($missing.Count) of $checked checked) -- fix the pointer or the claim:"
    foreach ($p in ($missing | Sort-Object -Unique)) { $defects += "  MISSING: $p" }
}
if ($planned.Count -gt 0) {
    $reviews += "specs/-referenced paths not on disk (may be planned, verify intent): $((($planned | Sort-Object -Unique) -join ', '))"
}

# --- 2. Git claim probe ------------------------------------------------------
if ($text -match '(?i)unpushed|uncommitted|unstaged|commit\+push|push OWED|needs? push') {
    $inRepo = $false
    Push-Location $projRoot
    try {
        git rev-parse --is-inside-work-tree 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $inRepo = $true }
        if ($inRepo) {
            $dirty = @(git status --porcelain 2>$null).Count
            $ahead = @(git log --oneline '@{u}..HEAD' 2>$null).Count
            $reviews += "GIT CLAIMS PRESENT -- live truth: $dirty dirty path(s), $ahead unpushed commit(s). Reconcile every unpushed/uncommitted claim in the file against these numbers."
        } else {
            $reviews += "GIT CLAIMS PRESENT but $projRoot is not a git repo -- verify which repo the claims describe."
        }
    } catch {} finally { Pop-Location }
}

# --- 3. Staleness prompts ----------------------------------------------------
$cutoff = (Get-Date).AddDays(-30)
$inThreads = $false
foreach ($ln in $lines) {
    if ($ln -match '^##\s') { $inThreads = ($ln -match '^##\s+Open threads') ; continue }
    if (-not $inThreads) { continue }
    if ($ln -notmatch '^\s*-\s') { continue }
    $flag = @()
    foreach ($dm in [regex]::Matches($ln, '\b(20\d{2}-\d{2}-\d{2})\b')) {
        try { if ([datetime]::ParseExact($dm.Groups[1].Value, 'yyyy-MM-dd', $null) -lt $cutoff) { $flag += "date $($dm.Groups[1].Value)"; break } } catch {}
    }
    if ($ln -match '\[the owner\]') { $flag += 'owner-gated' }
    if ($flag.Count -gt 0) {
        $head = ($ln.Trim() -replace '^\-\s*', '')
        if ($head.Length -gt 90) { $head = $head.Substring(0, 90) + '...' }
        $prompts += "RE-CONFIRM OR PRUNE ($($flag -join ', ')): $head"
    }
}

# --- 3.7 Tag-convention prompts (added 2026-09-03) ---------------------------
# Every top-level Open-threads bullet ends with one gate tag ([owner] / [agent]) and one
# complexity tag ([low] / [high]); the list runs [owner][low], [owner][high],
# [agent][low], [agent][high]. Spec: agent-ladder/specs/complexity-flag-rollout.md.
# Prompts only, never failures; tags are checked, sub-headers are not.
$tagPrompts = @()
$inThreads = $false
$prevRank = -1
$orderFlagged = $false
# A bullet may wrap onto continuation lines and its pair sits at the TRUE end, so gather each
# top-level item (head + every following non-blank, non-bullet, non-header line, plus its
# sub-bullets) and judge the whole thing. (2026-09-03 fix: head-only reads flagged every
# wrapped bullet as TAG PAIR MISSING.)
$itemText = $null; $itemHead = $null
function Judge-Item {
    param([string]$text, [string]$head)
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $h = ($head.Trim() -replace '^\-\s*', ''); if ($h.Length -gt 70) { $h = $h.Substring(0, 70) + '...' }
    $gates = [regex]::Matches($text, '\[(owner|agent)\]').Count
    $cplx  = [regex]::Matches($text, '\[(low|high)\]').Count
    if ($text -match '\[(quick|moderate|heavy)\]|\[the owner decides[^\]]*\]') { $script:tagPrompts += "RETIRED TAG (convert to [owner]/[agent] + [low]/[high]): $h" }
    if ($gates -ne 1 -or $cplx -ne 1) { $script:tagPrompts += "TAG PAIR MISSING (need one of [owner]/[agent] and one of [low]/[high]): $h"; return }
    $rank = 0
    if ($text -match '\[agent\]') { $rank += 2 }
    if ($text -match '\[high\]')  { $rank += 1 }
    if ($rank -lt $script:prevRank -and -not $script:orderFlagged) { $script:tagPrompts += "ORDER (owner-low, owner-high, agent-low, agent-high) breaks at: $h"; $script:orderFlagged = $true }
    $script:prevRank = $rank
}
foreach ($ln in $lines) {
    if ($ln -match '^##\s') { Judge-Item $itemText $itemHead; $itemText = $null; $inThreads = ($ln -match '^##\s+Open threads') ; continue }
    if (-not $inThreads) { continue }
    if ($ln -match '^-\s') { Judge-Item $itemText $itemHead; $itemText = $ln; $itemHead = $ln; continue }
    if ($null -eq $itemText) { continue }
    if ($ln.Trim().Length -eq 0) { Judge-Item $itemText $itemHead; $itemText = $null; continue }
    $itemText += ' ' + $ln
}
Judge-Item $itemText $itemHead

# --- 3.5 Jargon prompts (added 2026-08-19, /prevent) -------------------------
# A CHECKPOINT is read cold weeks later by someone who cannot ask what a phrase means.
# the project policy people-words rule: the test is not "is it a code", it is "can a
# stranger resolve this without opening another file". These terms are defined only inside
# this workspace, so each one owes a plain-words gloss in the same breath. Advisory only --
# a term is fine WITH its gloss; this just makes you look. Live sections only; the
# changelog is history and is exempt.
$jargonTerms = @(
    'Codex rung', 'the mirror rule', 'block-once', 'glob ban', 'loads.ne.functions',
    'category \(?[a-d]\)?', 'read-once', 'grey node', 'yolo rung', 'reverse-subagent',
    'F0\d\d\b', 'B\d\d\b', 'the hedge rule', 'toxic agent'
)
$jargonHits = @()
$inLive = $true
foreach ($ln in $lines) {
    if ($ln -match '^##\s') { $inLive = ($ln -notmatch '^##\s+(Harness changelog|Changelog)') ; continue }
    if (-not $inLive) { continue }
    if ($ln.Trim().Length -eq 0) { continue }
    foreach ($t in $jargonTerms) {
        if ($ln -match $t) {
            $head = $ln.Trim(); if ($head.Length -gt 80) { $head = $head.Substring(0, 80) + '...' }
            $jargonHits += "GLOSS IT OR CUT IT ('$t'): $head"
            break
        }
    }
}

# --- Report ------------------------------------------------------------------
Write-Output "[verify-checkpoint] $ckPath"
Write-Output "[verify-checkpoint] paths checked: $checked"
if ($defects.Count -gt 0) { $defects | ForEach-Object { Write-Output $_ } }
if ($reviews.Count -gt 0) { Write-Output '-- REVIEW (reconcile before stamping):'; $reviews | ForEach-Object { Write-Output "  $_" } }
if ($prompts.Count -gt 0) { Write-Output '-- STALENESS PROMPTS (not failures):'; $prompts | ForEach-Object { Write-Output "  $_" } }
if ($tagPrompts.Count -gt 0) { Write-Output '-- TAG PROMPTS (not failures -- gate + complexity pair on every Open-threads bullet, four-run order):'; $tagPrompts | ForEach-Object { Write-Output "  $_" } }
if ($jargonHits.Count -gt 0) { Write-Output '-- JARGON PROMPTS (not failures -- fine if already glossed in the same breath):'; $jargonHits | ForEach-Object { Write-Output "  $_" } }
if ($defects.Count -gt 0) {
    Write-Output "[verify-checkpoint] EXIT 2: $($missing.Count) dead path(s). Fix, then re-run; the finisher comes AFTER this passes."
    exit 2
}
Write-Output '[verify-checkpoint] clean (mechanical checks only -- REVIEW/PROMPT items above still need your judgment).'
exit 0


