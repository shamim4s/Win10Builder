#requires -Version 5.1
<#
 Windows 10 Pro ISO Builder v4
 - Validates an existing ISO BEFORE downloading anything.
 - Uses Microsoft's current Windows10ISO page to discover its current API page IDs.
 - Downloads the official Microsoft English x64 ISO only when the existing ISO is unsuitable.
 - Resumable/retry download with curl.exe.
 - Microsoft Update Catalog package discovery + caching.
 - Offline servicing to Windows 10 22H2 build 19045.7663.
 - Professional-only install.wim.
 - autounattend.xml at ISO root.
 - BIOS + UEFI bootable ISO.
#>

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=$PSScriptRoot
$ISOFolder="$Root\ISO"; $PackageFolder="$Root\Packages"; $WorkFolder="$Root\Work"
$MountFolder="$Root\Mount"; $OutputFolder="$Root\Output"; $LogFolder="$Root\Logs"
$AutoUnattend="$Root\autounattend.xml"
$OutputISO="$OutputFolder\Win10_22H2_Pro_19045.7663_English_x64.iso"
$Oscdimg="$Root\Tools\Oscdimg\oscdimg.exe"
$EfiSys="$Root\Tools\Oscdimg\efisys.bin"
$EtfsBoot="$Root\Tools\Oscdimg\etfsboot.com"

$MicrosoftISOPage='https://www.microsoft.com/en-us/software-download/windows10ISO'
$Catalog='https://www.catalog.update.microsoft.com'
$TargetBuild=19045;$TargetUBR=7663;$TargetKB='KB5120249'
$SSUKB='KB5081263'
$ExpectedOfficialISOHash='A6F470CA6D331EB353B815C043E327A347F594F37FF525F17764738FE812852E'
$UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/139 Safari/537.36'

function Step($s){Write-Host "`n================================================================`n$s`n================================================================" -ForegroundColor DarkCyan}
function Info($s){Write-Host "[INFO] $s" -ForegroundColor Cyan}
function OK($s){Write-Host "[OK] $s" -ForegroundColor Green}
function Warn($s){Write-Host "[WARN] $s" -ForegroundColor Yellow}
function Fail($s){throw $s}
function Req($p,$d){if(!(Test-Path -LiteralPath $p -PathType Leaf)){Fail "$d not found: $p"}}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpperInvariant()}
function EnsureDir($p){if(!(Test-Path $p)){New-Item -ItemType Directory -Path $p -Force|Out-Null}}

function Download-Resume {
 param([string]$Url,[string]$OutFile,[int]$Retries=5)
 Req (Join-Path $env:SystemRoot 'System32\curl.exe') 'curl.exe'
 $part="$OutFile.part"
 for($i=1;$i-le $Retries;$i++){
  Info "Download attempt $i/$Retries"
  & curl.exe -L --fail --retry 2 --retry-delay 3 --connect-timeout 30 --max-time 0 -C - -A $UA --progress-bar -o $part $Url
  if($LASTEXITCODE -eq 0){Move-Item $part $OutFile -Force;return}
  Warn "Download interrupted (curl exit $LASTEXITCODE). Retrying..."
  Start-Sleep ([Math]::Min(30,5*$i))
 }
 Fail "Download failed after $Retries attempts."
}

