# winpe-ssh

**An ssh server that works inside Windows PE, and the account of why Microsoft's own one does not.**

A Windows PE image you can reach over ssh turns a bare-metal recovery from
something you type blind at a console into something you can script, re-run
and record. The obvious way to get there is to put [Win32-OpenSSH][win32]
into the image. That does not work, and this repository is both the
explanation and a server that does.

Everything here was found by running it: a Windows Server 2022 PE
(21H2, build 20348.5020) booted on a UEFI virtual machine, driven from a
Linux host.

[win32]: https://github.com/PowerShell/Win32-OpenSSH

---

## The short version

| | |
|---|---|
| **Symptom** | ssh connects, exchanges versions, then `Connection reset by peer` |
| **Cause** | sshd hands each connection to a **second copy of itself**, and that child cannot run in WinPE |
| **Not the cause** | the OpenSSH version, SYSTEM vs a normal user, the firewall, missing DLLs, the environment, a path with a space, the lack of a registered service |
| **Fix** | an ssh server with no privilege separation and no child process: `pe-sshd` |

---

## Why Win32-OpenSSH cannot serve a connection in WinPE

### What you see

sshd starts, binds, and logs nothing alarming:

```
Server listening on 0.0.0.0 port 22.
```

The client connects and is dropped:

```
$ ssh peadmin@192.168.56.25
kex_exchange_identification: read: Connection reset by peer
```

### What the server log says

With `-E <file>` and `LogLevel DEBUG3`, the failure is precise — and it is
not in the handshake, which completes:

```
Connection from 192.168.56.1 port 33544 on 192.168.56.25 port 22
debug1: Local version string SSH-2.0-OpenSSH_for_Windows_8.1
debug1: Remote protocol version 2.0, remote software version OpenSSH_9.9
debug3: spawning "X:\Program Files\OpenSSH\sshd.exe" ... -y as user
debug2: Network child is on pid 1856
debug3: preauth child monitor started
debug1: monitor_read_log: child log fd closed      <-- the child is already gone
debug1: do_cleanup
debug1: Killing privsep child 1856
```

The child that is meant to hold the network side of the session dies the
instant it starts, and sshd tears the connection down.

### What the source says

From [`sshd-session.c`][src-session] in PowerShell/openssh-portable, the
Windows build spawns that child rather than forking:

```c
if (__posix_spawn_asuser(&pid, options.sshd_auth_path, &actions, NULL,
                         saved_argv, NULL, SSH_PRIVSEP_USER) != 0)
        fatal("%s, fork of unprivileged child failed", __func__);
debug2("Network child is on pid %ld", (long)pid);
```

`SSH_PRIVSEP_USER` is `"sshd"` (`ssh.h`). How that token is obtained depends
on who sshd itself is, from [`win32_usertoken_utils.c`][src-token]:

```c
if (wcscmp(user_utf16, L"sshd") == 0) {
        /* not running as system, try generating sshd token as admin */
        if (!am_system() && (token = generate_sshd_token_as_nonsystem()) != 0)
                goto done;
        if ((token = generate_sshd_virtual_token()) == 0)
                error("%s - unable to generate sshd virtual token, "
                      "ensure sshd service has TCB privileges", __func__);
        goto done;
}
```

and the non-SYSTEM branch is simply

```c
HANDLE generate_sshd_token_as_nonsystem()
{
        HANDLE token = 0;
        OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS_P, &token);
        return token;
}
```

So there are two paths. As SYSTEM — which is everything WinPE's
`startnet.cmd` launches — it needs the virtual account `NT SERVICE\sshd`,
which exists only for a **registered service**. WinPE's registry carries
neither `Schedule` nor `seclogon`, so `schtasks` and `runas` cannot help
either, and `sc.exe` is not even present in the image.

