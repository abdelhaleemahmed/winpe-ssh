// pe-sshd -- a small ssh server for a Windows PE recovery environment.
//
// WHY THIS EXISTS, AND WHY IT IS NOT OPENSSH.
//
// Microsoft's Win32-OpenSSH cannot serve a connection inside WinPE. It is not
// a configuration problem and it is not the build: sshd accepts the TCP
// connection, completes the version exchange, and then hands the session to a
// SECOND COPY OF ITSELF, spawned with -y, which dies the instant it starts:
//
//	debug3: spawning "...\sshd.exe" ... -y as user
//	debug2: Network child is on pid 336
//	debug1: monitor_read_log: child log fd closed
//	debug1: Killing privsep child 336
//
// and the client is told "Connection reset by peer". Tested in WinPE against
// three releases -- 7.7.2.0p1, 8.1.0.0p1 and 9.5.0.0p1 -- with sshd running
// as SYSTEM and, via runas-user.exe, as an ordinary local account. All six
// combinations fail the same way. The same binaries, configuration and paths
// work on full Windows, so it is the environment the child lands in.
//
// This server has no child and no privilege separation: one process handles
// the listener, the handshake, authentication and the session. That is the
// whole reason it works where OpenSSH does not. It also means the shell you
// get runs as whoever started it -- SYSTEM in WinPE -- which is what a
// bare-metal recovery needs, since wbadmin will not run as a limited user.
//
// WHAT IT IS NOT. It is not a general-purpose ssh server and must not be
// treated as one: one account, one password, both set on the command line and
// therefore visible to anything that can list processes; a host key generated
// fresh at every boot, so clients cannot pin it; no pty, so interactive
// programs that expect a console will misbehave. For a RAM disk that exists
// for twenty minutes on an isolated lab network that is the right set of
// trades, and every one of them would be wrong on a real machine.
//
//	go build -o pe-sshd.exe .
//	pe-sshd.exe -user peadmin -pass <password> -addr :22
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"

	"golang.org/x/crypto/ssh"
)

func main() {
	addr := flag.String("addr", ":22", "address to listen on")
	user := flag.String("user", "peadmin", "the one account this server accepts")
	pass := flag.String("pass", "", "its password (required)")
	shell := flag.String("shell", "cmd.exe", "program run for a session")
	flag.Parse()
	if *pass == "" {
		fmt.Println("pe-sshd: -pass is required")
		os.Exit(2)
	}
	log.SetFlags(log.Ltime)

	cfg := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, given []byte) (*ssh.Permissions, error) {
			if c.User() == *user && string(given) == *pass {
				log.Printf("auth ok: %s from %s", c.User(), c.RemoteAddr())
				return nil, nil
			}
			log.Printf("auth refused: %s from %s", c.User(), c.RemoteAddr())
			return nil, fmt.Errorf("denied")
		},
	}

	// A host key generated in memory at every boot. There is nowhere durable
	// to keep one -- X: is a RAM disk -- and a key written to the backup
	// volume would outlive the recovery it was made for.
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		log.Fatalf("host key: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		log.Fatalf("host key: %v", err)
	}
	cfg.AddHostKey(signer)
	log.Printf("host key fingerprint: %s", ssh.FingerprintSHA256(signer.PublicKey()))

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen %s: %v", *addr, err)
	}
	log.Printf("listening on %s, user %s, shell %s", *addr, *user, *shell)

	for {
		tcp, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go serve(tcp, cfg, *shell)
	}
}

func serve(tcp net.Conn, cfg *ssh.ServerConfig, shell string) {
	defer tcp.Close()
	conn, chans, reqs, err := ssh.NewServerConn(tcp, cfg)
	if err != nil {
		log.Printf("handshake from %s: %v", tcp.RemoteAddr(), err)
		return
	}
	defer conn.Close()
	log.Printf("connected: %s", conn.RemoteAddr())
	go ssh.DiscardRequests(reqs)

	for nc := range chans {
		if nc.ChannelType() != "session" {
			nc.Reject(ssh.UnknownChannelType, "only session channels")
			continue
		}
		ch, chReqs, err := nc.Accept()
		if err != nil {
			log.Printf("accept channel: %v", err)
			continue
		}
		go session(ch, chReqs, shell)
	}
	log.Printf("disconnected: %s", conn.RemoteAddr())
}

