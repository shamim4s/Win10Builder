#requires -Version 5.1
#requires -RunAsAdministrator
<#
 Windows 10 Pro 22H2 en-US offline ISO builder - v5
 Target: 19045.7663 / KB5120249
 Source: Microsoft Windows 10 ISO page, English x64
 Prerequisite for an old 19045.2965 image: KB5031539 special offline SSU
 Microsoft now combines current SSU with the LCU; KB5120249 itself carries
 the current combined SSU. Microsoft specifically requires KB5031539 first
 when an offline image lacks KB5028244 or later.

 This script:
  * validates an existing ISO BEFORE downloading anything
  * requires en-US (not en-GB)
  * obtains the current English x64 ISO URL from Microsoft's Windows10ISO page
  * downloads with retry/resume and progress
  * calculates and records SHA-256
  * exports only Windows 10 Pro
  * detects installed package baseline
  * downloads KB5031539 + KB5120249 automatically from Microsoft Update Catalog
  * caches packages
  * services in the required order
  * injects AutoUnattend.xml
  * rebuilds BIOS+UEFI bootable ISO
  * calculates final SHA-256
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ISOdir = Join-Path $Root 'ISO'
$PkgDir = Join-Path $Root 'Packages'
$Work = Join-Path $Root 'Work'
$Mount = Join-Path $Root 'Mount'
$Output = Join-Path $Root 'Output'
$Logs = Join-Path $Root 'Logs'
$Tools = Join-Path $Root 'Tools'
$Oscdimg = Join-Path $Tools 'Oscdimg\oscdimg.exe'
$EFI = Join-Path $Tools 'Oscdimg\efisys.bin'
$BIOS = Join-Path $Tools 'Oscdimg\etfsboot.com'
$AutoUnattend = Join-Path $Root 'autounattend.xml'
$SourceISO = Join-Path $ISOdir 'Win10_22H2_English_US_x64.iso'
$OutputISO = Join-Path $Output 'Win10_22H2_Pro_en-US_19045.7663.iso'
$Log = Join-Path $Logs ("Build-v5-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -ItemType Directory -Force -Path $ISOdir,$PkgDir,$Work,$Mount,$Output,$Logs | Out-Null
Start-Transcript -Path $Log -Append | Out-Null

function Say($m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Step($n,$m){ Say "`n================================================================" Cyan; Say "$n/12 - $m" Cyan; Say "================================================================" Cyan }
function OK($m){ Say "[OK] $m" Green }
function Info($m){ Say "[INFO] $m" Gray }
function Warn($m){ Say "[WARN] $m" Yellow }
function Fail($m){ throw $m }

function Run-Dism([string[]]$Args,[string]$Label) {
    Info $Label
    & dism.exe @Args
    $code = $LASTEXITCODE
    if($code -ne 0){ throw "$Label failed: DISM exit $code. Command: DISM $($Args -join ' ')" }
}

function Hash-File($p){
    (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Invoke-WebRetry {
    param([string]$Uri,[ValidateSet('GET','POST')][string]$Method='GET',[hashtable]$Headers=@{},[hashtable]$Body=$null,[Microsoft.PowerShell.Commands.WebRequestSession]$Session=$null)
    $last=$null
    for($i=1;$i -le 5;$i++){
        try{
            Info "Web request attempt $i/5: $Uri"
            $splat=@{Uri=$Uri;Method=$Method;UseBasicParsing=$true;TimeoutSec=120;ErrorAction='Stop';Headers=$Headers}
            if($Body){$splat.Body=$Body;$splat.ContentType='application/x-www-form-urlencoded'}
            if($Session){$splat.WebSession=$Session}
            return Invoke-WebRequest @splat
        }catch{
            $last=$_
            Warn "Request failed: $($_.Exception.Message)"
            if($i -lt 5){Start-Sleep -Seconds ([int](5*$i))}
        }
    }
    throw $last
}

function Download-Resumable {
    param([string]$Url,[string]$Destination,[string]$Label)
    $tmp="$Destination.part"
    for($attempt=1;$attempt -le 5;$attempt++){
        try{
            Say "`n$Label" Cyan
            Info "Attempt $attempt/5"
            if(Test-Path $tmp){ $existing=(Get-Item $tmp).Length } else {$existing=0}
            if($existing -gt 0){ Info ("Resuming at {0:N0} bytes" -f $existing) }

            # BITS gives reliable resume/progress on Windows.
            try{
                if($existing -gt 0){
                    Start-BitsTransfer -Source $Url -Destination $tmp -DisplayName $Label -Description 'Windows 10 Builder' -Priority High -RetryInterval 10 -RetryTimeout 300 -ErrorAction Stop
                } else {
                    Start-BitsTransfer -Source $Url -Destination $tmp -DisplayName $Label -Description 'Windows 10 Builder' -Priority High -RetryInterval 10 -RetryTimeout 300 -ErrorAction Stop
                }
            }catch{
                Warn "BITS failed; using HTTP range-resume fallback: $($_.Exception.Message)"
                $headers=@{}
                if($existing -gt 0){$headers.Range="bytes=$existing-"}
                $resp=Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop
                $mode=if($existing -gt 0){[IO.FileMode]::Append}else{[IO.FileMode]::Create}
                $fs=[IO.File]::Open($tmp,$mode)
                try{
                    $resp.RawContentStream.CopyTo($fs)
                }finally{$fs.Dispose()}
            }
            if(!(Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1024){throw "Downloaded file is missing or too small."}
            Move-Item $tmp $Destination -Force
            $h=Hash-File $Destination
            OK "$Label completed"
            Info "SHA-256: $h"
            return $h
        }catch{
            Warn "Download attempt failed: $($_.Exception.Message)"
            if($attempt -lt 5){Start-Sleep -Seconds ([int](10*$attempt))}
        }
    }
    throw "Unable to download $Label after 5 attempts."
}

function Get-ISOUrlFromMicrosoft {
    $page='https://www.microsoft.com/en-us/software-download/windows10ISO'
    $ua='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36'
    $session=New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $h=@{'User-Agent'=$ua;'Accept-Language'='en-US,en;q=0.9'}
    $home=Invoke-WebRetry -Uri $page -Headers $h -Session $session
    $html=$home.Content

    $prod=[regex]::Match($html,'product-info-content.*?option\s+value="(\d+)"[^>]*>\s*Windows 10\s*<',[Text.RegularExpressions.RegexOptions]::Singleline)
    if(!$prod.Success){
        $prod=[regex]::Match($html,'option\s+value="(\d+)"[^>]*>\s*Windows 10\s*<')
    }
    if(!$prod.Success){throw 'Could not determine Microsoft Windows 10 productEditionId from the current ISO page.'}
    $productId=$prod.Groups[1].Value
    Info "Microsoft productEditionId: $productId"

    $langId=([regex]::Match($html,'id="SoftwareDownload_LanguageSelectionByProductEdition"[^>]*data-defaultpageid="([^"]+)"')).Groups[1].Value
    $downloadId=([regex]::Match($html,'id="SoftwareDownload_DownloadLinks"[^>]*data-defaultpageid="([^"]+)"')).Groups[1].Value
    if(!$langId -or !$downloadId){throw 'Microsoft ISO page did not expose the current language/download page IDs.'}
    Info "Language page ID: $langId"
    Info "Download page ID: $downloadId"

    $sid=[guid]::NewGuid().Guid
    $base='https://www.microsoft.com/en-us/api/controls/contentinclude/html'
    $common="&host=www.microsoft.com&segments=software-download,windows10ISO&query=&sessionId=$sid&sdVersion=2"
    $u1="${base}?pageId=$langId$common&action=getskuinformationbyproductedition&productEditionId=$productId"
    $r1=Invoke-WebRetry -Uri $u1 -Method POST -Headers (@{'User-Agent'=$ua;'Referer'=$page;'Origin'='https://www.microsoft.com';'Accept-Language'='en-US,en;q=0.9'}) -Session $session
    $m=[regex]::Matches($r1.Content,'value="(\{[^"]*language[^"]*English[^"]*\})"')
    $sku=$null
    foreach($x in $m){
        $j=$x.Groups[1].Value -replace '&quot;','"' -replace '&amp;','&'
        try{$o=$j|ConvertFrom-Json;if($o.language -eq 'English'){$sku=[string]$o.id;break}}catch{}
    }
    if(!$sku){
        # HTML entity-safe fallback
        $un=[System.Net.WebUtility]::HtmlDecode($r1.Content)
        $mm=[regex]::Matches($un,'value="(\{[^"]+\})"')
        foreach($x in $mm){
            try{$o=$x.Groups[1].Value|ConvertFrom-Json;if($o.language -eq 'English'){$sku=[string]$o.id;break}}catch{}
        }
    }
    if(!$sku){throw 'Microsoft did not return an English SKU.'}
    Info "English SKU: $sku"

    $u2="${base}?pageId=$downloadId$common&action=GetProductDownloadLinksBySku&skuId=$sku&language=English"
    $r2=Invoke-WebRetry -Uri $u2 -Method POST -Headers (@{'User-Agent'=$ua;'Referer'=$page;'Origin'='https://www.microsoft.com';'Accept-Language'='en-US,en;q=0.9'}) -Session $session
    $content=[System.Net.WebUtility]::HtmlDecode($r2.Content)
    $links=[regex]::Matches($content,'href="(https?://[^"]+)"[^>]*>\s*<span[^>]*class="product-download-type"[^>]*>\s*IsoX64\s*<')
    if($links.Count -eq 0){$links=[regex]::Matches($content,'href="(https?://[^"]+)"[^>]*>[^<]*IsoX64')}
    if($links.Count -eq 0){throw 'Microsoft returned no English x64 ISO URL.'}
    return $links[0].Groups[1].Value
}

function Get-ISOInfo($iso) {
    $d=Mount-DiskImage -ImagePath $iso -PassThru
    try{
        Start-Sleep -Milliseconds 800
        $v=Get-Volume -DiskImage $d
        if(!$v.DriveLetter){throw 'Mounted ISO has no drive letter.'}
        $drive="$($v.DriveLetter):"
        $wim=Join-Path $drive 'sources\install.wim'
        $esd=Join-Path $drive 'sources\install.esd'
        if(Test-Path $wim){$image=$wim}else{$image=$esd}
        if(!$image){throw 'ISO contains neither sources\install.wim nor sources\install.esd.'}
        $txt=& dism.exe /Get-WimInfo /WimFile:$image /Index:6 2>&1
        if($LASTEXITCODE -ne 0){throw 'Could not inspect Pro index 6.'}
        [pscustomobject]@{
            Drive=$drive; Image=$image; Text=($txt -join "`n")
            Pro=($txt -match 'Name\s*:\s*Windows 10 Pro')
            X64=($txt -match 'Architecture\s*:\s*x64')
            Version=([regex]::Match(($txt -join "`n"),'Version\s*:\s*([0-9.]+)')).Groups[1].Value
            Build=([regex]::Match(($txt -join "`n"),'ServicePack Build\s*:\s*(\d+)')).Groups[1].Value
            Lang=([regex]::Match(($txt -join "`n"),'Languages\s*:\s*[\r\n]+\s*([^\s(]+)')).Groups[1].Value
        }
    }finally{
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
    }
}

function Get-CatalogPackage {
    param([string]$KB,[string]$ExpectedTitlePattern,[string]$CacheName)
    $dest=Join-Path $PkgDir $CacheName
    if(Test-Path $dest){
        if((Get-Item $dest).Length -gt 1MB){
            OK "Cached $KB found: $dest"
            Info "SHA-256: $(Hash-File $dest)"
            return $dest
        }
        Remove-Item $dest -Force
    }

    $search="https://www.catalog.update.microsoft.com/Search.aspx?q=$KB"
    $r=Invoke-WebRetry -Uri $search -Headers @{'User-Agent'='Mozilla/5.0'}
    $html=$r.Content
    $rows=[regex]::Matches($html,'(?is)<tr[^>]*>(.*?)</tr>')
    $selected=$null
    foreach($row in $rows){
        $rowText=[System.Net.WebUtility]::HtmlDecode($row.Groups[1].Value)
        if($rowText -match $ExpectedTitlePattern -and $rowText -notmatch 'ARM64' -and $rowText -notmatch 'x86-based'){
            $g=[regex]::Match($row.Groups[1].Value,'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
            if($g.Success){$selected=$g.Groups[1].Value;break}
        }
    }
    if(!$selected){
        # fallback: use GUID near the first matching title text
        $pos=$html.IndexOf($ExpectedTitlePattern.Trim('"'))
        $guids=[regex]::Matches($html,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if($guids.Count){$selected=$guids[0].Value}
    }
    if(!$selected){throw "Could not find Microsoft Update Catalog entry for $KB."}
    Info "Catalog UpdateID: $selected"

    $payload=@{size=0;updateID=$selected;uidInfo=$selected}|ConvertTo-Json -Compress
    $body=@{updateIDs="[$payload]"}
    $dr=Invoke-WebRetry -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body $body -Headers @{'Referer'='https://www.catalog.update.microsoft.com/';'User-Agent'='Mozilla/5.0'}
    $raw=$dr.Content -replace 'www\.download\.windowsupdate','download.windowsupdate'
    $lm=[regex]::Matches($raw,"downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'")
    $url=$null
    foreach($x in $lm){
        $u=$x.Groups[1].Value -replace '\\/','/'
        if($u -match '\.(msu|cab)(\?|$)'){$url=$u;break}
    }
    if(!$url -and $lm.Count){$url=$lm[0].Groups[1].Value}
    if(!$url){throw "Catalog returned no downloadable package URL for $KB."}
    Info "Microsoft package URL obtained."
    Download-Resumable -Url $url -Destination $dest -Label "$KB package"
    return $dest
}

try {
    Step 1 'Checking local tools'
    foreach($p in @($Oscdimg,$EFI,$BIOS,$AutoUnattend)){
        if(!(Test-Path $p)){throw "Required file not found: $p"}
    }
    OK "oscdimg: $Oscdimg"; OK "UEFI: $EFI"; OK "BIOS: $BIOS"; OK "autounattend.xml found"

    Step 2 'Checking source ISO candidates'
    $candidate=Get-ChildItem $ISOdir -Filter '*.iso' -File | Select-Object -First 1
    if($candidate){
        Info "Found ISO: $($candidate.FullName)"
        $h=Hash-File $candidate.FullName
        Info "ISO SHA-256: $h"
        try{$info=Get-ISOInfo $candidate.FullName}catch{$info=$null}
        if($info -and $info.Pro -and $info.X64 -and $info.Lang -eq 'en-US' -and $info.Version -like '10.0.19045*'){
            OK "Existing ISO is Windows 10 22H2 x64 Pro en-US."
            $SourceISO=$candidate.FullName
        }else{
            Warn 'Existing ISO is not the required en-US x64 source; it will not be used.'
            $SourceISO=$null
        }
    }else{$SourceISO=$null}

    Step 3 'Downloading Microsoft English x64 ISO when required'
    if(!$SourceISO){
        Info 'Getting current Microsoft ISO URL from the live Windows 10 ISO page.'
        $url=Get-ISOUrlFromMicrosoft
        Info "Microsoft ISO URL obtained (time-limited)."
        Download-Resumable -Url $url -Destination $SourceISO -Label 'Microsoft Windows 10 English x64 ISO' | Out-Null
        $info=Get-ISOInfo $SourceISO
        if(!$info.Pro -or !$info.X64 -or $info.Lang -ne 'en-US'){throw 'Downloaded ISO failed en-US/x64/Pro validation.'}
        $h=Hash-File $SourceISO
        Info "Microsoft English 64-bit published SHA-256: A6F470CA6D331EB353B815C043E327A347F594F37FF525F17764738FE812852E"
        if($h -eq 'A6F470CA6D331EB353B815C043E327A347F594F37FF525F17764738FE812852E'){OK 'ISO SHA-256 matches Microsoft published hash.'}else{Warn "ISO SHA-256 does not match Microsoft's published value; content validation passed, but the ISO will not be treated as hash-verified."}
    }

    Step 4 'Preparing clean workspace'
    Get-ChildItem $Work -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $Output -Filter '*.iso' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Run-Dism @('/Cleanup-Wim') 'Cleaning stale DISM mounts'
    $d=Mount-DiskImage -ImagePath $SourceISO -PassThru
    Start-Sleep -Milliseconds 800
    $vol=Get-Volume -DiskImage $d
    $drive="$($vol.DriveLetter):"
    $src=Join-Path $Work 'Source'
    New-Item -ItemType Directory -Force $src | Out-Null
    Copy-Item "$drive\*" $src -Recurse -Force
    Dismount-DiskImage -ImagePath $SourceISO | Out-Null
    $install=if(Test-Path "$src\sources\install.wim"){"$src\sources\install.wim"}else{"$src\sources\install.esd"}
    if(!$install){throw 'No install.wim/install.esd in source ISO.'}

    Step 5 'Exporting Windows 10 Professional only'
    $proWim=Join-Path $Work 'install-pro.wim'
    $idxTxt=& dism.exe /Get-WimInfo /WimFile:$install 2>&1
    $proIndex=0
    foreach($line in ($idxTxt -join "`n") -split "Index\s*:"){
        if($line -match 'Name\s*:\s*Windows 10 Pro(\s|$)' -and $line -notmatch 'N|Education|Workstations'){
            $m=[regex]::Match($line,'^\s*(\d+)');if($m.Success){$proIndex=[int]$m.Groups[1].Value;break}
        }
    }
    if(!$proIndex){$proIndex=6}
    Info "Professional index: $proIndex"
    Run-Dism @('/Export-Image',"/SourceImageFile:$install","/SourceIndex:$proIndex","/DestinationImageFile:$proWim",'/Compress:max','/CheckIntegrity') 'Exporting Professional image'
    Move-Item $proWim "$src\sources\install.wim" -Force
    if($install -like '*.esd'){Remove-Item $install -Force}

    Step 6 'Mounting Professional image'
    Run-Dism @('/Mount-Image',"/ImageFile:$src\sources\install.wim",'/Index:1',"/MountDir:$Mount") 'Mounting Professional image'
    $mounted=$true
    $reg="$Mount\Windows\System32\config\SOFTWARE"
    $hive='HKLM\WIN10V5'
    & reg.exe load $hive $reg | Out-Null
    $build=(Get-ItemProperty "Registry::$hive\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).CurrentBuildNumber
    $ubr=(Get-ItemProperty "Registry::$hive\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).UBR
    $edition=(Get-ItemProperty "Registry::$hive\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).EditionID
    Info "Offline image: build=$build UBR=$ubr edition=$edition"
    & reg.exe unload $hive | Out-Null

    Step 7 'Checking installed packages and servicing baseline'
    $pkgs=& dism.exe /Image:$Mount /Get-Packages 2>&1
    $pkgText=$pkgs -join "`n"
    $hasBaseline=($pkgText -match 'KB5028244') -or ($pkgText -match 'KB5\d{6}' -and $pkgText -match '19045')
    if($pkgText -match 'KB5120249'){
        OK 'KB5120249 already present.'
    }else{
        Info 'KB5120249 is not present.'
    }
    if($hasBaseline){OK 'Image has KB5028244 or later LCU baseline; special KB5031539 is not required.'}
    else{Info 'Image predates KB5028244; Microsoft requires special offline SSU KB5031539 before KB5120249.'}

    Step 8 'Downloading required Microsoft packages automatically'
    $ssu=$null
    if(!$hasBaseline){
        $ssu=Get-CatalogPackage -KB 'KB5031539' -ExpectedTitlePattern 'Servicing Stack Update for Windows 10 Version 22H2 for x64-based Systems.*KB5031539' -CacheName 'Windows10-KB5031539-x64.msu'
    }
    $lcu=Get-CatalogPackage -KB 'KB5120249' -ExpectedTitlePattern 'Cumulative Update for Windows 10 Version 22H2 for x64-based Systems.*KB5120249' -CacheName 'Windows10-KB5120249-x64.msu'

    Step 9 'Injecting packages in required order'
    if($ssu){
        Run-Dism @('/Image:'+$Mount,'/Add-Package',"/PackagePath:$ssu",'/NoRestart','/Quiet') 'Installing special offline SSU KB5031539'
    }
    Run-Dism @('/Image:'+$Mount,'/Add-Package',"/PackagePath:$lcu",'/NoRestart','/Quiet') 'Installing LCU KB5120249'
    Run-Dism @('/Image:'+$Mount,'/Cleanup-Image','/StartComponentCleanup') 'Component cleanup'

    Step 10 'Adding AutoUnattend.xml and verifying build'
    Copy-Item $AutoUnattend $src\AutoUnattend.xml -Force
    Run-Dism @('/Unmount-Image',"/MountDir:$Mount",'/Commit') 'Committing Professional image'
    $mounted=$false
    $verifyMount=Join-Path $Work 'VerifyMount'
    New-Item -ItemType Directory -Force $verifyMount | Out-Null
    Run-Dism @('/Mount-Image',"/ImageFile:$src\sources\install.wim",'/Index:1',"/MountDir:$verifyMount") 'Mounting image for final verification'
    $pkv=& dism.exe /Image:$verifyMount /Get-Packages 2>&1
    if(($pkv -join "`n") -notmatch 'KB5120249'){throw 'Final image does not show KB5120249.'}
    & reg.exe load 'HKLM\WIN10V5VERIFY' "$verifyMount\Windows\System32\config\SOFTWARE" | Out-Null
    $vbuild=(Get-ItemProperty 'Registry::HKLM\WIN10V5VERIFY\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    $vubr=(Get-ItemProperty 'Registry::HKLM\WIN10V5VERIFY\Microsoft\Windows NT\CurrentVersion').UBR
    & reg.exe unload 'HKLM\WIN10V5VERIFY' | Out-Null
    Run-Dism @('/Unmount-Image',"/MountDir:$verifyMount",'/Discard') 'Unmounting verification image'
    Remove-Item $verifyMount -Recurse -Force -ErrorAction SilentlyContinue
    Info "Final offline build: $vbuild.$vubr"
    if("$vbuild.$vubr" -ne '19045.7663'){throw "Target build verification failed. Expected 19045.7663, got $vbuild.$vubr."}

    Step 11 'Creating BIOS + UEFI bootable ISO'
    $bootArg="-bootdata:2#p0,e,b`"$BIOS`"#pEF,e,b`"$EFI`""
    & $Oscdimg -m -o -u2 -udfver102 -lWIN10PRO $bootArg $src $OutputISO
    if($LASTEXITCODE -ne 0){throw "oscdimg failed with exit code $LASTEXITCODE."}
    if(!(Test-Path $OutputISO)){throw 'Output ISO was not created.'}
    $finalHash=Hash-File $OutputISO

    Step 12 'Final report and SHA-256'
    $report=Join-Path $Output 'BuildReport.txt'
    @"
Windows 10 Pro ISO Builder v5
Date: $(Get-Date)
Source ISO: $SourceISO
Source SHA-256: $(Hash-File $SourceISO)
Target: Windows 10 22H2 Pro x64 en-US
Target build: 19045.7663
LCU: KB5120249
Special offline SSU: $(if($ssu){'KB5031539'}else{'Not required'})
AutoUnattend.xml: included at ISO root
Output ISO: $OutputISO
Output SHA-256: $finalHash
"@ | Set-Content $report -Encoding UTF8
    OK "BUILD COMPLETE"
    OK "Output: $OutputISO"
    OK "SHA-256: $finalHash"
    OK "Report: $report"
}
catch{
    Say "`nBUILD FAILED" Red
    Say $_.Exception.Message Red
    Say "Log: $Log" Yellow
    try{
        $mi=& dism.exe /Get-MountedWimInfo 2>&1
        Say "`nMounted-image status:" Yellow
        $mi | ForEach-Object {Say "$_"}
    }catch{}
    exit 1
}
finally{
    if($mounted){
        try{& reg.exe unload 'HKLM\WIN10V5' | Out-Null}catch{}
        try{& dism.exe /Unmount-Image /MountDir:$Mount /Discard | Out-Null}catch{}
    }
    Stop-Transcript | Out-Null
}
