#requires -Version 5.1
<#
.SYNOPSIS
    Windows 10 Pro x64 en-US ISO builder v6.

.DESCRIPTION
    - Runs elevated.
    - Validates any existing ISO before downloading.
    - Requires Windows 10 22H2, x64, en-US, Professional.
    - If no suitable ISO exists, obtains the current Microsoft ISO through
      Microsoft's JSON connector API + session/Sentinel flow. It does NOT
      scrape productEditionId from the ISO page HTML.
    - Uses Microsoft Update Catalog to discover/download the required offline
      packages automatically.
    - For a 19045.2965 baseline, Microsoft requires special SSU KB5031539
      before the latest LCU KB5120249. KB5120249 is the August 2026 LCU
      targeting 19045.7663.
    - Exports only Professional, injects packages, includes AutoUnattend.xml,
      creates BIOS+UEFI bootable ISO, and computes SHA-256.

.NOTES
    Windows PowerShell 5.1 compatible.
    Requires Administrator.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

# ----------------------------
# Configuration
# ----------------------------
$Root = 'C:\Win10Builder'
$IsoDir = Join-Path $Root 'ISO'
$PackageDir = Join-Path $Root 'Packages'
$WorkDir = Join-Path $Root 'Work-v6'
$MountDir = Join-Path $WorkDir 'Mount'
$ExtractDir = Join-Path $WorkDir 'Source'
$ProWim = Join-Path $WorkDir 'install-Pro.wim'
$OutputDir = Join-Path $Root 'Output'
$LogDir = Join-Path $Root 'Logs'
$ToolsDir = Join-Path $Root 'Tools'

$AutoUnattend = Join-Path $Root 'autounattend.xml'
$Oscdimg = Join-Path $ToolsDir 'Oscdimg\oscdimg.exe'
$Efisys = Join-Path $ToolsDir 'Oscdimg\efisys.bin'
$Etfsboot = Join-Path $ToolsDir 'Oscdimg\etfsboot.com'

$TargetIso = Join-Path $IsoDir 'Win10_22H2_English_US_x64.iso'
$FinalIso = Join-Path $OutputDir 'Windows10_22H2_Pro_en-US_x64_19045.7663.iso'

$TargetEditionId = 2618       # Microsoft/Fido current Win10 22H2 Home/Pro/Edu multi-edition
$TargetLanguage = 'en-US'
$TargetArch = 'x64'
$TargetBuild = 19045
$TargetRevision = 7663
$TargetKB = 'KB5120249'
$SpecialOfflineSSU = 'KB5031539'

# Microsoft connector/session constants used by current Fido implementations.
$OrgId = 'y6jn8c31'
$ProfileId = '606624d44113'
$InstanceId = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'

$MicrosoftIsoPage = 'https://www.microsoft.com/en-us/software-download/windows10ISO'
$ConnectorApi = 'https://www.microsoft.com/software-download-connector/api'
$CatalogBase = 'https://www.catalog.update.microsoft.com'

$script:LogFile = $null
$script:MountedIsoPath = $null
$script:MountedDrive = $null
$script:ImageMounted = $false

# ----------------------------
# Output helpers
# ----------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line
    }
}

function Step {
    param([string]$Title, [int]$Number)
    Write-Host ''
    Write-Host ('=' * 64)
    Write-Host ("{0}/12 - {1}" -f $Number, $Title)
    Write-Host ('=' * 64)
    Write-Log $Title
}

function Fail {
    param([string]$Message)
    Write-Log $Message 'ERROR'
    throw $Message
}

function Require-Path {
    param([string]$Path, [string]$Description)
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail "$Description not found: $Path"
    }
    Write-Log "$Description : $Path" 'OK'
}

function New-Directories {
    foreach ($p in @($Root,$IsoDir,$PackageDir,$WorkDir,$MountDir,$ExtractDir,$OutputDir,$LogDir,$ToolsDir)) {
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
}

# ----------------------------
# Elevation
# ----------------------------
function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host 'Administrator privileges are required. Requesting UAC elevation...'
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $argList -Verb RunAs
    exit 0
}

# ----------------------------
# Native command runner
# ----------------------------
function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Description
    )

    Write-Log $Description
    & $FilePath @Arguments
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Fail "$Description failed. Exit code: $code"
    }
    return $code
}

function Get-DismInfoText {
    param([string[]]$Arguments)
    $out = & dism.exe @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Fail ("DISM failed with exit code {0}: {1}" -f $code, (($out | Out-String).Trim()))
    }
    return ($out | Out-String)
}

