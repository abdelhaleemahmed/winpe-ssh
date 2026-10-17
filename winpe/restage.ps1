# restage.ps1 -- put the current startnet.cmd and sshd_config back into the
# already-exported PE image and rewrite the ISO.
#
# Iterating on what a recovery environment does at boot means changing one
# batch file and booting it again. Re-exporting boot.wim from the installation
# media to do that costs forty minutes and changes nothing else, so this does
# the three steps that matter: mount, replace, commit, and write the ISO.
[CmdletBinding()]
param(
    [string] $Work    = 'C:\winpe',
    [string] $Stage   = 'C:\winpe\stage',
    [string] $Out     = 'C:\winpe\v5c2-winpe.iso',
    [string] $Oscdimg = 'C:\winpe\tools\oscdimg'
)
$ErrorActionPreference = 'Stop'
$mediaDir = Join-Path $Work 'media'
$mountDir = Join-Path $Work 'mount'

if (-not (Test-Path "$mediaDir\sources\boot.wim")) { throw "no exported boot.wim at $mediaDir\sources" }
New-Item -ItemType Directory -Force $mountDir | Out-Null

'== mount'
dism /Mount-Image /ImageFile:"$mediaDir\sources\boot.wim" /Index:1 /MountDir:$mountDir
if ($LASTEXITCODE -ne 0) { throw "mount failed ($LASTEXITCODE)" }

'== replace the boot-time scripts'
Copy-Item -Force (Join-Path $Stage 'startnet.cmd') (Join-Path $mountDir 'Windows\System32\startnet.cmd')
Copy-Item -Force (Join-Path $Stage 'sshd_config')  (Join-Path $mountDir 'Program Files\OpenSSH\sshd_config')
'startnet.cmd in image : {0}' -f (Get-FileHash (Join-Path $mountDir 'Windows\System32\startnet.cmd') -Algorithm SHA256).Hash
'startnet.cmd staged   : {0}' -f (Get-FileHash (Join-Path $Stage 'startnet.cmd') -Algorithm SHA256).Hash

'== inject sc.exe'
# WinPE does not ship sc.exe, and sshd has to be registered as a service
# for its privilege-separation child to have an NT SERVICE\sshd account to
# run as. sc.exe is a plain console client for the service control manager,
# which PE does run, so copying it in is enough.
Copy-Item -Force C:\Windows\System32\sc.exe (Join-Path $mountDir 'Windows\System32\sc.exe')
'sc.exe in image : {0}' -f (Test-Path (Join-Path $mountDir 'Windows\System32\sc.exe'))

"== inject runas-user.exe"
# WinPE runs everything as SYSTEM and sshd cannot serve a connection as
# SYSTEM; this launcher starts it as a named local user instead. See the
# comment at the top of runas-user/main.go for the source that proves it.
Copy-Item -Force (Join-Path $Stage 'runas-user.exe') (Join-Path $mountDir 'Windows\System32\runas-user.exe')
'runas-user.exe in image : {0}' -f (Test-Path (Join-Path $mountDir 'Windows\System32\runas-user.exe'))

"== inject pe-sshd.exe"
# The ssh server that actually works in WinPE. Win32-OpenSSH is still in the
# image under Program Files, unused, because the chapter shows what it does
# there; nothing starts it.
Copy-Item -Force (Join-Path $Stage 'pe-sshd.exe') (Join-Path $mountDir ('Windows' + [char]92 + 'System32' + [char]92 + 'pe-sshd.exe'))
'pe-sshd.exe in image : {0}' -f (Test-Path (Join-Path $mountDir ('Windows' + [char]92 + 'System32' + [char]92 + 'pe-sshd.exe')))

'== commit'
dism /Unmount-Image /MountDir:$mountDir /Commit
if ($LASTEXITCODE -ne 0) { throw "unmount failed ($LASTEXITCODE)" }

'== rewrite the ISO'
Remove-Item $Out -Force -ErrorAction SilentlyContinue
& (Join-Path $Oscdimg 'oscdimg.exe') -m -o -u2 -udfver102 `
    ("-bootdata:2#p0,e,b{0}\etfsboot.com#pEF,e,b{0}\efisys_noprompt.bin" -f $Oscdimg) $mediaDir $Out
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed ($LASTEXITCODE)" }

'{0}  {1:N0} bytes' -f $Out, (Get-Item $Out).Length
'sha256 {0}' -f (Get-FileHash $Out -Algorithm SHA256).Hash
'== done =='
