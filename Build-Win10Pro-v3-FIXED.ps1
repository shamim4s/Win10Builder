#requires -Version 5.1
<#
 Win10Builder v3
 - Microsoft-hosted Windows 10 English x64 ISO auto-download
 - Microsoft Update Catalog auto-discovery for MSU/SSU
 - resumable downloads via curl.exe
 - SHA-256 for ISO and every cached package
 - Professional-only install.wim
 - Offline servicing to 19045.7663
 - BIOS + UEFI bootable ISO
 - autounattend.xml at ISO root
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Win10Builder' }
$ISOFolder="$Root\ISO"; $PackageFolder="$Root\Packages"; $WorkFolder="$Root\Work"
$MountFolder="$Root\Mount"; $OutputFolder="$Root\Output"; $LogFolder="$Root\Logs"
$AutoUnattend="$Root\autounattend.xml"
$OutputISO="$OutputFolder\Win10_22H2_Pro_19045.7663_English_x64.iso"

$Oscdimg="$Root\Tools\Oscdimg\oscdimg.exe"
$EfiSys="$Root\Tools\Oscdimg\efisys.bin"
$EtfsBoot="$Root\Tools\Oscdimg\etfsboot.com"

$TargetBuild=19045
$TargetUBR=7663
$TargetKB='KB5120249'
$SpecialSSU='KB5031539'
$MinimumLCU='KB5028244'
$ExpectedEnglishX64ISOHash='A6F470CA6D331EB353B815C043E327A347F594F37FF525F17764738FE812852E'

$MicrosoftISOPage='https://www.microsoft.com/en-us/software-download/windows10ISO'
$Catalog='https://www.catalog.update.microsoft.com'
$UserAgent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/139 Safari/537.36'

function Step($s){Write-Host "`n================================================================`n$s`n================================================================" -ForegroundColor DarkCyan}
function Info($s){Write-Host "[INFO] $s" -ForegroundColor Cyan}
function OK($s){Write-Host "[OK] $s" -ForegroundColor Green}
function Warn($s){Write-Host "[WARN] $s" -ForegroundColor Yellow}
function Fail($s){throw $s}
function Req($p,$d){if(!(Test-Path -LiteralPath $p -PathType Leaf)){Fail "$d not found: $p"}}
function SHA256($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpperInvariant()}
function Native($exe,[string[]]$args,$name){
  Info "$name..."
  & $exe @args
  if($LASTEXITCODE -ne 0){Fail "$name failed with exit code $LASTEXITCODE"}
}
function EnsureDir($p){if(!(Test-Path $p)){New-Item -ItemType Directory -Path $p -Force|Out-Null}}

function Download-Resumable {
  param([string]$Url,[string]$OutFile,[int]$Retries=5)
  if(-not (Get-Command curl.exe -ErrorAction SilentlyContinue)){Fail 'curl.exe is required. It is included with current Windows 10/11.'}
  $part="$OutFile.part"
  for($try=1;$try -le $Retries;$try++){
    Write-Host ""
    Info "Download attempt $try/$Retries"
    & curl.exe -L --fail --retry 0 --connect-timeout 30 --max-time 0 -C - --progress-bar -A $UserAgent -o $part $Url
    if($LASTEXITCODE -eq 0){
      Move-Item $part $OutFile -Force
      return
    }
    Warn "Download interrupted/failed (curl exit $LASTEXITCODE). Retrying..."
    Start-Sleep -Seconds ([Math]::Min(30,5*$try))
  }
  Fail "Unable to download after $Retries attempts: $Url"
}

