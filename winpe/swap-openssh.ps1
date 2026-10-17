# swap-openssh.ps1 -- put a different Win32-OpenSSH build into the PE image
# and rewrite the ISO.
#
# WHY A VERSION MATTERS HERE. Win32-OpenSSH 9.5 does privilege separation by
# spawning a second copy of itself to hold the network side of the connection:
#
#     debug3: spawning "...sshd.exe" ... -y as user
#     debug2: Network child is on pid 336
#     debug3: preauth child monitor started
#     debug1: Killing privsep child 336
#
# In WinPE that child dies the moment it starts, and the client gets
# "Connection reset by peer" after a successful version exchange. The same
# binary, same config and same path works on full Windows, so it is the
# environment the child lands in rather than the build being broken. Older
# Win32-OpenSSH releases create that child differently, which is why trying
# one is cheaper than trying to give WinPE whatever the new one wants.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Url,
    [string] $Work    = 'C:\winpe',
    [string] $Stage   = 'C:\winpe\stage',
    [string] $Out     = 'C:\winpe\v5c2-winpe.iso',
    [string] $Oscdimg = 'C:\winpe\tools\oscdimg'
)
$ErrorActionPreference = 'Stop'
$mediaDir = Join-Path $Work 'media'
$mountDir = Join-Path $Work 'mount'
# Cache by RELEASE TAG, not by file name. Every Win32-OpenSSH release ships a
# file called OpenSSH-Win64.zip, so keying on the name makes the second
# version silently reuse the first one's download -- a test that proves
# nothing while looking like it passed.
$tag      = ($Url -split '/')[-2]
$tmp      = Join-Path $Work ("ssh-" + $tag)

'== fetch {0}' -f $Url
$zip = "$tmp.zip"
if (-not (Test-Path $zip)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
}
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$src = Get-ChildItem $tmp -Directory | Select-Object -First 1
'{0} bytes, unpacked to {1}' -f (Get-Item $zip).Length, $src.FullName
# Not every build answers -V (8.1 does not), and a missing version banner is
# no reason to abandon the swap.
try { & (Join-Path $src.FullName 'sshd.exe') -V 2>&1 | Select-Object -First 1 } catch { 'sshd -V not supported by this build' }

'== mount'
New-Item -ItemType Directory -Force $mountDir | Out-Null
dism /Mount-Image /ImageFile:"$mediaDir\sources\boot.wim" /Index:1 /MountDir:$mountDir
if ($LASTEXITCODE -ne 0) { throw "mount failed ($LASTEXITCODE)" }

'== replace OpenSSH and the boot-time scripts'
$sshDst = Join-Path $mountDir 'Program Files\OpenSSH'
Remove-Item -Recurse -Force $sshDst -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $sshDst | Out-Null
Copy-Item -Force (Join-Path $src.FullName '*') $sshDst
Copy-Item -Force (Join-Path $Stage 'sshd_config')  (Join-Path $sshDst 'sshd_config')
Copy-Item -Force (Join-Path $Stage 'startnet.cmd') (Join-Path $mountDir 'Windows\System32\startnet.cmd')
'files in image OpenSSH: {0}' -f (Get-ChildItem $sshDst).Count

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