function Get-Windows10ISOUrl {
 Step 'Getting current Microsoft Windows 10 ISO link'
 $session=New-Object Microsoft.PowerShell.Commands.WebRequestSession
 $headers=@{'User-Agent'=$UA;'Accept-Language'='en-US,en;q=0.9'}
 $page=Invoke-WebRequest -Uri $MicrosoftISOPage -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 120
 $html=$page.Content

 # Microsoft embeds the current API page IDs in the page. Do NOT hard-code old IDs.
 $langId=[regex]::Match($html,'id="SoftwareDownload_LanguageSelectionByProductEdition"[^>]+data-defaultpageid="(?<id>[0-9a-f-]{36})"','IgnoreCase').Groups['id'].Value
 $linkId=[regex]::Match($html,'id="SoftwareDownload_DownloadLinks"[^>]+data-defaultpageid="(?<id>[0-9a-f-]{36})"','IgnoreCase').Groups['id'].Value
 if(!$langId -or !$linkId){Fail 'Microsoft Windows10ISO page did not expose its current API page IDs.'}
 Info "Microsoft language API page: $langId"
 Info "Microsoft download-link API page: $linkId"

 $sid=[guid]::NewGuid().ToString()
 $u1="${([Uri]$MicrosoftISOPage).Scheme}://www.microsoft.com/en-us/api/controls/contentinclude/html?pageId=$langId&host=www.microsoft.com&segments=software-download,windows10ISO&query=&action=getskuinformationbyproductedition&sessionId=$sid&productEditionId=1429&sdVersion=2"
 $r1=Invoke-WebRequest -Uri $u1 -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 120
 $english=$null
 foreach($m in [regex]::Matches($r1.Content,'<option[^>]+value="(?<v>\{[^"]+\})"[^>]*>\s*English\s*</option>','IgnoreCase')){
  $j=$m.Groups['v'].Value.Replace('&quot;','"').Replace('&amp;','&')
  try{$o=$j|ConvertFrom-Json;if($o.language -eq 'English'){$english=[string]$o.id;break}}catch{}
 }
 if(!$english){
  $m=[regex]::Match($r1.Content,'value="(?<v>\{&quot;id&quot;:&quot;(?<id>\d+)&quot;[^"]*language&quot;:&quot;English&quot;[^"]*\})"','IgnoreCase')
  if($m.Success){$english=$m.Groups['id'].Value}
 }
 if(!$english){Fail 'Microsoft did not return the English Windows 10 SKU.'}
 Info "English SKU: $english"

 $u2="https://www.microsoft.com/en-us/api/controls/contentinclude/html?pageId=$linkId&host=www.microsoft.com&segments=software-download,windows10ISO&query=&action=GetProductDownloadLinksBySku&sessionId=$sid&skuId=$english&language=English&sdVersion=2"
 $h2=@{'User-Agent'=$UA;'Referer'=$MicrosoftISOPage;'Accept-Language'='en-US,en;q=0.9'}
 $r2=Invoke-WebRequest -Uri $u2 -WebSession $session -Headers $h2 -UseBasicParsing -TimeoutSec 120
 $urls=[regex]::Matches($r2.Content,'href="(?<u>https?://[^"]+)"[^>]*>\s*<span[^>]*class="product-download-type">\s*IsoX64\s*</span>','IgnoreCase')
 if(!$urls.Count){$urls=[regex]::Matches($r2.Content,'https?://[^"\s<]+\.iso[^"\s<]*','IgnoreCase')}
 if(!$urls.Count){Fail 'Microsoft returned no x64 ISO URL. Microsoft may be temporarily rate-limiting the request; wait and retry.'}
 $u=$urls[0].Groups['u'].Value.Replace('&amp;','&')
 if(!$u){$u=$urls[0].Value}
 return $u
}