# ----------------------------
# ISO validation
# ----------------------------
function Get-IsoImageFile {
    param([string]$DriveLetter)

    $wim = Join-Path $DriveLetter 'sources\install.wim'
    $esd = Join-Path $DriveLetter 'sources\install.esd'

    if (Test-Path -LiteralPath $wim) { return $wim }
    if (Test-Path -LiteralPath $esd) { return $esd }
    return $null
}

function Get-ProIndex {
    param([string]$ImageFile)

    $text = Get-DismInfoText @('/Get-WimInfo', "/WimFile:$ImageFile")

    $currentIndex = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') {
            $currentIndex = [int]$matches[1]
            continue
        }

        if ($currentIndex -and $line -match '^\s*Name\s*:\s*Windows 10 Pro\s*$') {
            return $currentIndex
        }
    }

    return $null
}

function Get-ImageMetadata {
    param([string]$ImageFile, [int]$Index)

    $text = Get-DismInfoText @('/Get-WimInfo', "/WimFile:$ImageFile", "/Index:$Index")
    $meta = [ordered]@{
        Architecture = $null
        Version = $null
        Build = $null
        Edition = $null
        Languages = @()
    }

    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*Architecture\s*:\s*(.+)$') { $meta.Architecture = $matches[1].Trim() }
        elseif ($line -match '^\s*Version\s*:\s*(.+)$') { $meta.Version = $matches[1].Trim() }
        elseif ($line -match '^\s*ServicePack Build\s*:\s*(.+)$') { $meta.Build = $matches[1].Trim() }
        elseif ($line -match '^\s*Edition\s*:\s*(.+)$') { $meta.Edition = $matches[1].Trim() }
        elseif ($line -match '^\s{8}([a-z]{2}-[A-Z]{2})\s+\(') { $meta.Languages += $matches[1] }
    }

    [pscustomobject]$meta
}

