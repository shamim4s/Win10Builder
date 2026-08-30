WINDOWS 10 PRO ISO BUILDER v4

1. Put these in C:\Win10Builder:
   Build-Win10Pro-v4.ps1
   Start-Build-Win10Pro-v4.cmd
   autounattend.xml

2. Keep:
   Tools\Oscdimg\oscdimg.exe
   Tools\Oscdimg\efisys.bin
   Tools\Oscdimg\etfsboot.com
   Tools\BCDBoot\... (kept for future use)

3. Put any existing Windows 10 ISO in:
   C:\Win10Builder\ISO

v4 VALIDATES EXISTING ISO FIRST:
- mounts ISO temporarily
- checks install.wim/install.esd
- checks x64
- checks Windows 10 22H2 / build 19045
- checks English/en-US
- checks Windows 10 Pro
- if suitable, it REUSES the ISO regardless of filename or hash
- if the SHA-256 matches Microsoft's current English x64 hash, it reports it as officially hash-verified
- if unsuitable, it obtains a fresh ISO URL from Microsoft's current Windows10ISO page

MICROSOFT ISO DISCOVERY:
v4 reads the current data-defaultpageid values from Microsoft's page instead of hard-coding obsolete API page IDs. It then asks Microsoft's Windows10ISO service for the English SKU and x64 ISO URL.

PACKAGE DOWNLOAD:
v4 automatically discovers packages from Microsoft Update Catalog and caches them under Packages.
Current target:
- SSU: KB5081263 (19045.7052)
- LCU: KB5120249 (19045.7663)

The Microsoft March 2026 servicing documentation states that KB5081263 is the Windows 10 19045.7052 SSU and that Microsoft now combines the latest SSU with the latest LCU. The August 11, 2026 KB5120249 article lists 19045.7663.

OUTPUT:
Output\Win10_22H2_Pro_19045.7663_English_x64.iso
Output\BuildReport.txt

IMPORTANT:
19045.7663 is an ESU-era Windows 10 build. Microsoft's August 2026 KB5120249 applies to Windows 10 ESU. This builder does not bypass Microsoft's licensing or ESU eligibility.