function Get-MicrosoftISOUrl {
  Step 'Getting a fresh Microsoft ISO download URL'
  $session=New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $headers=@{'User-Agent'=$UserAgent;'Accept-Language'='en-US,en;q=0.9'}
  $page=Invoke-WebRequest -Uri $MicrosoftISOPage -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 120
  $raw=$page.Content

  $prodMatch=[regex]::Match($raw,'product-info-content.*?option value="(?<id>\d+)".*?>Windows 10</option>','Singleline,IgnoreCase')
  if(-not $prodMatch.Success){$prodMatch=[regex]::Match($raw,'productEditionId[=:]"?(?<id>\d+)','IgnoreCase')}
  if(-not $prodMatch.Success){$prodId='1429'}else{$prodId=$prodMatch.Groups['id'].Value}
  Info "Microsoft productEditionId: $prodId"

  $sid=[guid]::NewGuid().ToString()
  $p1='a8f8f489-4c7f-463a-9ca6-5cff94d8d041'
  $p2='cfa9e580-a81e-4a4b-a846-7b21bf4e2e5b'
  $base='https://www.microsoft.com/en-us/api/controls/contentinclude/html'
  $u1="${base}?pageId=$p1&host=www.microsoft.com&segments=software-download,windows10ISO&query=&action=getskuinformationbyproductedition&sessionId=$sid&productEditionId=$prodId&sdvParam=2"
  $skuResp=Invoke-WebRequest -Uri $u1 -Method Get -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 120
  $skuId=$null

  $skuMatches=[regex]::Matches($skuResp.Content,'<option[^>]+value="(?<v>\{&quot;id&quot;:&quot;(?<id>\d+).*?\})"[^>]*>\s*English\s*</option>','IgnoreCase')
  if($skuMatches.Count){$skuId=$skuMatches[0].Groups['id'].Value}
  if(-not $skuId){
    $fallback=[regex]::Match($skuResp.Content,'id[":]+(?<id>\d+).*?English','IgnoreCase,Singleline')
    if($fallback.Success){$skuId=$fallback.Groups['id'].Value}
  }
  if(-not $skuId){Fail 'Microsoft did not return an English Windows 10 SKU. Microsoft may have changed its download API or blocked the request.'}
  Info "English SKU: $skuId"

  $u2="${base}?pageId=$p2&host=www.microsoft.com&segments=software-download,windows10ISO&query=&action=GetProductDownloadLinksBySku&sessionId=$sid&skuId=$skuId&language=English&sdvParam=2"
  $linkHeaders=@{'User-Agent'=$UserAgent;'Referer'=$MicrosoftISOPage;'Accept-Language'='en-US'}
  $linkResp=Invoke-WebRequest -Uri $u2 -Method Get -WebSession $session -Headers $linkHeaders -UseBasicParsing -TimeoutSec 120
  $links=[regex]::Matches($linkResp.Content,'href="(?<url>https?://[^"]+)"[^>]*>\s*<span[^>]*class="product-download-type">\s*IsoX64\s*</span>','IgnoreCase')
  if($links.Count -eq 0){$links=[regex]::Matches($linkResp.Content,'https?://[^"\s<]+\.iso[^"\s<]*','IgnoreCase')}
  if($links.Count -eq 0){Fail 'Microsoft returned no x64 ISO download URL. A fresh Microsoft browser session may be required if Sentinel blocks the API.'}
  return $links[0].Groups['url'].Value.Replace('&amp;','&')
}

function Ensure-SourceISO {
  Step '3/12 - Checking/downloading source ISO'
  $existing=@(Get-ChildItem $ISOFolder -Filter '*.iso' -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending)
  $iso=$null

  if($existing.Count -gt 0){
    $candidate=$existing[0].FullName
    Info "Found existing ISO: $candidate"
    $candidateHash=SHA256 $candidate
    Info "Existing ISO SHA-256: $candidateHash"
    if($candidateHash -eq $ExpectedEnglishX64ISOHash){
      OK 'Existing ISO matches Microsoft published English x64 SHA-256.'
      return $candidate
    }
    Warn 'Existing ISO is not the current Microsoft English x64 ISO hash. A fresh Microsoft ISO will be downloaded.'
    Rename-Item $candidate ($candidate + ".old") -Force
  }

  $url=Get-MicrosoftISOUrl
  $iso="$ISOFolder\Win10_English_x64.iso"
  Info 'Microsoft ISO URL acquired. The URL is time-limited.'
  Download-Resumable -Url $url -OutFile $iso
  $hash=SHA256 $iso
  Info "Downloaded ISO SHA-256: $hash"
  if($hash -ne $ExpectedEnglishX64ISOHash){
    Fail "Downloaded ISO SHA-256 mismatch. Expected $ExpectedEnglishX64ISOHash but received $hash."
  }
  OK 'Downloaded ISO SHA-256 matches Microsoft published value.'
  return $iso
}

