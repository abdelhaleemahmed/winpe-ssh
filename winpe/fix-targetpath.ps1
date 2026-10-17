# fix-targetpath.ps1 -- apply the SYSTEMROOT fix to an image that is already
# exported, and rewrite the ISO, without repeating the 40-minute export.
#
# This exists because the full build re-exports boot.wim from the installation
# media every time, and the only thing wrong with the image it produced was one
# DISM setting. Everything else in it -- OpenSSH, startnet.cmd, the bootable
# mark -- is already correct and committed.
[CmdletBinding()]
param(
    [string] $Work    = 'C:\winpe',
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

'== confirm what is already inside'
'openssh : {0}' -f (Test-Path "$mountDir\Program Files\OpenSSH\sshd.exe")
'startnet: {0}' -f (Test-Path "$mountDir\Windows\System32\startnet.cmd")
'wbadmin : {0}' -f (Test-Path "$mountDir\Windows\System32\wbadmin.exe")

'== set the target path'
# The argument is the deployment ROOT, not the Windows directory: DISM
# appends \Windows itself. Passing X:\Windows yields a configured path of
# X:\windows\Windows and the same refusal with different text. The trailing
# backslash also has to survive PowerShell's native-argument quoting, which
# is why this goes through cmd with a trailing space.
cmd /c "dism /Image:$mountDir /Set-TargetPath:X:\ "
if ($LASTEXITCODE -ne 0) { throw "set-targetpath failed ($LASTEXITCODE)" }

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