That is a good theory. It is also **not sufficient**, which is the part worth
recording: running sshd as an ordinary local account (via `runas-user`, in
this repo) takes the first branch — the one that just returns its own token —
and the child *still* dies. The privilege-separation child cannot run in
WinPE regardless of which token it is given.

[src-session]: https://github.com/PowerShell/openssh-portable/blob/latestw_all/sshd-session.c
[src-token]: https://github.com/PowerShell/openssh-portable/blob/latestw_all/contrib/win32/win32compat/win32_usertoken_utils.c

### What was tested

| Win32-OpenSSH | as SYSTEM | as a local account |
|---|---|---|
| 9.5.0.0p1-Beta | reset after version exchange | — |
| 8.1.0.0p1-Beta | reset after version exchange | reset, `-y` child killed |
| 7.7.2.0p1-Beta | — | reset *before* version exchange |

Ruled out individually, each by test rather than by argument:

- **Missing DLLs** — `userenv`, `profapi`, `logoncli`, `samcli`, `netapi32`,
  `secur32`, `sspicli`, `authz`, `msv1_0`, `ntdsapi` are all present in the
  PE image.
- **Environment** — setting `ProgramData`, `ALLUSERSPROFILE`, `USERPROFILE`,
  `HOMEDRIVE`, `HOMEPATH` changes nothing.
- **A path containing a space** — the same binary in
  `C:\Program Files\...` works on full Windows.
- **Needing a registered service** — full Windows has no `sshd` service
  either and works.
