// runas-user -- start a program as a named local user.
//
// WHY THIS EXISTS. Windows PE runs everything as SYSTEM, and Win32-OpenSSH's
// sshd cannot serve a connection when it is SYSTEM. Its own source says why:
// every connection is handed to a child spawned as the user "sshd"
// (SSH_PRIVSEP_USER), and win32_usertoken_utils.c chooses the token like this
//
//	if (!am_system() && (token = generate_sshd_token_as_nonsystem()) != 0)
//		goto done;
//	if ((token = generate_sshd_virtual_token()) == 0)
//		error("... ensure sshd service has TCB privileges");
//
// where the non-SYSTEM branch is simply
//
//	HANDLE generate_sshd_token_as_nonsystem() {
//		HANDLE token = 0;
//		OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS_P, &token);
//		return token;
//	}
//
// -- it hands back its own token and is done. The SYSTEM branch needs the
// virtual account NT SERVICE\sshd, which exists only for a registered service,
// and WinPE's registry has no Task Scheduler and no Secondary Logon to build
// that world with. So the whole problem is "sshd must not be SYSTEM", and the
// whole solution is a program that can start it as somebody else.
//
// WHY NOT runas OR schtasks. Both need services WinPE does not carry:
// seclogon and Schedule are absent from the PE registry, checked rather than
// assumed. LogonUser is an LSA call and needs neither, and SYSTEM already
// holds the privileges CreateProcessAsUser wants.
//
// Built with the Go toolchain on the host, which produces a single
// dependency-free amd64 executable -- the only kind worth putting in a RAM
// disk that has no runtime installed.
//
//	go build -o runas-user.exe .
package main

// ON THE UTF-16 CONVERSION, AND THE CALL THIS NO LONGER USES.
//
// Every string handed to a W-suffixed Windows API has to be a NUL-terminated
// UTF-16 pointer. The Go standard library offers two ways to make one:
//
//	syscall.StringToUTF16Ptr(s)        // deprecated; PANICS if s holds a NUL
//	syscall.UTF16PtrFromString(s)      // returns (*uint16, error)
//
// This program used the first and now uses the second, and the honest reason
// is narrower than it looks. The three strings here arrive as command-line
// arguments, and a Windows command line is itself NUL-terminated, so none of
// them can contain an embedded NUL: the panic the deprecated call is
// deprecated for is unreachable from this program's inputs. Nothing was
// broken and nothing was fixed.
//
// What changed is that the call can now report instead of abort. That is
// worth having for a program whose whole job happens on a machine with no
// installed system and no second console -- and it stops being theoretical
// the moment these strings come from somewhere other than argv, which is one
// small edit away: a credentials file, an answer file, a config read off the
// backup volume.
//
// It is written down because the deprecated form still works, still appears
// in most examples, and is a drop-in if this ever has to move backwards:
// delete the utf16 helper and substitute syscall.StringToUTF16Ptr at its five
// call sites. Tested after the change: go vet clean, bad credentials rejected
// with "The user name or password is incorrect" rather than a panic, and a
// real logon starting a real process (see the lab notes).
import (
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

var (
	advapi32                 = syscall.NewLazyDLL("advapi32.dll")
	procLogonUserW           = advapi32.NewProc("LogonUserW")
	procCreateProcessAsUserW = advapi32.NewProc("CreateProcessAsUserW")
)

const (
	logon32LogonInteractive = 2
	logon32ProviderDefault  = 0
	createNewConsole        = 0x00000010
)

// utf16 converts one argument for a W-suffixed Windows call, naming the
// argument in the error so a failure says which string was wrong.
func utf16(what, s string) *uint16 {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		fmt.Printf("%s is not usable as a Windows string: %v\n", what, err)
		os.Exit(2)
	}
	return p
}

func main() {
	if len(os.Args) < 4 {
		fmt.Println(`usage: runas-user <user> <password> <program> [args...]`)
		os.Exit(2)
	}
	user, password := os.Args[1], os.Args[2]

	var token syscall.Handle
	ok, _, err := procLogonUserW.Call(
		uintptr(unsafe.Pointer(utf16("user", user))),
		uintptr(unsafe.Pointer(utf16("domain", "."))),
		uintptr(unsafe.Pointer(utf16("password", password))),
		logon32LogonInteractive,
		logon32ProviderDefault,
		uintptr(unsafe.Pointer(&token)),
	)
	if ok == 0 {
		fmt.Printf("LogonUser(%s) failed: %v\n", user, err)
		os.Exit(1)
	}
	defer syscall.CloseHandle(token)

	// Quote each argument that contains a space, so a path like
	// "X:\Program Files\OpenSSH\sshd.exe" survives.
	parts := make([]string, 0, len(os.Args)-3)
	for _, a := range os.Args[3:] {
		if strings.ContainsAny(a, " \t") && !strings.HasPrefix(a, `"`) {
			a = `"` + a + `"`
		}
		parts = append(parts, a)
	}
	cmdline := strings.Join(parts, " ")

	si := new(syscall.StartupInfo)
	si.Cb = uint32(unsafe.Sizeof(*si))
	// Without a window station and desktop the new process has nowhere to
	// exist; winsta0\default is the one WinPE has.
	si.Desktop = utf16("desktop", `winsta0\default`)
	pi := new(syscall.ProcessInformation)

	ok, _, err = procCreateProcessAsUserW.Call(
		uintptr(token),
		0, // application name: taken from the command line
		uintptr(unsafe.Pointer(utf16("command line", cmdline))),
		0, 0, 0,
		createNewConsole,
		0, 0,
		uintptr(unsafe.Pointer(si)),
		uintptr(unsafe.Pointer(pi)),
	)
	if ok == 0 {
		fmt.Printf("CreateProcessAsUser failed: %v\n  command: %s\n", err, cmdline)
		os.Exit(1)
	}
	fmt.Printf("started as %s, pid %d: %s\n", user, pi.ProcessId, cmdline)
	syscall.CloseHandle(pi.Thread)
	syscall.CloseHandle(pi.Process)
}