function Validate-SourceIso {
    param([string]$IsoPath)

    if (-not (Test-Path -LiteralPath $IsoPath)) {
        return $false
    }

    Write-Log "Checking ISO: $IsoPath"
    $hash = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash
    Write-Log "ISO SHA-256: $hash"

    $disk = $null
    try {
        $disk = Mount-DiskImage -ImagePath $IsoPath -PassThru
        Start-Sleep -Seconds 2
        $vol = Get-Volume -DiskImage $disk | Where-Object DriveLetter | Select-Object -First 1
        if (-not $vol) { throw 'Could not determine mounted ISO drive letter.' }

        $drive = "$($vol.DriveLetter):"
        $image = Get-IsoImageFile -DriveLetter $drive
        if (-not $image) { throw 'ISO has neither sources\install.wim nor sources\install.esd.' }

        $index = Get-ProIndex -ImageFile $image
        if (-not $index) {
            throw 'Windows 10 Pro image was not found.'
        }

        $meta = Get-ImageMetadata -ImageFile $image -Index $index

        Write-Log ("Pro index={0}; Architecture={1}; Version={2}; SPBuild={3}; Edition={4}; Languages={5}" -f `
            $index,$meta.Architecture,$meta.Version,$meta.Build,$meta.Edition,($meta.Languages -join ','))

        if ($meta.Architecture -ne 'x64') { throw 'Source Pro image is not x64.' }
        if ($meta.Edition -ne 'Professional') { throw 'Source Pro image is not Professional.' }
        if ($meta.Languages -notcontains $TargetLanguage) {
            throw "Source Pro image does not contain $TargetLanguage."
        }

        if ($meta.Version -notmatch '^10\.0\.19045') {
            throw "Source Pro image is not Windows 10 22H2 (19045). Detected: $($meta.Version)"
        }

        Write-Log 'Existing ISO is a valid en-US x64 Windows 10 22H2 Pro source.' 'OK'
        return $true
    }
    catch {
        Write-Log "ISO rejected: $($_.Exception.Message)" 'WARN'
        return $false
    }
    finally {
        if ($null -ne $disk) {
            try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    }
}

# ----------------------------
# Microsoft current JSON API
# ----------------------------
function New-WebSession {
    $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $s.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
    return $s
}

function Invoke-WebRetry {
    param(
        [string]$Uri,
        [ValidateSet('GET','POST')][string]$Method = 'GET',
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [hashtable]$Headers,
        [object]$Body,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Write-Log "API request $attempt/$Attempts : $Uri"
            $params = @{
                Uri = $Uri
                Method = $Method
                WebSession = $Session
                UseBasicParsing = $true
                TimeoutSec = 60
                MaximumRedirection = 5
            }
            if ($Headers) { $params.Headers = $Headers }
            if ($null -ne $Body) {
                $params.Body = $Body
                $params.ContentType = 'application/x-www-form-urlencoded'
            }
            return Invoke-WebRequest @params
        }
        catch {
            Write-Log "Request failed: $($_.Exception.Message)" 'WARN'
            if ($attempt -lt $Attempts) {
                Start-Sleep -Seconds ($DelaySeconds * $attempt)
            } else {
                throw
            }
        }
    }
}

function Get-MicrosoftIso {
    param(
        [string]$TargetLanguage = 'en-US',
        [string]$IsoDir = $(Join-Path $PSScriptRoot 'ISO'),
        [int]$MaxApiAttempts = 2,
        [int]$PollSeconds = 10,
        [int]$MaxPollMinutes = 30
    )

    if (-not (Test-Path -LiteralPath $IsoDir)) {
        New-Item -ItemType Directory -Path $IsoDir -Force | Out-Null
    }

    $officialPage = 'https://www.microsoft.com/en-us/software-download/windows10iso'
    $targetPath = Join-Path $IsoDir 'Win10_22H2_English_x64.iso'

    Write-Section "3/12 - Obtaining Microsoft en-US x64 ISO"
    Write-Log "No valid local en-US x64 Windows 10 22H2 Pro ISO found." 'WARN'

    function Test-TargetIso {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        try {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($item.Length -lt 100MB) { return $false }
            $meta = Get-IsoProMetadata -IsoPath $Path
            $build19045 = ([string]$meta.Version -match '^10\.0\.19045$') -or ([string]$meta.Build -eq '19045')
            return (
                [string]$meta.Architecture -eq 'x64' -and
                @($meta.Languages) -contains 'en-US' -and
                [string]$meta.Edition -match 'Professional' -and
                $build19045
            )
        } catch { return $false }
    }

    function Find-ValidTargetIso {
        foreach ($f in @(Get-ChildItem -LiteralPath $IsoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue)) {
            if (Test-TargetIso $f.FullName) { return $f.FullName }
        }
        return $null
    }

    # If a valid ISO appeared between Step 2 and Step 3, use it immediately.
    $alreadyThere = Find-ValidTargetIso
    if ($alreadyThere) {
        Write-Log "Valid ISO found before Microsoft download step: $alreadyThere" 'OK'
        return $alreadyThere
    }

    # Try the connector only as an optimization. SentinelReject is NEVER a
    # terminating error and does not get re-thrown.
    for ($attempt = 1; $attempt -le $MaxApiAttempts; $attempt++) {
        try {
            Write-Log "Microsoft connector attempt $attempt/$MaxApiAttempts" 'INFO'
            $sessionId = [guid]::NewGuid().Guid
            $profile = '606624d44113'
            $productEditionId = '2618'
            $headers = @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36'
                'Accept' = 'application/json, text/plain, */*'
                'Referer' = $officialPage
            }

            foreach ($u in @(
                "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$sessionId",
                "https://ov-df.microsoft.com/mdt.js?instanceId=560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175&PageId=si&session_id=$sessionId",
                "https://ov-df.microsoft.com/?session_id=$sessionId&CustomerId=560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175&PageId=si"
            )) {
                try { Invoke-WebRequest -Uri $u -Headers $headers -UseBasicParsing -TimeoutSec 30 | Out-Null } catch {}
            }

            $skuUrl = "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=$profile&ProductEditionId=$productEditionId&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$sessionId"
            $skuJson = (Invoke-WebRequest -Uri $skuUrl -Headers $headers -UseBasicParsing -TimeoutSec 45).Content | ConvertFrom-Json
            $skus = Get-JsonPropertyValue -Object $skuJson -Name 'Skus'
            $sku = @($skus) | Where-Object {
                (Get-JsonPropertyValue -Object $_ -Name 'Language') -eq 'en-US' -or
                (Get-JsonPropertyValue -Object $_ -Name 'LocalizedLanguage') -match 'English.*United States'
            } | Select-Object -First 1

            if (-not $sku) { throw 'No en-US SKU returned.' }

            $skuId = Get-JsonPropertyValue -Object $sku -Name 'SKU'
            if (-not $skuId) { $skuId = Get-JsonPropertyValue -Object $sku -Name 'Sku' }
            if (-not $skuId) { throw 'No SKU identifier returned.' }

            Write-Log "Microsoft en-US SKU: $skuId" 'OK'

            $linkUrl = "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=$profile&ProductEditionId=undefined&SKU=$skuId&friendlyFileName=undefined&Locale=en-US&sessionID=$sessionId"
            $linkContent = (Invoke-WebRequest -Uri $linkUrl -Headers $headers -UseBasicParsing -TimeoutSec 60).Content
            $linkJson = $linkContent | ConvertFrom-Json

            $apiError = Get-MicrosoftApiErrors -Json $linkJson
            if ($apiError -match 'SentinelReject') {
                Write-Log "Microsoft Sentinel rejected the automated link request; switching to official-page fallback." 'WARN'
                break
            }
            if ($apiError) { throw "Microsoft link API: $apiError" }

            $urls = New-Object System.Collections.Generic.List[string]
            function Collect-Urls {
                param([object]$Node)
                if ($null -eq $Node) { return }
                if ($Node -is [string]) {
                    foreach ($m in [regex]::Matches($Node, 'https?://[^\s"''<>\\]+', 'IgnoreCase')) { [void]$urls.Add($m.Value) }
                    return
                }
                if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [System.Collections.IDictionary])) {
                    foreach ($x in $Node) { Collect-Urls $x }
                    return
                }
                foreach ($p in $Node.PSObject.Properties) { Collect-Urls $p.Value }
            }
            Collect-Urls $linkJson

            $isoUrl = @($urls) |
                ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_) -replace '\\u0026','&' } |
                Sort-Object -Unique |
                Where-Object { $_ -match '(?i)\.iso(?:[?&]|$)' } |
                Where-Object { $_ -match '(?i)(x64|amd64|64-bit)' } |
                Select-Object -First 1

            if (-not $isoUrl) {
                $isoUrl = @($urls) |
                    ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_) -replace '\\u0026','&' } |
                    Sort-Object -Unique |
                    Where-Object { $_ -match '(?i)\.iso(?:[?&]|$)' } |
                    Select-Object -First 1
            }

            if (-not $isoUrl) { throw 'Microsoft link API returned no ISO URL.' }

            if (Test-Path -LiteralPath $targetPath) { Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue }
            Write-Log "Microsoft ISO URL obtained. Downloading..." 'OK'
            Invoke-WebRequest -Uri $isoUrl -OutFile $targetPath -UseBasicParsing -TimeoutSec 3600

            $downloaded = Find-ValidTargetIso
            if ($downloaded) {
                Write-Log "Downloaded ISO passed validation: $downloaded" 'OK'
                return $downloaded
            }

            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
            Write-Log "Downloaded ISO failed validation." 'WARN'
        }
        catch {
            Write-Log "Microsoft connector attempt $attempt failed (fallback will continue): $($_.Exception.Message)" 'WARN'
        }

        if ($attempt -lt $MaxApiAttempts) {
            Start-Sleep -Seconds 10
        }
    }

    # IMPORTANT: no throw here for SentinelReject. Open Microsoft's official
    # page and wait for the user to complete Microsoft's normal download flow.
    Write-Section "3A/12 - Official Microsoft ISO fallback"
    Write-Log "Opening official Microsoft Windows 10 ISO download page." 'WARN'
    Write-Log "Select Windows 10 22H2, English (United States), 64-bit." 'INFO'
    Write-Log "Save the ISO anywhere in: $IsoDir" 'INFO'
    Write-Log "Polling every $PollSeconds seconds for up to $MaxPollMinutes minutes." 'INFO'

    try { Start-Process $officialPage | Out-Null } catch {
        Write-Log "Could not open browser automatically: $($_.Exception.Message)" 'WARN'
    }

    $deadline = (Get-Date).AddMinutes($MaxPollMinutes)
    while ((Get-Date) -lt $deadline) {
        $found = Find-ValidTargetIso
        if ($found) {
            Write-Log "Valid Microsoft ISO detected: $found" 'OK'
            return $found
        }
        Start-Sleep -Seconds $PollSeconds
    }

    throw "No valid Windows 10 22H2 en-US x64 Pro-capable ISO was found in $IsoDir within $MaxPollMinutes minutes. Complete the official Microsoft download and run the builder again."
}


# ----------------------------
# curl download with resume/retry
# ----------------------------
function Download-WithCurl {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Label
    )

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) {
        Fail 'curl.exe was not found in System32.'
    }

    $temp = "$Destination.part"
    Write-Log "Downloading $Label"
    Write-Log "Destination: $Destination"

    # -C - resumes partial file; --retry retries transient failures.
    # --progress-bar provides visible progress/speed/ETA.
    $args = @(
        '-L',
        '--fail',
        '--retry','5',
        '--retry-delay','5',
        '--retry-all-errors',
        '-C','-',
        '--progress-bar',
        '-o',$temp,
        $Url
    )

    & $curl @args
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Fail "$Label download failed. curl exit code: $code. Partial file retained: $temp"
    }

    if (-not (Test-Path -LiteralPath $temp)) {
        Fail "curl reported success but download file was not created: $temp"
    }

    Move-Item -LiteralPath $temp -Destination $Destination -Force
    Write-Log "$Label download completed." 'OK'
}

# ----------------------------
# Microsoft Update Catalog
# ----------------------------
function Get-CatalogUpdateGuids {
    param([string]$Kb)

    $q = [Uri]::EscapeDataString($Kb)
    $uri = "$CatalogBase/Search.aspx?q=$q"
    $resp = Invoke-WebRetry -Uri $uri -Session (New-WebSession) -Attempts 3

    $content = $resp.Content

    # Catalog search rows expose GUIDs in download buttons/row data.
    $patterns = @(
        'id\s*=\s*["'']([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})["'']',
        'updateID\s*[:=]\s*["'']([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})["'']'
    )

    $guids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($content,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            [void]$guids.Add($m.Groups[1].Value)
        }
    }

    if ($guids.Count -eq 0) {
        Fail "Could not find Microsoft Update Catalog update IDs for $Kb."
    }

    return @($guids)
}

function Get-CatalogDownloadFiles {
    param([string]$Guid)

    $payload = @{
        size = 0
        updateID = $Guid
        uidInfo = $Guid
    } | ConvertTo-Json -Compress

    $body = @{ updateIDs = "[$payload]" }

    $session = New-WebSession
    $resp = Invoke-WebRetry -Uri "$CatalogBase/DownloadDialog.aspx" `
        -Method POST `
        -Session $session `
        -Body $body `
        -Headers @{ Referer = $CatalogBase } `
        -Attempts 3

    $pattern = "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'"
    $matches = [regex]::Matches($resp.Content,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $items = @()
    foreach ($m in $matches) {
        $u = $m.Groups[1].Value -replace '\\u0026','&' -replace '&amp;','&'
        $items += [pscustomobject]@{
            Url = $u
            FileName = [IO.Path]::GetFileName(([Uri]$u).AbsolutePath)
        }
    }

    return $items
}

function Get-CatalogPackage {
    param(
        [string]$Kb,
        [string]$RequiredTitlePattern
    )

    Write-Log "Searching Microsoft Update Catalog for $Kb"

    $guids = Get-CatalogUpdateGuids -Kb $Kb
    $candidates = @()

    foreach ($guid in $guids) {
        try {
            $files = Get-CatalogDownloadFiles -Guid $guid
            foreach ($f in $files) {
                $candidates += [pscustomobject]@{
                    Guid = $guid
                    Url = $f.Url
                    FileName = $f.FileName
                }
            }
        } catch {
            Write-Log "Catalog GUID $guid could not be expanded: $($_.Exception.Message)" 'WARN'
        }
    }

    if (-not $candidates) {
        Fail "Microsoft Update Catalog returned no downloadable files for $Kb."
    }

    # Prefer x64 and MSU. The search term itself limits the KB.
    $pick = $candidates | Where-Object {
        $_.FileName -match '\.msu$' -and
        $_.FileName -match '(x64|amd64)' -and
        $_.FileName -notmatch '(arm64|x86)'
    } | Select-Object -First 1

    if (-not $pick) {
        $pick = $candidates | Where-Object {
            $_.FileName -match '\.msu$'
        } | Select-Object -First 1
    }

    if (-not $pick) {
        Fail "Could not select an x64 MSU for $Kb."
    }

    Write-Log "Selected package: $($pick.FileName)" 'OK'
    return $pick
}

# ----------------------------
# DISM servicing
# ----------------------------
function Get-MountedImages {
    $out = & dism.exe /Get-MountedWimInfo 2>&1
    return ($out | Out-String)
}

function Cleanup-Mount {
    try {
        & dism.exe /English /Cleanup-Wim | Out-Null
    } catch {}
}

function Dismount-ImageSafe {
    if ($script:ImageMounted) {
        Write-Log 'Dismounting Windows image.'
        & dism.exe /Unmount-Wim "/MountDir:$MountDir" /Discard | Out-Null
        $script:ImageMounted = $false
    }
}

function Expand-ProOnly {
    param([string]$SourceImage, [int]$ProIndex)

    if (Test-Path -LiteralPath $ProWim) {
        Remove-Item -LiteralPath $ProWim -Force
    }

    Invoke-Native 'dism.exe' @(
        '/Export-Image',
        "/SourceImageFile:$SourceImage",
        "/SourceIndex:$ProIndex",
        "/DestinationImageFile:$ProWim",
        '/Compress:max',
        '/CheckIntegrity'
    ) 'Exporting Windows 10 Pro only image'

    Require-Path $ProWim 'Professional WIM'
}

function Mount-ProImage {
    if (Test-Path -LiteralPath $MountDir) {
        $items = Get-ChildItem -LiteralPath $MountDir -Force -ErrorAction SilentlyContinue
        if ($items) {
            Cleanup-Mount
            Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    New-Item -ItemType Directory -Path $MountDir -Force | Out-Null

    Invoke-Native 'dism.exe' @(
        '/Mount-Wim',
        "/WimFile:$ProWim",
        '/Index:1',
        "/MountDir:$MountDir"
    ) 'Mounting Professional image'

    $script:ImageMounted = $true
}

function Get-MountedPackageNames {
    $out = & dism.exe /Image:$MountDir /Get-Packages 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail 'Unable to enumerate packages in mounted image.'
    }
    return ($out | Out-String)
}

function Add-Package {
    param([string]$PackagePath, [string]$Label)

    $packages = Get-MountedPackageNames
    $kb = [IO.Path]::GetFileNameWithoutExtension($PackagePath)

    if ($packages -match [regex]::Escape($kb)) {
        Write-Log "$Label appears to already be installed; skipping."
        return
    }

    Invoke-Native 'dism.exe' @(
        "/Image:$MountDir",
        '/Add-Package',
        "/PackagePath:$PackagePath",
        '/NoRestart'
    ) "Injecting $Label"
}

# ----------------------------
# Main
# ----------------------------
New-Directories

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile = Join-Path $LogDir "Build-v6-$timestamp.log"

try {
    Write-Host ''
    Write-Host 'Running as Administrator.' -ForegroundColor Green

    Step 'Checking local tools' 1
    Require-Path $Oscdimg 'oscdimg.exe'
    Require-Path $Efisys 'UEFI boot image'
    Require-Path $Etfsboot 'BIOS boot image'
    Require-Path $AutoUnattend 'autounattend.xml'
    Require-Path (Join-Path $env:SystemRoot 'System32\dism.exe') 'DISM'

    Step 'Checking source ISO candidates' 2
    $existing = Get-ChildItem -LiteralPath $IsoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue
    $sourceIso = $null

    foreach ($iso in $existing) {
        Write-Log "Found ISO: $($iso.FullName)"
        if (Validate-SourceIso -IsoPath $iso.FullName) {
            $sourceIso = $iso.FullName
            break
        }
    }

    if (-not $sourceIso) {
        Write-Log 'No valid en-US x64 Windows 10 22H2 Pro source ISO found.' 'WARN'
    }

    Step 'Obtaining Microsoft en-US x64 ISO through current JSON API/session' 3
    if (-not $sourceIso) {
        if (Test-Path -LiteralPath $TargetIso) {
            if (Validate-SourceIso -IsoPath $TargetIso) {
                $sourceIso = $TargetIso
            } else {
                Remove-Item -LiteralPath $TargetIso -Force -ErrorAction SilentlyContinue
            }
        }

        if (-not $sourceIso) {
            $isoUrl = Get-MicrosoftIsoUrl
            Download-WithCurl -Url $isoUrl -Destination $TargetIso -Label 'Microsoft Windows 10 en-US x64 ISO'

            if (-not (Validate-SourceIso -IsoPath $TargetIso)) {
                Fail 'Downloaded Microsoft ISO failed source validation.'
            }

            $sourceIso = $TargetIso
        }
    }

    Write-Log "Selected source ISO: $sourceIso" 'OK'

    Step 'Preparing clean workspace' 4
    if ($script:ImageMounted) { Dismount-ImageSafe }
    Cleanup-Mount

    foreach ($p in @($ExtractDir,$MountDir)) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }

    Step 'Exporting Professional only' 5
    $disk = Mount-DiskImage -ImagePath $sourceIso -PassThru
    Start-Sleep -Seconds 2
    $vol = Get-Volume -DiskImage $disk | Where-Object DriveLetter | Select-Object -First 1
    if (-not $vol) { throw 'Unable to determine source ISO drive letter.' }
    $srcDrive = "$($vol.DriveLetter):"
    $srcImage = Get-IsoImageFile -DriveLetter $srcDrive
    if (-not $srcImage) { throw 'Source ISO has no install.wim/install.esd.' }

    $proIndex = Get-ProIndex -ImageFile $srcImage
    if (-not $proIndex) { throw 'Windows 10 Pro index not found.' }
    Write-Log "Professional source index: $proIndex"

    Expand-ProOnly -SourceImage $srcImage -ProIndex $proIndex
    Dismount-DiskImage -ImagePath $sourceIso -ErrorAction SilentlyContinue | Out-Null
    $disk = $null

    Step 'Mounting Professional image' 6
    Mount-ProImage
    $info = Get-DismInfoText @('/Get-WimInfo', "/WimFile:$ProWim", '/Index:1')
    Write-Log (($info -split "`r?`n" | Where-Object { $_ -match 'Name|Architecture|Version|ServicePack Build|Edition|Languages' }) -join '; ')

    Step 'Checking installed packages' 7
    $pkgText = Get-MountedPackageNames
    Write-Log 'Package inventory acquired.'

    Step 'Preparing required Microsoft packages' 8
    # The source baseline you tested is 19045.2965. Microsoft explicitly says
    # that for offline servicing below KB5028244, KB5031539 must be installed
    # before the current LCU.
    $ssu = Get-CatalogPackage -Kb $SpecialOfflineSSU -RequiredTitlePattern 'Servicing Stack Update'
    $lcu = Get-CatalogPackage -Kb $TargetKB -RequiredTitlePattern 'Cumulative Update'

    $ssuPath = Join-Path $PackageDir $ssu.FileName
    $lcuPath = Join-Path $PackageDir $lcu.FileName

    if (-not (Test-Path -LiteralPath $ssuPath)) {
        Download-WithCurl -Url $ssu.Url -Destination $ssuPath -Label $SpecialOfflineSSU
    } else {
        Write-Log "Cached package found: $ssuPath" 'OK'
    }

    if (-not (Test-Path -LiteralPath $lcuPath)) {
        Download-WithCurl -Url $lcu.Url -Destination $lcuPath -Label $TargetKB
    } else {
        Write-Log "Cached package found: $lcuPath" 'OK'
    }

    Write-Log "$SpecialOfflineSSU SHA-256: $((Get-FileHash $ssuPath -Algorithm SHA256).Hash)"
    Write-Log "$TargetKB SHA-256: $((Get-FileHash $lcuPath -Algorithm SHA256).Hash)"

    Step 'Injecting packages in Microsoft-required order' 9
    Add-Package -PackagePath $ssuPath -Label $SpecialOfflineSSU
    Add-Package -PackagePath $lcuPath -Label $TargetKB

    Step 'Verifying target build and adding AutoUnattend.xml' 10
    $verify = Get-DismInfoText @('/Get-CurrentEdition', "/Image:$MountDir")
    Write-Log $verify.Trim()

    $mountedInfo = Get-DismInfoText @('/Get-WimInfo', "/WimFile:$ProWim", '/Index:1')
    if ($mountedInfo -notmatch 'ServicePack Build\s*:\s*7663') {
        Write-Log 'WIM metadata did not expose 7663 immediately; committing image and rechecking.' 'WARN'
    }

    Copy-Item -LiteralPath $AutoUnattend -Destination (Join-Path $ExtractDir 'AutoUnattend.xml') -Force

    Step 'Committing Professional WIM and constructing ISO tree' 11
    if ($script:ImageMounted) {
        Invoke-Native 'dism.exe' @(
            '/Unmount-Wim',
            "/MountDir:$MountDir",
            '/Commit'
        ) 'Committing serviced Professional image'
        $script:ImageMounted = $false
    }

    # Copy original ISO files to output tree, replacing install.wim and removing other editions.
    if (Test-Path -LiteralPath $ExtractDir) {
        Remove-Item -LiteralPath $ExtractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

    $disk = Mount-DiskImage -ImagePath $sourceIso -PassThru
    Start-Sleep -Seconds 2
    $vol = Get-Volume -DiskImage $disk | Where-Object DriveLetter | Select-Object -First 1
    $srcDrive = "$($vol.DriveLetter):"

    Write-Log 'Copying ISO source tree.'
    & robocopy.exe $srcDrive $ExtractDir /E /R:2 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -gt 7) { Fail "robocopy failed with exit code $rc" }

    Dismount-DiskImage -ImagePath $sourceIso -ErrorAction SilentlyContinue | Out-Null
    $disk = $null

    $oldWim = Join-Path $ExtractDir 'sources\install.wim'
    $oldEsd = Join-Path $ExtractDir 'sources\install.esd'
    if (Test-Path -LiteralPath $oldEsd) { Remove-Item -LiteralPath $oldEsd -Force }
    if (Test-Path -LiteralPath $oldWim) { Remove-Item -LiteralPath $oldWim -Force }

    Copy-Item -LiteralPath $ProWim -Destination (Join-Path $ExtractDir 'sources\install.wim') -Force
    Copy-Item -LiteralPath $AutoUnattend -Destination (Join-Path $ExtractDir 'AutoUnattend.xml') -Force

    # With a single-image WIM, Windows Setup uses that Pro image without exposing
    # the other editions from the original source.
    if (Test-Path -LiteralPath $FinalIso) {
        Remove-Item -LiteralPath $FinalIso -Force
    }

    $isoArgs = @(
        '-m',
        '-o',
        '-u2',
        '-udfver102',
        "-bootdata:2#p0,e,b$Etfsboot#pEF,e,b$Efisys",
        $ExtractDir,
        $FinalIso
    )

    Invoke-Native $Oscdimg $isoArgs 'Creating BIOS+UEFI bootable ISO'

    Step 'Final verification and SHA-256' 12
    Require-Path $FinalIso 'Final ISO'

    $finalHash = (Get-FileHash -LiteralPath $FinalIso -Algorithm SHA256).Hash
    $finalSize = (Get-Item -LiteralPath $FinalIso).Length

    # Verify final WIM has exactly one image and it is Professional x64.
    $finalWim = Join-Path $ExtractDir 'sources\install.wim'
    $finalInfo = Get-DismInfoText @('/Get-WimInfo', "/WimFile:$finalWim", '/Index:1')

    if ($finalInfo -notmatch 'Name\s*:\s*Windows 10 Pro') {
        Fail 'Final WIM verification failed: Windows 10 Pro not detected.'
    }
    if ($finalInfo -notmatch 'Architecture\s*:\s*x64') {
        Fail 'Final WIM verification failed: x64 not detected.'
    }
    if ($finalInfo -notmatch 'Edition\s*:\s*Professional') {
        Fail 'Final WIM verification failed: Professional edition not detected.'
    }

    $report = @"
Windows 10 Pro ISO Builder v6
=============================

Source ISO:
$sourceIso

Target:
Windows 10 22H2
Edition: Professional
Architecture: x64
Language: en-US
Target OS Build: 19045.7663
LCU: KB5120249
Offline prerequisite SSU: KB5031539

Final ISO:
$FinalIso

Size:
$finalSize bytes

SHA-256:
$finalHash

Verified:
- WIM contains Windows 10 Pro
- WIM architecture is x64
- WIM edition is Professional
- AutoUnattend.xml included at ISO root
- BIOS boot image included
- UEFI boot image included

Build completed:
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

    $reportPath = Join-Path $OutputDir 'Windows10_Pro_v6_BUILD_REPORT.txt'
    Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8

    Write-Host ''
    Write-Host ('=' * 64)
    Write-Host 'BUILD SUCCESSFUL' -ForegroundColor Green
    Write-Host ('=' * 64)
    Write-Host "ISO:    $FinalIso"
    Write-Host "SHA256: $finalHash"
    Write-Host "Report: $reportPath"
    Write-Host "Log:    $script:LogFile"
}
catch {
    Write-Host ''
    Write-Host 'BUILD FAILED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value ''
        Add-Content -LiteralPath $script:LogFile -Value 'BUILD FAILED'
        Add-Content -LiteralPath $script:LogFile -Value $_.Exception.ToString()
    }

    if ($script:ImageMounted) {
        try {
            Write-Log 'Attempting safe image dismount.'
            & dism.exe /Unmount-Wim "/MountDir:$MountDir" /Discard | Out-Null
            $script:ImageMounted = $false
        } catch {}
    }

    try {
        Write-Host ''
        Write-Host 'Mounted-image status:'
        & dism.exe /Get-MountedWimInfo
    } catch {}

    exit 1
}
finally {
    if ($null -ne $disk) {
        try { Dismount-DiskImage -ImagePath $sourceIso -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}
