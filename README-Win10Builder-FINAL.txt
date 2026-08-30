WIN10BUILDER FINAL

Put these files in C:\Win10Builder:
Build-Win10Pro.ps1
Start-Build.cmd
autounattend.xml

Tools:
Tools\Oscdimg\oscdimg.exe
Tools\Oscdimg\efisys.bin
Tools\Oscdimg\etfsboot.com
Tools\BCDBoot\bcdboot.exe
Tools\BCDBoot\bcdedit.exe
Tools\BCDBoot\bootsect.exe

The script does NOT install ADK. It uses local tools and Windows inbox DISM.

Source ISO:
ISO\Win10_22H2_English_x64.iso

If missing, the script opens:
https://massgrave.dev/windows_10_links
Save the Microsoft-hosted English x64 Windows 10 22H2 ISO using the filename above.

Target:
KB5120249 -> Windows 10 22H2 OS build 19045.7663.
Microsoft: https://support.microsoft.com/en-us/servicing/os/windows-10/2026/08/kb5120249-windows-10-21h2-22h2-security-update

If KB5120249 is missing, the script opens Microsoft Update Catalog and asks for the Windows 10 x64 MSU in Packages.

For an old source lacking KB5028244 or later, Microsoft requires standalone KB5031539 before the current LCU for offline servicing. The script checks and requests it when needed.

The script:
- keeps Windows 10 Professional only
- writes sources\ei.cfg for Professional
- injects autounattend.xml at ISO root
- validates the actual offline build
- refuses to create the ISO unless it is exactly 19045.7663
- creates BIOS + UEFI bootable ISO
- calculates SHA-256
- creates BuildReport.txt and a transcript