func session(ch ssh.Channel, reqs <-chan *ssh.Request, shell string) {
	defer ch.Close()
	for req := range reqs {
		switch req.Type {
		case "exec":
			// payload is a 4-byte length followed by the command line
			var p struct{ Command string }
			if err := ssh.Unmarshal(req.Payload, &p); err != nil {
				req.Reply(false, nil)
				return
			}
			req.Reply(true, nil)
			run(ch, exec.Command(shell, "/c", p.Command), false)
			return
		case "shell":
			req.Reply(true, nil)
			run(ch, exec.Command(shell), true)
			return
		case "pty-req", "env", "window-change":
			// Accepted and ignored: there is no pty here, and saying no to
			// pty-req makes common clients give up rather than continue.
			req.Reply(true, nil)
		default:
			req.Reply(false, nil)
		}
	}
}

// pipeInteractive does the job a pty would do, for a session that has none.
//
// An interactive client -- PuTTY, or ssh with -t -- sends a bare CR when you
// press Enter and expects the far end to echo what you type. cmd.exe reading
// from a plain pipe wants a full CRLF-terminated line and echoes nothing. Put
// those together and the symptom is a shell that shows its prompt, accepts
// typing, and then does nothing at all: the line never terminates, so `dir`
// is still sitting in the pipe.
//
// So this reads a keystroke at a time, echoes it back, keeps a local line
// buffer, handles backspace, and hands cmd.exe a complete CRLF-terminated
// line only when Enter arrives. It is line editing, not a terminal: no
// arrow-key history, no Ctrl-C into the child, nothing that needs a console
// handle. That is the honest limit of a server with no ConPTY behind it, and
// it is enough to run a recovery.
func pipeInteractive(ch ssh.Channel, stdin io.WriteCloser) {
	defer stdin.Close()
	var line []byte
	buf := make([]byte, 1)
	for {
		n, err := ch.Read(buf)
		if n > 0 {
			switch b := buf[0]; b {
			case '\r', '\n':
				ch.Write([]byte("\r\n"))
				stdin.Write(append(append([]byte{}, line...), '\r', '\n'))
				line = line[:0]
			case 0x7f, 0x08: // DEL or BS
				if len(line) > 0 {
					line = line[:len(line)-1]
					ch.Write([]byte("\b \b"))
				}
			case 0x03: // Ctrl-C: abandon the line, as a console would
				ch.Write([]byte("^C\r\n"))
				line = line[:0]
			default:
				line = append(line, b)
				ch.Write([]byte{b})
			}
		}
		if err != nil {
			return
		}
	}
}

func run(ch ssh.Channel, cmd *exec.Cmd, interactive bool) {
	stdin, err := cmd.StdinPipe()
	if err != nil {
		fmt.Fprintf(ch, "pe-sshd: stdin: %v\n", err)
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Fprintf(ch, "pe-sshd: stdout: %v\n", err)
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		fmt.Fprintf(ch, "pe-sshd: stderr: %v\n", err)
		return
	}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(ch, "pe-sshd: %v\n", err)
		sendExit(ch, 127)
		return
	}
	log.Printf("running: %s", cmd.String())

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(ch, stdout) }()
	go func() { defer wg.Done(); io.Copy(ch.Stderr(), stderr) }()
	if interactive {
		go pipeInteractive(ch, stdin)
	} else {
		// exec: the client is piping data, not typing it, so pass it through
		// untouched -- no echo, no line buffering, no translation.
		go func() { io.Copy(stdin, ch); stdin.Close() }()
	}
	wg.Wait()

	code := 0
	if err := cmd.Wait(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			code = 1
		}
	}
	log.Printf("finished: exit %d", code)
	sendExit(ch, code)
}

func sendExit(ch ssh.Channel, code int) {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint32(payload, uint32(code))
	ch.SendRequest("exit-status", false, payload)
}
