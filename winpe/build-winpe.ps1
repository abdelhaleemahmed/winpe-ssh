# build-winpe.ps1 -- build a bootable Windows PE with an ssh server in it.
#
# WHY THIS RUNS INSIDE A WINDOWS GUEST. DISM refuses to mount an image without
# administrative rights, and the only Windows machine in this lab that is
# already Administrator is the guest itself. Building the recovery environment
# on the machine it will recover is also the honest arrangement: everything
# here comes from that machine's own installation media.
#
# WHAT IT PRODUCES. One ISO that boots on BIOS or UEFI, containing the Windows
# PE that ships on the Windows Server 2022 media, plus:
#   * Win32-OpenSSH, so the recovery can be driven from another machine
#   * startnet.cmd, which brings up the network, creates the account sshd needs
#     and starts it
# and nothing else. wbadmin, diskpart, dism and bcdboot are already in that PE
# -- checked, not assumed, by this script before it changes anything.
#
# WHAT IT DOES NOT NEED. The Windows ADK's WinPE add-on and its `copype`:
# the installation media already carries a WinPE in sources\boot.wim (index 1,
# "Microsoft Windows PE (amd64)"). Only oscdimg is borrowed from the ADK, to
# write the bootable ISO, and it is copied in beside this script.
[CmdletBinding()]
param(
    [string] $Media    = 'D:',                     # mounted Windows Server 2022 media
    [string] $Work     = 'C:\winpe',
    [string] $Out      = 'C:\winpe\v5c2-winpe.iso',
    [string] $Oscdimg  = 'C:\winpe\tools\oscdimg',  # oscdimg.exe + etfsboot.com + efisys.bin
    [string] $SshUrl   = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip',
    [string] $Stage    = 'C:\winpe\stage'           # startnet.cmd + sshd_config land here
)

$ErrorActionPreference = 'Stop'
function Step($n, $m) { Write-Host ("`n== {0} {1}" -f $n, $m) -ForegroundColor Cyan }

$mediaDir = Join-Path $Work 'media'
$mountDir = Join-Path $Work 'mount'

