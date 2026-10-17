@echo off
rem ---------------------------------------------------------------------------
rem startnet.cmd -- what Windows PE runs the moment it finishes booting.
rem
rem THIS IS ONE LAB'S OWN FILE, not a generic template. Three things in it are
rem site-specific and you will want to change them: the static address
rem 192.168.56.25 and the adapter it is set on, the account name and password,
rem and the wbadmin hints at the end, which name that lab's machine and backup
rem volume. The order of the rest -- wpeinit, address, firewall, account,
rem server -- is the part worth copying, and each line says why it is there.
rem
rem WinPE has no services, no installed roles and no persistent registry: it is
rem a RAM disk mounted as X:. Everything this file sets up disappears at power
rem off, which is why it is set up again on every boot rather than installed.
rem
rem The point of it is the last section: a Windows recovery environment you can
rem reach over ssh. Without that, a bare-metal recovery is something you type
rem at a console, blind, and cannot script, re-run or record.
rem ---------------------------------------------------------------------------
echo.
echo ============================================================
echo  V5C2 Windows PE  --  bare-metal recovery environment
echo ============================================================

rem wpeinit starts PnP and brings up networking (DHCP on every adapter).
echo [1/5] wpeinit: devices and network
wpeinit
wpeutil InitializeNetwork

rem The lab's host-only network has no DHCP server, so the second adapter comes
rem up with a 169.254 address and is unreachable. VirtualBox's NAT port
rem forwarding is not a substitute: a host connecting to a forwarded port is
rem accepted by the NAT engine whether or not anything is listening in the
rem guest, so it looks connected and then never produces an ssh banner, which
rem is indistinguishable from a broken sshd. A static address on the lab
rem network takes that whole layer out of the picture.
rem
rem VirtualBox presents NIC1 (NAT) as "Ethernet" and NIC2 (host-only) as
rem "Ethernet 2"; the fallback covers a differently named second adapter.
netsh interface ipv4 set address name="Ethernet 2" static 192.168.56.25 255.255.255.0 >nul 2>&1
if errorlevel 1 netsh interface ipv4 set address name="Ethernet Instance 0 2" static 192.168.56.25 255.255.255.0 >nul 2>&1
ipconfig | find "IPv4"

rem WinPE runs a firewall and blocks inbound connections, which is the last
rem thing standing between a correct address, a listening sshd, and a client
rem that still times out. wpeutil has a switch for precisely this. Everything
rem up to here can be right and the environment still unreachable without it.
wpeutil DisableFirewall
netsh advfirewall set allprofiles state off >nul 2>&1

rem A local account is the part people get wrong. sshd on Windows does not
rem authenticate against a file of its own -- it asks Windows to log a user in
rem and hand back a token, so there has to BE a user. WinPE boots with none.
echo.
echo [2/5] local account for sshd
net user peadmin PeRecover!2026 /add
echo     --- local groups this PE has ---
net localgroup
echo     --- creating the built-in groups PE lacks ---
net localgroup Users /add
net localgroup Administrators /add
net localgroup Users peadmin /add
net localgroup Administrators peadmin /add

rem Win32-OpenSSH resolves its own paths through the environment, and the
rem connection-handling child it spawns re-resolves them from scratch. WinPE's
rem environment is minimal: without these the child exits the instant it
rem starts, the parent logs only "child log fd closed", and the client is told
rem "Connection reset by peer" with nothing else to go on.
set ProgramData=X:\ProgramData
set ALLUSERSPROFILE=X:\ProgramData
set USERPROFILE=X:\Users\Default
set HOMEDRIVE=X:
set HOMEPATH=\Users\Default
if not exist X:\Users\Default md X:\Users\Default
echo     ProgramData   : %ProgramData%

echo.
echo [3/5] ssh host keys
if not exist X:\ProgramData\ssh md X:\ProgramData\ssh
copy /y "X:\Program Files\OpenSSH\sshd_config" X:\ProgramData\ssh\sshd_config >nul
"X:\Program Files\OpenSSH\ssh-keygen.exe" -A

echo.
echo [4/5] starting sshd
rem -D keeps sshd in the foreground of its own window. Without it sshd tries to
rem detach the way it would as a Windows service, the window stays open looking
rem healthy, nothing ends up listening on port 22, and a client gets a TCP
rem connection that never produces a banner -- which reads as a network fault
rem and is not one. The config test and the netstat line below exist so that
rem this is visible on the console instead of being inferred from a timeout.
"X:\Program Files\OpenSSH\sshd.exe" -t -f X:\ProgramData\ssh\sshd_config
if errorlevel 1 echo     sshd config test FAILED
rem sshd MUST be registered as a service here, not merely started as a process.
rem On Windows, sshd accepts a connection and then re-executes itself to do
rem privilege separation, and that child authenticates as the virtual account
rem NT SERVICE\sshd. A virtual account exists only for a registered service of
rem that name, so with sshd run as a bare process the parent logs
rem
rem     debug3: spawning "...\sshd.exe" -D -e -f ... -R as subprocess
rem     debug3: send_rexec_state: done
rem
rem and the child dies without a word. The client sees "Connection reset by
rem peer" and nothing explains why. Registering the service makes the account
rem exist. The manual start below stays as a fallback and as the thing that
rem prints a log to the console when the service route fails.
rem Two things are needed and neither is obvious.
rem
rem FIRST, a local account named sshd. On Windows, sshd re-executes itself for
rem every connection to do privilege separation, and that child runs as the
rem sshd account. Without it the parent logs
rem     debug3: spawning "...\sshd.exe" ... -R as subprocess
rem     debug3: send_rexec_state: done
rem and the child dies silently; the client sees "Connection reset by peer".
net user sshd SshPriv!2026 /add