function Get-CatalogUpdateUrl {
  param([string]$KB)
  $searchUrl="$Catalog/Search.aspx?q=$KB"
  $search=Invoke-WebRequest -Uri $searchUrl -Headers @{'User-Agent'=$UserAgent} -UseBasicParsing -TimeoutSec 120
  $ids=[regex]::Matches($search.Content,'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}','IgnoreCase') |
        ForEach-Object {$_.Value} | Select-Object -Unique
  if(!$ids){Fail "No Microsoft Update Catalog result found for $KB"}

  foreach($id in $ids){
    $post=@{size=0;updateID=$id;uidInfo=$id}|ConvertTo-Json -Compress
    $body=@{updateIDs="[$post]"}
    $dialog=Invoke-WebRequest -Uri "$Catalog/DownloadDialog.aspx" -Method Post -Body $body `
      -ContentType 'application/x-www-form-urlencoded' `
      -Headers @{'User-Agent'=$UserAgent;'Referer'=$searchUrl} -UseBasicParsing -TimeoutSec 120
    $urls=[regex]::Matches($dialog.Content,'https?://(?:catalog\.s\.)?download\.windowsupdate\.com/[^''"\s<]+','IgnoreCase') |
           ForEach-Object {$_.Value.Replace('&amp;','&')} | Select-Object -Unique
    foreach($u in $urls){
      $lower=$u.ToLowerInvariant()
      if($lower -match '\.msu(\?|$)' -and $lower -match 'x64'){return $u}
      if($lower -match '\.cab(\?|$)' -and $lower -match 'x64'){return $u}
    }
  }
  Fail "Could not find a Microsoft x64 MSU/CAB download URL for $KB."
}

