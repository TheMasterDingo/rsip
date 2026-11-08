<#
.SYNOPSIS
    Shows public profile information for a Star Citizen (RSI) handle.

.DESCRIPTION
    Fetches the citizen and organizations pages from robertsspaceindustries.com and
    prints the display name, handle, UEE citizen record, badge, enlistment date, location,
    fluency and organization memberships. Needs nothing beyond PowerShell 5.1 or later.

.PARAMETER Handle
    RSI handle to look up. You are prompted for one if it is omitted.

.PARAMETER Bio
    Also print the citizen's bio. Short form: -b

.PARAMETER AsObject
    Return the data as an object (including the bio) instead of printing it, for use in scripts.

.EXAMPLE
    ./rsip.ps1 MasterDingo -b

.EXAMPLE
    ./rsip.ps1 MasterDingo -AsObject | ConvertTo-Json
#>
[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [string]$Handle,

    [Alias('b')]
    [switch]$Bio,

    [switch]$AsObject
)

# Turn an HTML fragment into clean text: tags stripped, entities decoded, whitespace collapsed.
# Like a browser, only <br> produces a line break; newlines in the source are plain whitespace.
function ConvertFrom-HtmlText {
    param ([string]$Html)

    $text = [System.Net.WebUtility]::HtmlDecode(($Html -replace '<br\s*/?>', "`0" -replace '<[^>]+>', ''))
    $text = $text -replace '\s+', ' ' -replace ' ,', ','
    ($text -split "`0" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n"
}

# Clean text of the first capture group of $Pattern in $Html, or $Default when nothing matches.
function Find-Text {
    param ([string]$Html, [string]$Pattern, [string]$Default = 'Not Found')

    $text = if ($Html -match "(?s)$Pattern") { ConvertFrom-HtmlText $Matches[1] }
    if ($text) { $text } else { $Default }
}

# Value of a labelled entry, e.g. <span class="label">Enlisted</span><strong class="value">May 25, 2021</strong>
function Get-Entry {
    param ([string]$Html, [string]$Label, [string]$Default = 'Not Found')

    Find-Text $Html "<span class=`"label[^`"]*`">\s*$([regex]::Escape($Label))\s*</span>\s*<(?:strong|span|div) class=`"value[^`"]*`">(.*?)</(?:strong|span|div)>" $Default
}

# Organizations of one kind ('main' or 'affiliation') as "Name(SID, Rank)", or REDACTED when the citizen hides them.
function Get-Orgs {
    param ([string]$Html, [string]$Kind)

    $pattern = "(?s)<div class=`"box-content org $Kind([^`"]*)`">(.*?)(?=<div class=`"box-content org |\z)"
    foreach ($block in [regex]::Matches($Html, $pattern)) {
        if ($block.Groups[1].Value -match 'visibility-R') { 'REDACTED' }
        elseif ($block.Groups[2].Value -match '<a href="/orgs/([^"/]+)" class="value[^"]*">(.*?)</a>') {
            $sid, $name = $Matches[1], (ConvertFrom-HtmlText $Matches[2])
            $rank = Get-Entry $block.Groups[2].Value 'Organization rank' -Default ''
            '{0}({1})' -f $name, ((@($sid, $rank) -ne '') -join ', ')
        }
        else { 'Unknown' }
    }
}

# Print "Label: value | value" with the label in yellow, values in cyan and REDACTED in red.
function Write-Field {
    param ([string]$Label, [string[]]$Values)

    if (-not $Values) { $Values = @('None') }
    $indent = "`n" + ' ' * ($Label.Length + 2)   # continuation lines of multi-line values sit under the value
    Write-Host -NoNewline -ForegroundColor DarkYellow "${Label}: "
    for ($i = 0; $i -lt $Values.Count; $i++) {
        if ($i) { Write-Host -NoNewline -ForegroundColor DarkYellow ' | ' }
        $color = if ($Values[$i] -eq 'REDACTED') { 'DarkRed' } else { 'DarkCyan' }
        Write-Host -NoNewline -ForegroundColor $color ($Values[$i] -replace "`n", $indent)
    }
    Write-Host
}

if (-not $Handle) { $Handle = Read-Host 'Enter RSI Handle' }
$Handle = $Handle.Trim()
if (-not $Handle) { Write-Host -ForegroundColor Red 'No handle given.'; exit 1 }

$url = "https://robertsspaceindustries.com/citizens/$([uri]::EscapeDataString($Handle))"
try {
    $citizenHtml = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
    $orgHtml     = (Invoke-WebRequest -Uri "$url/organizations" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
}
catch {
    $status = [int]$_.Exception.Response.StatusCode   # 0 when no HTTP response came back at all
    $reason = $_.Exception.Message
    Write-Host -ForegroundColor Red $(switch ($status) {
        404     { "Citizen '$Handle' was not found (404)." }
        0       { "Request failed: $reason" }
        default { "HTTP error $status while contacting RSI." }
    })
    exit 1
}

$profile = [ordered]@{
    'Display Name'             = Find-Text $citizenHtml '<div class="info">\s*<p class="entry">\s*<strong class="value">(.*?)</strong>'
    'Handle Name'              = Get-Entry $citizenHtml 'Handle name'
    'UEE Citizen Record'       = Get-Entry $citizenHtml 'UEE Citizen Record'
    'Badge'                    = Find-Text $citizenHtml '<span class="icon">\s*<img[^>]*>\s*</span>\s*<span class="value">(.*?)</span>'
    'Enlisted Date'            = Get-Entry $citizenHtml 'Enlisted'
    'Location'                 = Get-Entry $citizenHtml 'Location' -Default 'Unknown'
    'Fluency'                  = Get-Entry $citizenHtml 'Fluency'
    'Bio'                      = Get-Entry $citizenHtml 'Bio'
    'Main Organization'        = Get-Orgs $orgHtml 'main'
    'Affiliated Organizations' = @(Get-Orgs $orgHtml 'affiliation')
}

# Every real profile has a handle, so a miss here means the page no longer looks like we expect.
if ($profile['Handle Name'] -eq 'Not Found') {
    Write-Warning 'This does not look like an RSI profile page; the site layout may have changed and the patterns in this script need updating.'
}

if ($AsObject) {
    $object = [ordered]@{ Url = $url }
    foreach ($entry in $profile.GetEnumerator()) { $object[$entry.Key -replace ' ', ''] = $entry.Value }
    return [pscustomobject]$object
}

Write-Host -NoNewline -ForegroundColor DarkGray 'Information extracted from: '; Write-Host -ForegroundColor White $url
foreach ($entry in $profile.GetEnumerator()) {
    if ($entry.Key -eq 'Bio' -and -not $Bio) { continue }
    Write-Field $entry.Key $entry.Value
}
