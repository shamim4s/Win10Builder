Windows 10 Pro ISO Builder v5

TARGET
- Windows 10 22H2
- Professional only
- x64
- English (United States) / en-US
- OS build 19045.7663
- LCU KB5120249

IMPORTANT CURRENT MICROSOFT SERVICING FACT
Microsoft's August 11, 2026 KB5120249 documentation says Microsoft now combines the latest SSU with the LCU. For OFFLINE servicing, however, an image without the July 25, 2023 LCU KB5028244 or later must first receive the special October 13, 2023 SSU KB5031539. This builder implements that exact branch.

FOLDER
C:\Win10Builder
  Build-Win10Pro-v5.ps1
  Start-Build-Win10Pro-v5.cmd
  autounattend.xml
  ISO\
  Packages\
  Tools\Oscdimg\oscdimg.exe
  Tools\Oscdimg\efisys.bin
  Tools\Oscdimg\etfsboot.com

EXISTING ISO
The script validates an existing ISO FIRST. It requires:
- Windows 10 22H2 / 19045
- x64
- Windows 10 Pro
- en-US

Your previously tested ISO is en-GB, so v5 intentionally rejects it and obtains the English (US) ISO from Microsoft's current Windows 10 ISO page.

MICROSOFT ISO
The script reads the live Microsoft Windows10ISO page to get its current page IDs and product ID. It then asks Microsoft's service for the English SKU and x64 ISO URL. It does not use the obsolete hard-coded page IDs that caused the earlier 404.

MICROSOFT ISO HASH
Microsoft currently publishes this English 64-bit Windows 10 ISO SHA-256:
A6F470CA6D331EB353B815C043E327A347F594F37FF525F17764738FE812852E

PACKAGES
The script searches Microsoft Update Catalog automatically and obtains the actual Microsoft download URL:
- KB5031539, only when the source lacks KB5028244 or later
- KB5120249, x64 Windows 10 22H2

Packages are cached under Packages\ and SHA-256 values are calculated/logged after download.

OUTPUT
Output\Win10_22H2_Pro_en-US_19045.7663.iso
Output\BuildReport.txt

The ISO includes AutoUnattend.xml at its root and has BIOS + UEFI boot entries.

RUN
Right-click Start-Build-Win10Pro-v5.cmd -> Run as administrator
or:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Win10Builder\Build-Win10Pro-v5.ps1

Requires Windows PowerShell 5.1, DISM, Mount-DiskImage, and oscdimg plus its BIOS/UEFI boot files.