function Get-WimInfoText($wim){(& dism.exe /Get-WimInfo /WimFile:$wim 2>&1|Out-String)}
function FindProIndex($wim){
 $t=Get-WimInfoText $wim;$idx=$null
 foreach($line in ($t -split "`r?`n")){
  if($line -match '^\s*Index\s*:\s*(\d+)'){ $idx=[int]$Matches[1] }
  if($line -match '^\s*Name\s*:\s*Windows 10 Pro\s*$'){return $idx}
 }
 return $null
}
function Validate-ISO($iso){
 Step '3/12 - Validating existing ISO before any download'
 Req $iso 'ISO'
 Info "ISO: $iso"
 $h=Hash $iso
 Info "ISO SHA-256: $h"
 if($h -eq $ExpectedOfficialISOHash){OK 'ISO matches Microsoft published English 64-bit SHA-256.'}
 else{Warn 'ISO hash differs from Microsoft current published English x64 hash; content will be inspected.'}

 $disk=Mount-DiskImage -ImagePath $iso -PassThru
 try{
  Start-Sleep 2
  $vol=$disk|Get-Volume
  $drive="$($vol.DriveLetter):"
  $wim="$drive\sources\install.wim";$esd="$drive\sources\install.esd"
  if(!(Test-Path $wim) -and !(Test-Path $esd)){return $null}
  $file=if(Test-Path $wim){$wim}else{$esd}
  $info=Get-WimInfoText $file
  if($info -notmatch 'Architecture\s*:\s*x64'){Warn 'Source image is not x64.';return $null}
  if($info -notmatch 'Version\s*:\s*10\.0\.19045'){Warn 'Source image is not Windows 10 22H2 (19045).';return $null}
  if($info -notmatch '(?i)en-US|English'){Warn 'Source image does not report English/en-US.';return $null}
  $pro=FindProIndex $file
  if(!$pro){Warn 'Windows 10 Pro is not present.';return $null}
  OK "Valid Windows 10 22H2 x64 English source with Pro (index $pro)."
  return [pscustomobject]@{Path=$iso;ProIndex=$pro;Hash=$h}
 }finally{Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue}
}
function Ensure-SourceISO {
 $isos=@(Get-ChildItem $ISOFolder -Filter '*.iso' -File -ErrorAction SilentlyContinue|Sort-Object Length -Descending)
 foreach($iso in $isos){
  try{$v=Validate-ISO $iso.FullName;if($v){return $v}}catch{Warn "Could not validate $($iso.Name): $($_.Exception.Message)"}
 }
 Step 'No suitable existing ISO found'
 Info 'Obtaining a fresh official Microsoft English x64 ISO.'
 $url=Get-Windows10ISOUrl
 $out="$ISOFolder\Win10_22H2_English_x64_Microsoft.iso"
 Download-Resume $url $out
 $h=Hash $out
 Info "Downloaded ISO SHA-256: $h"
 if($h -ne $ExpectedOfficialISOHash){Fail "Microsoft ISO hash mismatch. Expected $ExpectedOfficialISOHash but received $h."}
 OK 'Fresh ISO verified against Microsoft published SHA-256.'
 $v=Validate-ISO $out
 if(!$v){Fail 'Fresh Microsoft ISO failed content validation.'}
 return $v
}

function CatalogUrl($KB){
 $s=Invoke-WebRequest -Uri "$Catalog/Search.aspx?q=$KB" -Headers @{'User-Agent'=$UA} -UseBasicParsing -TimeoutSec 120
 $ids=[regex]::Matches($s.Content,'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}','IgnoreCase')|% Value|Select-Object -Unique
 foreach($id in $ids){
  $body="updateIDs=[{`"size`":0,`"updateID`":`"$id`",`"uidInfo`":`"$id`"}]"
  try{$d=Invoke-WebRequest -Uri "$Catalog/DownloadDialog.aspx" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -Headers @{'User-Agent'=$UA;'Referer'="$Catalog/Search.aspx?q=$KB"} -UseBasicParsing -TimeoutSec 120}catch{continue}
  $urls=[regex]::Matches($d.Content,'https?://[^''"\s<]+','IgnoreCase')|% Value|% {$_ -replace '&amp;','&'}|Select-Object -Unique
  foreach($u in $urls){if($u -match '(?i)\.(msu|cab)(\?|$)' -and $u -match '(?i)x64'){return $u}}
 }
 Fail "No x64 Microsoft Update Catalog download URL found for $KB."
}
function Ensure-Package($KB){
 $c=@(Get-ChildItem $PackageFolder -File -ErrorAction SilentlyContinue|?{$_.Name -match "(?i)$KB" -and $_.Extension -in '.msu','.cab'})
 if($c.Count){OK "$KB cached: $($c[0].Name)";return $c[0].FullName}
 Step "Downloading $KB from Microsoft Update Catalog"
 $u=CatalogUrl $KB;$name=[IO.Path]::GetFileName(([Uri]$u).AbsolutePath);if(!$name){$name="$KB-x64.msu"}
 $out="$PackageFolder\$name";Download-Resume $u $out
 OK "$KB cached";Info "SHA-256: $(Hash $out)";return $out
}
function OfflineBuild($m){
 $h="$m\Windows\System32\Config\SOFTWARE";$n="W10V4_$PID"
 & reg.exe load "HKLM\$n" $h|Out-Null;if($LASTEXITCODE-ne 0){Fail 'Cannot load offline SOFTWARE hive'}
 try{$p=Get-ItemProperty "HKLM:\$n\Microsoft\Windows NT\CurrentVersion";return [pscustomobject]@{Build=[int]$p.CurrentBuild;UBR=[int]$p.UBR;Edition="$($p.EditionID)";Product="$($p.ProductName)"}}finally{& reg.exe unload "HKLM\$n"|Out-Null}
}
function Dism($a,$name){Info "$name...";& dism.exe @a;if($LASTEXITCODE-ne 0){Fail "$name failed: DISM exit $LASTEXITCODE"}}