function Ensure-Package {
  param([string]$KB)
  $cached=@(Get-ChildItem $PackageFolder -File -ErrorAction SilentlyContinue |
    Where-Object {$_.Name -match "(?i)$KB" -and $_.Extension -in '.msu','.cab'})
  if($cached.Count -gt 0){
    $p=$cached[0]
    OK "$KB already cached: $($p.Name)"
    Info "SHA-256: $(SHA256 $p.FullName)"
    return $p.FullName
  }

  Step "Downloading $KB automatically from Microsoft Update Catalog"
  $url=Get-CatalogUpdateUrl -KB $KB
  $name=[IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
  if([string]::IsNullOrWhiteSpace($name)){$name="$KB-x64.msu"}
  $out="$PackageFolder\$name"
  Download-Resumable -Url $url -OutFile $out
  $hash=SHA256 $out
  OK "$KB downloaded and cached."
  Info "SHA-256: $hash"
  return $out
}

function ProIndex($w){
  $o=& dism.exe /Get-WimInfo /WimFile:$w 2>&1
  $i=$null
  foreach($l in $o){
    if("$l" -match '^\s*Index\s*:\s*(\d+)\s*$'){$i=[int]$Matches[1]}
    elseif("$l" -match '^\s*Name\s*:\s*Windows 10 Pro\s*$'){return $i}
  }
  return $null
}
function OfflineBuild($m){
  $h="$m\Windows\System32\Config\SOFTWARE";Req $h 'Offline SOFTWARE hive'
  $n="W10B_$PID"
  & reg.exe load "HKLM\$n" $h|Out-Null
  if($LASTEXITCODE-ne 0){Fail 'Cannot load offline SOFTWARE hive'}
  try{
    $p=Get-ItemProperty "HKLM:\$n\Microsoft\Windows NT\CurrentVersion"
    [pscustomobject]@{Build=[int]$p.CurrentBuild;UBR=[int]$p.UBR;EditionID="$($p.EditionID)";ProductName="$($p.ProductName)"}
  }finally{& reg.exe unload "HKLM\$n"|Out-Null}
}
function InstalledPackages($m){(& dism.exe /Image:$m /Get-Packages 2>&1|Out-String)}
function NativeDISM($args,$name){Native 'dism.exe' $args $name}

foreach($d in @($ISOFolder,$PackageFolder,$WorkFolder,$MountFolder,$OutputFolder,$LogFolder)){EnsureDir $d}
$log="$LogFolder\Build-v3-$(Get-Date -Format yyyyMMdd-HHmmss).log"
Start-Transcript $log -Force|Out-Null

try{
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $pr=[Security.Principal.WindowsPrincipal]::new($id)
  if(!$pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
  }

  Write-Host 'Running as Administrator.' -ForegroundColor Green

  Step '1/12 - Checking local tools'
  Req $Oscdimg 'oscdimg.exe';Req $EfiSys 'efisys.bin';Req $EtfsBoot 'etfsboot.com'
  Req "$env:SystemRoot\System32\dism.exe" 'Windows DISM'
  OK "oscdimg: $Oscdimg";OK "UEFI: $EfiSys";OK "BIOS: $EtfsBoot"

  Step '2/12 - Checking autounattend.xml'
  Req $AutoUnattend 'autounattend.xml';OK 'autounattend.xml found'

  $SourceISO=Ensure-SourceISO

  Step '5/12 - Extracting ISO'
  $Source="$WorkFolder\Source"
  Remove-Item $Source -Recurse -Force -ErrorAction SilentlyContinue
  EnsureDir $Source
  $disk=Mount-DiskImage $SourceISO -PassThru
  Start-Sleep 2
  try{
    $vol=$disk|Get-Volume
    $drive="$($vol.DriveLetter):"
    Info "Mounted source ISO at $drive"
    & robocopy "$drive\" $Source /E /R:2 /W:1 /NFL /NDL /NJH /NJS|Out-Null
    if($LASTEXITCODE -gt 7){Fail "ISO extraction failed: robocopy exit $LASTEXITCODE"}
  }finally{Dismount-DiskImage $SourceISO -ErrorAction SilentlyContinue}
  Copy-Item $AutoUnattend "$Source\autounattend.xml" -Force

  $Wim="$Source\sources\install.wim"
  $Esd="$Source\sources\install.esd"
  if(!(Test-Path $Wim) -and (Test-Path $Esd)){
    NativeDISM @('/Export-Image',"/SourceImageFile:$Esd",'/SourceIndex:1',"/DestinationImageFile:$WorkFolder\converted.wim",'/Compress:max','/CheckIntegrity') 'Converting ESD to WIM'
    Move-Item "$WorkFolder\converted.wim" $Wim -Force
    Remove-Item $Esd -Force
  }
  Req $Wim 'install.wim'

  Step '6/12 - Extracting Professional only'
  $idx=ProIndex $Wim
  if(!$idx){Fail 'Windows 10 Pro was not found in install.wim'}
  OK "Professional index: $idx"
  NativeDISM @('/Export-Image',"/SourceImageFile:$Wim","/SourceIndex:$idx","/DestinationImageFile:$WorkFolder\pro.wim",'/Compress:max','/CheckIntegrity') 'Professional export'
  Move-Item "$WorkFolder\pro.wim" $Wim -Force
  @"
[EditionID]
Professional
[Channel]
Retail
[VL]
0
"@|Set-Content "$Source\sources\ei.cfg" -Encoding ASCII

  Step '7/12 - Mounting Professional image'
  Remove-Item $MountFolder -Recurse -Force -ErrorAction SilentlyContinue
  EnsureDir $MountFolder
  NativeDISM @('/Mount-Image',"/ImageFile:$Wim",'/Index:1',"/MountDir:$MountFolder") 'Mounting image'
  $before=OfflineBuild $MountFolder
  Info "Edition: $($before.EditionID)"
  Info "Build: $($before.Build).$($before.UBR)"
  if($before.EditionID -ne 'Professional' -and $before.ProductName -notmatch 'Windows 10 Pro'){Fail 'Mounted image is not Professional'}

  Step '8/12 - Determining required servicing path'
  $installed=InstalledPackages $MountFolder
  $hasMinimum=$installed -match [regex]::Escape($MinimumLCU)
  if($hasMinimum){OK "Image already contains $MinimumLCU or later baseline."}
  else{Info "Image is older than $MinimumLCU. Microsoft requires special $SpecialSSU for offline servicing."}

  $ssuPath=$null
  if(!$hasMinimum){$ssuPath=Ensure-Package $SpecialSSU}

  Step '9/12 - Downloading current LCU automatically'
  $lcuPath=Ensure-Package $TargetKB

  Step '10/12 - Applying servicing packages'
  if($ssuPath){
    NativeDISM @("/Image:$MountFolder",'/Add-Package',"/PackagePath:$ssuPath",'/NoRestart') "Installing $SpecialSSU"
  }
  $installed2=InstalledPackages $MountFolder
  if($installed2 -match [regex]::Escape($TargetKB)){OK "$TargetKB already installed"}
  else{NativeDISM @("/Image:$MountFolder",'/Add-Package',"/PackagePath:$lcuPath",'/NoRestart') "Installing $TargetKB"}

  Step '11/12 - Validating final build'
  $after=OfflineBuild $MountFolder
  Info "Final edition: $($after.EditionID)"
  Info "Final build: $($after.Build).$($after.UBR)"
  if($after.Build -ne $TargetBuild -or $after.UBR -ne $TargetUBR){
    & dism.exe /Unmount-Image /MountDir:$MountFolder /Discard|Out-Null
    Fail "Expected $TargetBuild.$TargetUBR but got $($after.Build).$($after.UBR)."
  }
  OK 'Windows 10 Professional 19045.7663 verified.'
  Copy-Item $AutoUnattend "$Source\autounattend.xml" -Force

  Step '12/12 - Creating bootable BIOS + UEFI ISO'
  NativeDISM @('/Unmount-Image',"/MountDir:$MountFolder",'/Commit') 'Committing image'
  Remove-Item $OutputISO -Force -ErrorAction SilentlyContinue
  $boot="-bootdata:2#p0,e,b$EtfsBoot#pEF,e,b$EfiSys"
  Native $Oscdimg @('-m','-o','-u2','-udfver102','-lWIN10PRO',$boot,$Source,$OutputISO) 'Creating bootable ISO'
  $finalHash=SHA256 $OutputISO
  $size=[math]::Round((Get-Item $OutputISO).Length/1GB,2)

  $report="$OutputFolder\BuildReport.txt"
  @"
WINDOWS 10 PRO BUILDER v3 REPORT
================================
Build time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Target: Windows 10 22H2 Professional x64 English
Target build: 19045.7663
Target LCU: $TargetKB
Special SSU if required: $SpecialSSU
Source ISO: $SourceISO
Source ISO SHA-256: $(SHA256 $SourceISO)
LCU package: $(Split-Path $lcuPath -Leaf)
LCU package SHA-256: $(SHA256 $lcuPath)
SSU package: $(if($ssuPath){Split-Path $ssuPath -Leaf}else{'Not required'})
SSU SHA-256: $(if($ssuPath){SHA256 $ssuPath}else{'N/A'})
Final edition: $($after.EditionID)
Final build: $($after.Build).$($after.UBR)
Professional only: YES
autounattend.xml at ISO root: YES
BIOS boot: YES
UEFI boot: YES
ISO size GB: $size
FINAL ISO SHA-256: $finalHash
"@|Set-Content $report -Encoding UTF8

  Write-Host "`nBUILD COMPLETE" -ForegroundColor Green
  Write-Host "ISO: $OutputISO" -ForegroundColor Green
  Write-Host "SHA-256: $finalHash" -ForegroundColor Green
  Write-Host "REPORT: $report" -ForegroundColor Green
  Read-Host 'Press ENTER to close'
}
catch{
  Write-Host "`nBUILD FAILED" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host "Log: $log" -ForegroundColor Yellow
  Read-Host 'Press ENTER to close'
  exit 1
}
finally{try{Stop-Transcript|Out-Null}catch{}}
