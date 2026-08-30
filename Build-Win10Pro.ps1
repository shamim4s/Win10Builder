#requires -Version 5.1
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
$Root=if($PSScriptRoot){$PSScriptRoot}else{"C:\Win10Builder"}
$ISOFolder="$Root\ISO"; $PackageFolder="$Root\Packages"; $WorkFolder="$Root\Work"; $MountFolder="$Root\Mount"; $OutputFolder="$Root\Output"; $LogFolder="$Root\Logs"
$SourceISO="$ISOFolder\Win10_22H2_English_x64.iso"; $OutputISO="$OutputFolder\Win10_22H2_Pro_19045.7663_English_x64.iso"; $AutoUnattend="$Root\autounattend.xml"; $BuildReport="$OutputFolder\BuildReport.txt"
$Oscdimg="$Root\Tools\Oscdimg\oscdimg.exe"; $EfiSys="$Root\Tools\Oscdimg\efisys.bin"; $EtfsBoot="$Root\Tools\Oscdimg\etfsboot.com"
$BcdBoot="$Root\Tools\BCDBoot\bcdboot.exe"; $BcdEdit="$Root\Tools\BCDBoot\bcdedit.exe"; $BootSect="$Root\Tools\BCDBoot\bootsect.exe"
$MassgraveURL="https://massgrave.dev/windows_10_links"; $CatalogURL="https://www.catalog.update.microsoft.com/Search.aspx?q="
$TargetKB="KB5120249"; $PrereqSSU="KB5031539"; $PrereqLCU="KB5028244"; $TargetBuild=19045; $TargetUBR=7663
$identity=[Security.Principal.WindowsIdentity]::GetCurrent(); $principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"";exit}
function Step($s){Write-Host "`n================================================================`n$s`n================================================================" -ForegroundColor DarkCyan}
function Info($s){Write-Host "[INFO] $s" -ForegroundColor Cyan}; function OK($s){Write-Host "[OK] $s" -ForegroundColor Green}; function Warn($s){Write-Host "[WARN] $s" -ForegroundColor Yellow}
function Fail($s){throw $s}
function Req($p,$d){if(!(Test-Path -LiteralPath $p -PathType Leaf)){Fail "$d not found: $p"}}
function Hash($p){(Get-FileHash $p -Algorithm SHA256).Hash.ToUpperInvariant()}
function Native($f,[string[]]$a,$n){Info "$n...";& $f @a;if($LASTEXITCODE-ne 0){Fail "$n failed with exit code $LASTEXITCODE"}}
function FindPkg($kb){Get-ChildItem $PackageFolder -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension-in ".msu",".cab" -and $_.Name-match[regex]::Escape($kb)}|Select-Object -First 1}
function ProIndex($w){$o=& dism.exe /Get-WimInfo /WimFile:$w 2>&1;$i=$null;foreach($l in $o){if("$l"-match'^\s*Index\s*:\s*(\d+)\s*$'){$i=[int]$Matches[1]}elseif("$l"-match'^\s*Name\s*:\s*Windows 10 Pro\s*$'){return $i}};return $null}
function OfflineBuild($m){$h="$m\Windows\System32\Config\SOFTWARE";Req $h "Offline SOFTWARE hive";$n="W10B_$PID";& reg.exe load "HKLM\$n" $h|Out-Null;if($LASTEXITCODE-ne 0){Fail "Cannot load offline SOFTWARE hive"};try{$p=Get-ItemProperty "HKLM:\$n\Microsoft\Windows NT\CurrentVersion";[pscustomobject]@{Build=[int]$p.CurrentBuild;UBR=[int]$p.UBR;EditionID="$($p.EditionID)";ProductName="$($p.ProductName)"}}finally{& reg.exe unload "HKLM\$n"|Out-Null}}
function Installed($m){(& dism.exe /Image:$m /Get-Packages 2>&1|Out-String)}
function OpenCatalog($kb){Start-Process ($CatalogURL+$kb)}
foreach($d in @($ISOFolder,$PackageFolder,$WorkFolder,$MountFolder,$OutputFolder,$LogFolder)){if(!(Test-Path $d)){New-Item -ItemType Directory $d -Force|Out-Null}}
$log="$LogFolder\Build-$(Get-Date -Format yyyyMMdd-HHmmss).log";Start-Transcript $log -Force|Out-Null
try{
Write-Host "Running as Administrator." -ForegroundColor Green
Step "1/12 - Checking local tools"
Req $Oscdimg "oscdimg.exe";Req $EfiSys "efisys.bin";Req $EtfsBoot "etfsboot.com";Req "$env:SystemRoot\System32\dism.exe" "Windows DISM"
OK "oscdimg: $Oscdimg";OK "UEFI boot image: $EfiSys";OK "BIOS boot image: $EtfsBoot"
if(Test-Path $BcdBoot){OK "bcdboot.exe available"};if(Test-Path $BcdEdit){OK "bcdedit.exe available"};if(Test-Path $BootSect){OK "bootsect.exe available"}
Step "2/12 - Checking autounattend.xml";Req $AutoUnattend "autounattend.xml";OK "autounattend.xml found"
Step "3/12 - Checking source ISO"

$IsoCandidates = @(
    Get-ChildItem -Path $ISOFolder -Filter "*.iso" -File -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending
)

if ($IsoCandidates.Count -eq 0) {

    Write-Host ""
    Write-Host "[INFO] No ISO found in:" -ForegroundColor Yellow
    Write-Host "       $ISOFolder" -ForegroundColor Yellow
    Write-Host ""

    Start-Process $MassgraveURL

    Read-Host "Download the Microsoft-hosted Windows 10 English x64 ISO "Win10_22H2_English_x64.iso", place it in $ISOFolder, then press ENTER"
    
    $IsoCandidates = @(
        Get-ChildItem -Path $ISOFolder -Filter "*.iso" -File -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending
    )
}

if ($IsoCandidates.Count -eq 0) {
    Fail "No .iso file was found in $ISOFolder"
}

if ($IsoCandidates.Count -gt 1) {
    Write-Host ""
    Write-Host "[INFO] Multiple ISO files detected:" -ForegroundColor Yellow

    $n = 1
    foreach ($iso in $IsoCandidates) {
        Write-Host "[$n] $($iso.Name) - $([math]::Round($iso.Length / 1GB,2)) GB"
        $n++
    }

    Write-Host ""
    Write-Host "[INFO] The largest ISO will be selected automatically." -ForegroundColor Cyan
}

$SourceISO = $IsoCandidates[0].FullName

OK "Source ISO found:"
Info $SourceISO

$SourceHash = Hash $SourceISO

OK "Source ISO SHA-256:"
Info $SourceHash
Step "4/12 - Extracting ISO contents"
$Source="$WorkFolder\Source";Remove-Item $Source -Recurse -Force -ErrorAction SilentlyContinue;New-Item -ItemType Directory $Source -Force|Out-Null
$disk=Mount-DiskImage $SourceISO -PassThru;Start-Sleep 2;$vol=$disk|Get-Volume;$drive="$($vol.DriveLetter):";try{robocopy "$drive\" $Source /E /R:1 /W:1 /NFL /NDL /NJH /NJS|Out-Null;if($LASTEXITCODE-gt 7){Fail "robocopy failed: $LASTEXITCODE"}}finally{Dismount-DiskImage $SourceISO -ErrorAction SilentlyContinue}
Copy-Item $AutoUnattend "$Source\autounattend.xml" -Force
$Wim="$Source\sources\install.wim";$Esd="$Source\sources\install.esd"
if(!(Test-Path $Wim)-and(Test-Path $Esd)){Native dism.exe @("/Export-Image","/SourceImageFile:$Esd","/SourceIndex:1","/DestinationImageFile:$WorkFolder\converted.wim","/Compress:max","/CheckIntegrity") "ESD to WIM conversion";Move-Item "$WorkFolder\converted.wim" $Wim -Force;Remove-Item $Esd -Force};Req $Wim "install.wim"
Step "5/12 - Extracting Professional only"
$idx=ProIndex $Wim;if(!$idx){Fail "Windows 10 Pro was not found"};OK "Professional index: $idx"
Native dism.exe @("/Export-Image","/SourceImageFile:$Wim","/SourceIndex:$idx","/DestinationImageFile:$WorkFolder\pro.wim","/Compress:max","/CheckIntegrity") "Professional export";Move-Item "$WorkFolder\pro.wim" $Wim -Force
@"
[EditionID]
Professional
[Channel]
Retail
[VL]
0
"@|Set-Content "$Source\sources\ei.cfg" -Encoding ASCII
Step "6/12 - Mounting Professional image"
Remove-Item $MountFolder -Recurse -Force -ErrorAction SilentlyContinue;New-Item -ItemType Directory $MountFolder -Force|Out-Null
Native dism.exe @("/Mount-Image","/ImageFile:$Wim","/Index:1","/MountDir:$MountFolder") "Mounting image"
$before=OfflineBuild $MountFolder;Info "Edition: $($before.EditionID)";Info "Build: $($before.Build).$($before.UBR)"
if($before.EditionID-ne "Professional" -and $before.ProductName-notmatch"Windows 10 Pro"){& dism.exe /Unmount-Image /MountDir:$MountFolder /Discard|Out-Null;Fail "Mounted image is not Professional"}
Step "7/12 - Checking installed packages";$installed=Installed $MountFolder;$hasTarget=$installed-match$TargetKB;$hasBaseline=$installed-match$PrereqLCU
if($hasTarget){OK "$TargetKB already present"}else{Info "$TargetKB not present"}
Step "8/12 - Preparing $TargetKB"
$target=FindPkg $TargetKB;if(!$target){OpenCatalog $TargetKB;Read-Host "Download the Windows 10 x64 $TargetKB MSU into $PackageFolder";$target=FindPkg $TargetKB};if(!$target){& dism.exe /Unmount-Image /MountDir:$MountFolder /Discard|Out-Null;Fail "$TargetKB package not found"};$targetHash=Hash $target.FullName;OK "Package: $($target.Name)";Info "SHA-256: $targetHash"
Step "9/12 - Applying servicing prerequisite"
if($hasBaseline){OK "$PrereqLCU or later baseline detected; $PrereqSSU not required by offline rule"}else{$ssu=FindPkg $PrereqSSU;if(!$ssu){OpenCatalog $PrereqSSU;Read-Host "Download Windows 10 x64 $PrereqSSU into $PackageFolder";$ssu=FindPkg $PrereqSSU};if(!$ssu){& dism.exe /Unmount-Image /MountDir:$MountFolder /Discard|Out-Null;Fail "$PrereqSSU is required for this old image but was not found"};Native dism.exe @("/Image:$MountFolder","/Add-Package","/PackagePath:$($ssu.FullName)") "Installing $PrereqSSU"}
Step "10/12 - Applying $TargetKB"
if(!(Installed $MountFolder-match$TargetKB)){Native dism.exe @("/Image:$MountFolder","/Add-Package","/PackagePath:$($target.FullName)") "Installing $TargetKB"}else{OK "$TargetKB already installed"}
& dism.exe /Image:$MountFolder /Cleanup-Image /StartComponentCleanup|Out-Null
Step "11/12 - Validating final build"
$after=OfflineBuild $MountFolder;Info "Final build: $($after.Build).$($after.UBR)";Info "Edition: $($after.EditionID)"
if($after.Build-ne$TargetBuild-or$after.UBR-ne$TargetUBR){& dism.exe /Unmount-Image /MountDir:$MountFolder /Discard|Out-Null;Fail "Expected $TargetBuild.$TargetUBR but got $($after.Build).$($after.UBR). ISO will not be created."}
OK "19045.7663 verified";Copy-Item $AutoUnattend "$Source\autounattend.xml" -Force
Step "12/12 - Committing and creating bootable ISO"
Native dism.exe @("/Unmount-Image","/MountDir:$MountFolder","/Commit") "Committing image";Remove-Item $OutputISO -Force -ErrorAction SilentlyContinue
$boot="-bootdata:2#p0,e,b$EtfsBoot#pEF,e,b$EfiSys";Native $Oscdimg @("-m","-o","-u2","-udfver102","-lWIN10PRO",$boot,$Source,$OutputISO) "Creating BIOS+UEFI ISO"
$finalHash=Hash $OutputISO;$size=[math]::Round((Get-Item $OutputISO).Length/1GB,2)
@"
WINDOWS 10 PRO 22H2 ISO BUILD REPORT
=====================================
Build time: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Source ISO: $SourceISO
Source SHA-256: $SourceHash
Target: Windows 10 Professional x64 English 22H2
Target build: 19045.7663
Target KB: $TargetKB
Target package: $($target.Name)
Target package SHA-256: $targetHash
Offline prerequisite: $PrereqSSU
Final edition: $($after.EditionID)
Final build: $($after.Build).$($after.UBR)
Professional only: YES
autounattend.xml at ISO root: YES
BIOS boot: YES
UEFI boot: YES
Output ISO: $OutputISO
Size GB: $size
FINAL ISO SHA-256: $finalHash
"@|Set-Content $BuildReport -Encoding UTF8
Write-Host "`nBUILD COMPLETE`nISO: $OutputISO`nSHA-256: $finalHash`nREPORT: $BuildReport" -ForegroundColor Green
Read-Host "Press ENTER to close"
}catch{Write-Host "`nBUILD FAILED`n$($_.Exception.Message)`nLog: $log" -ForegroundColor Red;Read-Host "Press ENTER to close";exit 1}finally{try{Stop-Transcript|Out-Null}catch{}}