Step 1 "clean working directories"
foreach ($d in @($mountDir, $mediaDir)) {
    if (Test-Path $d) {
        # A left-over mount keeps a lock on the directory; discard it rather
        # than fail three steps later with a file-in-use error.
        try { dism /Unmount-Image /MountDir:$d /Discard 2>&1 | Out-Null } catch {}
        Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force $d | Out-Null
}

Step 2 "copy the boot files off the installation media"
# Only what a bootable PE needs: the boot managers, their configuration, and
# boot.wim. install.wim (4+ GB of Windows itself) is deliberately not copied.
foreach ($item in @('bootmgr', 'bootmgr.efi', 'boot', 'efi')) {
    Copy-Item -Recurse -Force (Join-Path $Media $item) $mediaDir
}
New-Item -ItemType Directory -Force (Join-Path $mediaDir 'sources') | Out-Null

Step 3 "export index 1 (the PE) out of boot.wim"
# /Export-Image takes the one image we want; the media's boot.wim also holds
# index 2, Windows Setup, which is 2.2 GB of installer we have no use for.
#
# /Bootable is NOT optional, and leaving it out fails silently until the very
# end. Windows media boots whichever image inside boot.wim carries the
# bootable mark, and on the installation media that mark is on index 2, not
# index 1. Export index 1 without it and the ISO boots as far as the Windows
# Boot Manager and then stops with
#
#     File: \windows\system32\boot\winload.efi
#     Status: 0xc0000225
#     Info: The application or operating system couldn't be loaded because a
#           required file is missing or contains errors.
#
# which reads like a corrupt image and is really one missing flag.
dism /Export-Image /SourceImageFile:"$Media\sources\boot.wim" /SourceIndex:1 `
     /DestinationImageFile:"$mediaDir\sources\boot.wim" /Bootable /CheckIntegrity
if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image failed ($LASTEXITCODE)" }

Step 4 "mount it"
dism /Mount-Image /ImageFile:"$mediaDir\sources\boot.wim" /Index:1 /MountDir:$mountDir
if ($LASTEXITCODE -ne 0) { throw "dism /Mount-Image failed ($LASTEXITCODE)" }

Step 5 "check the recovery tools are in this PE before changing it"
$need = @{
    'wbadmin.exe'  = 'Windows\System32\wbadmin.exe'
    'diskpart.exe' = 'Windows\System32\diskpart.exe'
    'dism.exe'     = 'Windows\System32\Dism.exe'
    'bcdboot.exe'  = 'Windows\System32\bcdboot.exe'
    'net.exe'      = 'Windows\System32\net.exe'
}
$missing = @()
foreach ($k in $need.Keys | Sort-Object) {
    $present = Test-Path (Join-Path $mountDir $need[$k])
    '{0,-14} {1}' -f $k, $present
    if (-not $present) { $missing += $k }
}
if ($missing -contains 'wbadmin.exe') {
    throw "wbadmin.exe is not in this PE -- the sysrecovery route is not available from it"
}

Step 5b "point the image at its own SYSTEMROOT"
# The PE on installation media is configured for Windows Setup, whose system
# root is X:\$windows.~bt\Windows rather than X:\Windows. Boot it as a
# standalone PE without changing that and it gets as far as its own desktop
# and then refuses with a dialog:
#
#   Windows PE cannot start because the actual SYSTEMROOT directory
#   (X:\windows) is different from the configured one
#   (X:\$windows.~bt\Windows). This can be configured from dism.exe with the
#   /set-targetpath command.
#
# which is, to its credit, an error message that names its own fix.
# The argument is the deployment ROOT: DISM appends \Windows itself, so
# X:\Windows produces a configured path of X:\windows\Windows and the same
# refusal. The trailing backslash must also survive PowerShell's handling of
# native arguments, hence cmd and the trailing space.
cmd /c "dism /Image:$mountDir /Set-TargetPath:X:\ "
if ($LASTEXITCODE -ne 0) { throw "dism /Set-TargetPath failed ($LASTEXITCODE)" }

Step 6 "fetch Win32-OpenSSH"
$zip = Join-Path $Work 'OpenSSH-Win64.zip'
if (-not (Test-Path $zip)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $SshUrl -OutFile $zip -UseBasicParsing
}
'{0} bytes, SHA256 {1}' -f (Get-Item $zip).Length, (Get-FileHash $zip -Algorithm SHA256).Hash
$sshTmp = Join-Path $Work 'ssh'
if (Test-Path $sshTmp) { Remove-Item -Recurse -Force $sshTmp }
Expand-Archive -Path $zip -DestinationPath $sshTmp -Force

Step 7 "inject ssh and startnet.cmd into the image"
$sshDst = Join-Path $mountDir 'Program Files\OpenSSH'
New-Item -ItemType Directory -Force $sshDst | Out-Null
Copy-Item -Force (Join-Path $sshTmp 'OpenSSH-Win64\*') $sshDst
Copy-Item -Force (Join-Path $Stage 'sshd_config')  (Join-Path $sshDst 'sshd_config')
Copy-Item -Force (Join-Path $Stage 'startnet.cmd') (Join-Path $mountDir 'Windows\System32\startnet.cmd')
'injected: {0} files into Program Files\OpenSSH' -f (Get-ChildItem $sshDst).Count

Step 8 "commit"
dism /Unmount-Image /MountDir:$mountDir /Commit
if ($LASTEXITCODE -ne 0) { throw "dism /Unmount-Image failed ($LASTEXITCODE)" }

Step 9 "write the bootable ISO"
# -bootdata:2#... gives the ISO both an El Torito BIOS boot image and a UEFI
# one, so the same file boots either firmware. The Windows machine here is
# UEFI; building both costs nothing and removes a class of "it will not boot".
$etfs = Join-Path $Oscdimg 'etfsboot.com'
# efisys.bin is the ADK's PROMPTING UEFI boot image: media built with it
# stops at "Press any key to boot from CD or DVD......" and, if nobody
# presses one, falls through to the next boot device. On a headless machine
# that is a recovery that silently does not happen. efisys_noprompt.bin is
# the same thing without the prompt, and it is what unattended media wants.
$efi  = Join-Path $Oscdimg 'efisys_noprompt.bin'
& (Join-Path $Oscdimg 'oscdimg.exe') -m -o -u2 -udfver102 `
    "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi" $mediaDir $Out
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed ($LASTEXITCODE)" }

'{0}  {1:N0} bytes' -f $Out, (Get-Item $Out).Length
Write-Host "`n== done ==" -ForegroundColor Green