foreach($d in @($ISOFolder,$PackageFolder,$WorkFolder,$MountFolder,$OutputFolder,$LogFolder)){EnsureDir $d}
$log="$LogFolder\Build-v4-$(Get-Date -Format yyyyMMdd-HHmmss).log";Start-Transcript $log -Force|Out-Null
try{
 $id=[Security.Principal.WindowsIdentity]::GetCurrent();$pr=[Security.Principal.WindowsPrincipal]::new($id)
 if(!$pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"";exit}
 Write-Host 'Running as Administrator.' -ForegroundColor Green

 Step '1/12 - Checking local tools';Req $Oscdimg 'oscdimg.exe';Req $EfiSys 'efisys.bin';Req $EtfsBoot 'etfsboot.com';Req "$env:SystemRoot\System32\dism.exe" 'DISM'
 OK "oscdimg: $Oscdimg";OK "UEFI: $EfiSys";OK "BIOS: $EtfsBoot"
 Step '2/12 - Checking autounattend.xml';Req $AutoUnattend 'autounattend.xml';OK 'autounattend.xml found'
 $source=Ensure-SourceISO

 Step '4/12 - Preparing clean workspace'
 if((dism /Get-MountedWimInfo 2>&1|Out-String)-match [regex]::Escape($MountFolder)){Fail "A WIM is still mounted at $MountFolder. Unmount it before starting."}
 Remove-Item "$WorkFolder\Source" -Recurse -Force -ErrorAction SilentlyContinue
 EnsureDir "$WorkFolder\Source";EnsureDir $MountFolder
 $disk=Mount-DiskImage $source.Path -PassThru;Start-Sleep 2
 try{$vol=$disk|Get-Volume;$drive="$($vol.DriveLetter):";& robocopy "$drive\" "$WorkFolder\Source" /E /R:2 /W:1 /NFL /NDL /NJH /NJS|Out-Null;if($LASTEXITCODE-gt 7){Fail "ISO copy failed: robocopy $LASTEXITCODE"}}finally{Dismount-DiskImage $source.Path -ErrorAction SilentlyContinue}
 Copy-Item $AutoUnattend "$WorkFolder\Source\autounattend.xml" -Force
 $srcWim="$WorkFolder\Source\sources\install.wim";$srcEsd="$WorkFolder\Source\sources\install.esd"
 if(!(Test-Path $srcWim)){
   $esdPro=FindProIndex $srcEsd
   if(!$esdPro){Fail 'Windows 10 Professional was not found in install.esd.'}
   Dism @('/Export-Image',"/SourceImageFile:$srcEsd","/SourceIndex:$esdPro","/DestinationImageFile:$WorkFolder\converted.wim",'/Compress:max','/CheckIntegrity') 'Converting Professional ESD to WIM'
   Move-Item "$WorkFolder\converted.wim" $srcWim -Force
   Remove-Item $srcEsd -Force
 }

 Step '5/12 - Exporting Professional only'
 $pro=FindProIndex $srcWim;if(!$pro){Fail 'Professional index not found.'};OK "Professional index: $pro"
 Dism @('/Export-Image',"/SourceImageFile:$srcWim","/SourceIndex:$pro","/DestinationImageFile:$WorkFolder\pro.wim",'/Compress:max','/CheckIntegrity') 'Professional export'
 Move-Item "$WorkFolder\pro.wim" $srcWim -Force
 "[EditionID]`r`nProfessional`r`n[Channel]`r`nRetail`r`n[VL]`r`n0" | Set-Content "$WorkFolder\Source\sources\ei.cfg" -Encoding ASCII

 Step '6/12 - Mounting Professional image'
 Remove-Item "$MountFolder\*" -Recurse -Force -ErrorAction SilentlyContinue
 Dism @('/Mount-Image',"/ImageFile:$srcWim",'/Index:1',"/MountDir:$MountFolder") 'Mounting image'
 $before=OfflineBuild $MountFolder;Info "Edition: $($before.Edition)";Info "Build: $($before.Build).$($before.UBR)"
 if($before.Edition -ne 'Professional' -and $before.Product -notmatch 'Windows 10 Pro'){Fail 'Mounted image is not Professional.'}

 Step '7/12 - Checking current packages/build'
 $pkgs=(& dism.exe /Image:$MountFolder /Get-Packages 2>&1|Out-String)
 if($pkgs -match [regex]::Escape($TargetKB)){OK "$TargetKB already present"}else{Info "$TargetKB not present"}

 Step '8/12 - Downloading required SSU'
 # Source ISO is normally far older than current servicing stack. KB5081263 is the
 # documented 19045.7052 SSU; Microsoft later combines current SSU with the LCU.
 $ssu=Ensure-Package $SSUKB

 Step '9/12 - Downloading current LCU'
 $lcu=Ensure-Package $TargetKB

 Step '10/12 - Applying packages'
 if($pkgs -notmatch [regex]::Escape($SSUKB)){Dism @("/Image:$MountFolder",'/Add-Package',"/PackagePath:$ssu",'/NoRestart') "Installing $SSUKB"}else{OK "$SSUKB already present"}
 $pkgs2=(& dism.exe /Image:$MountFolder /Get-Packages 2>&1|Out-String)
 if($pkgs2 -notmatch [regex]::Escape($TargetKB)){Dism @("/Image:$MountFolder",'/Add-Package',"/PackagePath:$lcu",'/NoRestart') "Installing $TargetKB"}else{OK "$TargetKB already present"}

 Step '11/12 - Validating final image'
 Dism @('/Unmount-Image',"/MountDir:$MountFolder",'/Commit') 'Committing image'
 # Re-mount briefly for authoritative offline registry validation.
 Dism @('/Mount-Image',"/ImageFile:$srcWim",'/Index:1',"/MountDir:$MountFolder") 'Validation mount'
 $after=OfflineBuild $MountFolder
 Info "Final edition: $($after.Edition)";Info "Final build: $($after.Build).$($after.UBR)"
 if($after.Build-ne$TargetBuild -or $after.UBR-ne$TargetUBR){Dism @('/Unmount-Image',"/MountDir:$MountFolder",'/Discard') 'Discarding invalid image';Fail "Expected 19045.7663 but got $($after.Build).$($after.UBR)."}
 Dism @('/Unmount-Image',"/MountDir:$MountFolder",'/Commit') 'Final commit'
 OK 'Windows 10 Professional 19045.7663 verified.'

 Step '12/12 - Creating bootable ISO'
 $sourceDir="$WorkFolder\Source"
 Remove-Item $OutputISO -Force -ErrorAction SilentlyContinue
 $boot="-bootdata:2#p0,e,b$EtfsBoot#pEF,e,b$EfiSys"
 & $Oscdimg -m -o -u2 -udfver102 -lWIN10PRO $boot $sourceDir $OutputISO
 if($LASTEXITCODE-ne 0){Fail "oscdimg failed: $LASTEXITCODE"}
 $final=Hash $OutputISO;$size=[math]::Round((Get-Item $OutputISO).Length/1GB,2)
 $report="$OutputFolder\BuildReport.txt"
 @"
Windows 10 Pro Builder v4
=========================
Source ISO: $($source.Path)
Source SHA-256: $($source.Hash)
Source validation: Windows 10 22H2 / x64 / English / Professional
SSU: $SSUKB
LCU: $TargetKB
Final edition: $($after.Edition)
Final build: $($after.Build).$($after.UBR)
autounattend.xml: YES
BIOS boot: YES
UEFI boot: YES
Final ISO: $OutputISO
Final ISO SHA-256: $final
ISO size GB: $size
"@|Set-Content $report -Encoding UTF8
 Write-Host "`nBUILD COMPLETE" -ForegroundColor Green;Write-Host "ISO: $OutputISO" -ForegroundColor Green;Write-Host "SHA-256: $final" -ForegroundColor Green;Write-Host "Report: $report" -ForegroundColor Green
 Read-Host 'Press ENTER to close'
}catch{
 Write-Host "`nBUILD FAILED" -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red;Write-Host "Log: $log" -ForegroundColor Yellow;Read-Host 'Press ENTER to close';exit 1
}finally{try{Stop-Transcript|Out-Null}catch{}}