rem SECOND, sshd has to stay in the foreground (-D). Registering it as a
rem service was tried instead and is a dead end in PE: sc.exe is not even part
rem of WinPE, and with sc.exe copied in the service is created but never
rem listens. -e puts its log in this window, which on a machine with no disk
rem and no second screen is the only place it can be read.
rem Find the backup volume by the folder wbadmin creates. This serves twice:
rem it is the -backupTarget the recovery needs, and it is somewhere writable
rem that survives a reboot, which is the only way to read sshd's log. X: is a
rem RAM disk and everything on it is gone the moment the machine restarts.
set BKP=
for %%D in (C D E F G H) do if exist %%D:\WindowsImageBackup set BKP=%%D:
if defined BKP echo     backup volume : %BKP%
set SSHLOG=X:\sshd-pe.log
if defined BKP set SSHLOG=%BKP%\sshd-pe.log
echo     sshd log      : %SSHLOG%

rem WHY A SERVICE AND NOT JUST A PROCESS -- read out of the Win32-OpenSSH
rem source rather than guessed. sshd hands each connection to a child that it
rem spawns AS THE USER "sshd" (SSH_PRIVSEP_USER in ssh.h), and
rem win32_usertoken_utils.c picks how to get that token:
rem
rem     if (!am_system() && (token = generate_sshd_token_as_nonsystem()) != 0)
rem             goto done;
rem     if ((token = generate_sshd_virtual_token()) == 0)
rem             error("... ensure sshd service has TCB privileges");
rem
rem and the non-SYSTEM branch is the whole answer, because it is this:
rem
rem     HANDLE generate_sshd_token_as_nonsystem() {
rem         HANDLE token = 0;
rem         OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS_P, &token);
rem         return token;
rem     }
rem
rem It hands back sshd's own token. No account, no service, nothing to set up
rem -- it only has to be true that sshd is not SYSTEM. startnet.cmd IS SYSTEM,
rem so PE always took the other branch, which wants the virtual account
rem NT SERVICE\sshd, which exists only for a registered service, which WinPE
rem cannot provide: its registry carries neither Schedule nor seclogon, so
rem schtasks and runas are out too.
rem
rem runas-user.exe (built from winpe/runas-user, injected by the build) does
rem the one thing needed: LogonUser as a local account, then
rem CreateProcessAsUser. Both are plain API calls and need no service.
rem AND IT STILL DOES NOT WORK. Running sshd as a plain user was tried with
rem runas-user.exe and changes nothing: the -y child dies exactly as it does
rem under SYSTEM, on 7.7.2.0p1, 8.1.0.0p1 and 9.5.0.0p1 alike. Win32-OpenSSH
rem cannot serve a connection in WinPE, full stop. Its files are left in the
rem image because the chapter shows what they do there; nothing starts them.
rem
rem pe-sshd.exe is the server that does work: one process, no privilege
rem separation, no second copy of itself to spawn -- which is the only reason
rem it survives here. It also stays SYSTEM, so the session can run wbadmin,
rem which a limited account could not.
start "pe-sshd" "X:\Windows\System32\pe-sshd.exe" -addr :22 -user peadmin -pass PeRecover!2026
ping -n 6 127.0.0.1 >nul
netstat -an | find ":22 "
echo     if nothing is listening above, falling back to a foreground sshd
netstat -an | find ":22 " >nul || start "sshd" "X:\Program Files\OpenSSH\sshd.exe" -D -e -E %SSHLOG% -f X:\ProgramData\ssh\sshd_config
ping -n 4 127.0.0.1 >nul
ping -n 4 127.0.0.1 >nul
echo     listening sockets on port 22:
netstat -an | find ":22 "

echo.
echo [5/5] ready
echo     user     : peadmin
echo     password : PeRecover!2026
echo     reach it : ssh peadmin@192.168.56.25
echo.
echo  The backup to restore from is on the second disk. To recover:
echo     wbadmin get versions -backupTarget:E:
echo     wbadmin start sysrecovery -version:^<version^> -backupTarget:E: -machine:V5C2WIN -restoreAllVolumes -quiet
echo.