- **Incomplete account database** — WinPE's SAM has no built-in groups
  (`net user` reports *"The user was successfully created but could not be
  added to the USERS local group"*); creating them by hand does not help.

The same binaries, configuration and paths work on full Windows. It is the
environment the child lands in.

---

## What this repository contains

```
pe-sshd/        the ssh server that works in WinPE (Go)
runas-user/     start a program as a named local user, for PE where
                runas and schtasks cannot (Go)
winpe/          the image build: scripts that produce a bootable,
                ssh-reachable WinPE ISO from Windows installation media
```

### `pe-sshd`

One process. It accepts the connection, does the handshake, authenticates,
and runs the session itself — **no second process, no privilege separation**,
which is the only reason it survives in WinPE. It also stays SYSTEM, so the
session can run tools like `wbadmin` that refuse to work as a limited user.

Supports `exec` (`ssh host "command"`, with the exit status propagated) and
`shell` (an interactive prompt). There is no ConPTY behind it, so the
interactive mode does its own echo and line editing: Enter, backspace and
Ctrl-C work; arrow-key history does not.

### `runas-user`

`LogonUser` + `CreateProcessAsUser` in about a hundred lines, because WinPE
has no `runas` that takes a password and no Task Scheduler. It is what
proved the SYSTEM-versus-user theory wrong, and it is useful on its own
whenever something in PE must not run as SYSTEM.

### `winpe/`

- **`build-winpe.ps1`** — builds the ISO from installation media: exports the
  PE out of `boot.wim`, checks the recovery tools are present *before*
  modifying anything, injects what you ask for, and writes a dual-boot
  (BIOS + UEFI) ISO with `oscdimg`.
- **`restage.ps1`** — re-injects the boot scripts and binaries into an
  already-exported image and rewrites the ISO. Iterating on `startnet.cmd`
  takes about five minutes instead of forty.
- **`swap-openssh.ps1`** — swaps a different Win32-OpenSSH release into the
  image, for reproducing the results above.
- **`fix-targetpath.ps1`** — applies the `Set-TargetPath` fix to an image
  that is already exported.
- **`startnet.cmd`** — what PE runs at boot: network, account, firewall,
  ssh server, and the state printed where you can see it.
- **`sshd_config`** — a minimal config for the Win32-OpenSSH experiments.

---

## Five things that stop a hand-built WinPE before ssh is even the problem

Each of these fails silently or with a message that points somewhere else.
They cost more time than the ssh problem did.

**1. The ISO boots to a prompt nobody presses.** The ADK's `efisys.bin`
stops at *"Press any key to boot from CD or DVD……"*; headless, nobody does,
and the firmware moves on to `BdsDxe: No bootable option or device was
found.` Build unattended media with **`efisys_noprompt.bin`**.

**2. `0xc0000225` is one missing flag.** Exporting the PE with
`dism /Export-Image` without **`/Bootable`** drops the mark that tells the
boot manager which image to load. The result boots as far as the Windows
Boot Manager and stops with `\windows\system32\boot\winload.efi … missing or
contains errors`, which reads like a corrupt image.

**3. The PE refuses its own system root.** Installation-media PE is
configured for Windows Setup:

```
Windows PE cannot start because the actual SYSTEMROOT directory (X:\windows)
is different from the configured one (X:\$windows.~bt\Windows).
```

Fix it with `dism /Image:<mount> /Set-TargetPath:X:\` — and note the
argument is the **deployment root**: DISM appends `\Windows` itself, so
passing `X:\Windows` produces `X:\windows\Windows` and the same refusal.

**4. WinPE runs a firewall.** Correct address, listening server, and every
inbound connection still times out. `wpeutil DisableFirewall`.

**5. A server that looks healthy and listens to nothing.** Win32-OpenSSH's
`sshd` without `-D` tries to detach as it would as a service: the window
stays open, nothing binds port 22, and the client gets a TCP connection that
never produces a banner.

And one about WinPE itself: it ships no `sc.exe`, no `whoami`, and no
PowerShell unless you add the optional component. `startnet.cmd` is batch
for a reason.

---

## Building

Needs the Go toolchain, and for the image, the ADK's `oscdimg` plus Windows
installation media. DISM must run elevated.

```powershell
cd pe-sshd    ; go build -ldflags "-s -w" -o pe-sshd.exe .
cd ..\runas-user ; go build -ldflags "-s -w" -o runas-user.exe .
```

Then build the image, with the media mounted at `D:` and `oscdimg.exe`,
`etfsboot.com` and `efisys_noprompt.bin` copied beside it:

```powershell
.\winpe\build-winpe.ps1 -Media D: -Work C:\winpe -Out C:\winpe\winpe-ssh.iso
```

`build-winpe.ps1` checks for `wbadmin`, `diskpart`, `dism`, `bcdboot` and
`net` in the image and stops if the one you need is absent, rather than
producing media that fails at the moment you need it.

## Using it

`startnet.cmd` runs at boot and prints what it did. The essentials:

```bat
wpeinit
wpeutil InitializeNetwork
netsh interface ipv4 set address name="Ethernet 2" static 192.168.56.25 255.255.255.0
wpeutil DisableFirewall
net user peadmin <password> /add
start "pe-sshd" "X:\Windows\System32\pe-sshd.exe" -addr :22 -user peadmin -pass <password>
```

Then, from anywhere that can reach it:

```console
$ ssh peadmin@192.168.56.25 "wbadmin get versions -backupTarget:C:"
$ ssh peadmin@192.168.56.25        # an interactive prompt
```

## Limitations, stated rather than discovered

- **One account, one password, on the command line.** Anything that can list
  processes can read it.
- **A host key generated at every boot.** Clients cannot pin it; you will
  see a new fingerprint each time. There is nowhere durable to keep one —
  `X:` is a RAM disk.
- **No pty.** Line editing only; programs that expect a console will
  misbehave.
- **No authorisation model.** Whoever has the password gets a SYSTEM shell.

For a RAM disk that exists for twenty minutes on an isolated network those
are the right trades. On anything permanent they are all wrong, and this is
the wrong tool.

## Licence

MIT — see [LICENSE](LICENSE).

`winpe/sshd_config` and the Win32-OpenSSH quotations are from the
[PowerShell/openssh-portable][portable] project, which is under the OpenSSH
licence; they are reproduced here for explanation.

[portable]: https://github.com/PowerShell/openssh-portable
