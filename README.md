# Ctrl+V for images in a remote Claude Code session

Paste a screenshot straight into Claude Code running over SSH, instead of saving it,
`scp`-ing it across, and pasting the path.

**[Read the setup guide →](https://neymik.github.io/claude-code-remote-clipboard/)**

## How it works

Claude Code reads a pasted image from the clipboard of the machine it runs on, and on
a headless server there isn't one. But on Linux it shells out to exactly two commands,
checking nothing but their exit codes — no `DISPLAY`, no X connection:

```sh
xclip -selection clipboard -t TARGETS   -o | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"
xclip -selection clipboard -t image/png -o > /tmp/<tempfile>
```

So you don't need a real clipboard on the server. You need a program *named* `xclip`,
earlier in `PATH`, that answers those two calls with the image from your laptop —
fetched over a reverse tunnel you already have open for the SSH session.

```
your machine                              the server
────────────                              ──────────
screenshot → clipboard
      ↓
clip-image-server  ──── reverse tunnel ───→  tunnel port (one per session)
127.0.0.1:8377                                     ↓
                                             xclip shim
                                                   ↓
                                             Claude Code
```

Nothing leaves your machine until you actually press Ctrl+V on the server.

## Files

| File | Where it goes |
|------|---------------|
| [`clip-image-server`](clip-image-server) | your machine, `~/.local/bin/` |
| [`clip_et.zsh`](clip_et.zsh) | your machine, sourced from `~/.zshrc` — `clip_et` connects, `clip_reap` cleans up |
| [`xclip`](xclip) | the server, `/usr/local/bin/`, mode 700 |
| [`index.html`](index.html) | the guide published above |

Both scripts need a shared token pasted in before use — the guide covers it.

## One port per session — claimed by binding, never by asking

A reverse-tunnel port is bound by the `etserver` *daemon*, not by your session. Ask it to
bind a port another client already holds and it does not fail that one request — it
`abort()`s (`TcpSocketHandler.cpp:156`, *"Tried to listen twice on the same port"*) and
every session on the host dies with `Session terminated`.

Checking first does not fix it. Asking which port is free and using the answer a moment
later is a race as wide as the whole handshake, and clients racing each other are all told
the same port is free. So don't ask — **try**: request the forward with
`ssh -O forward -R`, which turns a collision into a harmless non-zero exit, and attach with
a bare `et` (no `-r`) so `etserver` never binds on your behalf.

The probes go over a **single multiplexed connection**, not one login each. `sshd` still
performs the `listen()` and still reports the failure, so the bind is still the test — but
a taken port costs a round trip instead of a full handshake. That matters more than it
sounds: every port below the first free one is held by a live session, so this walk runs on
every connect, and paying a login per port put more than twenty seconds in front of the
terminal on a high-latency link.

And it runs **in the background**. The clipboard is a convenience, so it must never gate the
terminal: `clip_et` hands off to `et` immediately and the tunnel attaches while `et` is still
connecting. Opening a session costs `et`'s own connect and nothing else, no matter how slow
or contended the tunnel setup turns out to be.

## Watch out for terminals that rewrite `ssh`

Warp reuses its own SSH connection (`warpify.ssh.reuse_existing_control_master`) by rewriting
your invocation and **prepending** `-o ControlMaster=yes -o ControlPath=~/.ssh/<hash> -t`.
ssh keeps the *first* value of an option, so Warp's control path wins and yours is never
created. Two things follow, and both bite:

- Your probes address a control socket you do not own.
- `ssh -O exit` on that path closes **Warp's** master — and every session riding on it.

So call the binary by absolute path (`/usr/bin/ssh`), which no alias, function or `PATH` shim
can intercept, and treat `[[ -S $ctl ]]` as the precondition for touching the socket at all.
If it is not there, connect without the bridge rather than close a connection that is not
yours.

The shim then routes each session to *its own* machine's clipboard, identifying the owner
by the peer address of the process holding the tunnel — a fact from the kernel, not
anything a session can set. Where ownership cannot be proved and more than one clipboard
is reachable, it refuses to paste rather than hand over another machine's clipboard.

## Eternal Terminal on a busy server

Lessons from one host carrying many concurrent ET sessions from several machines.

- **`et -x` kills every session you have there, not just stale ones.** It prefixes the
  login with `pkill etterminal -u <user>`, so it takes your live sessions in other tabs
  along with the leftovers. Use it only when you know this is your only session.
- **ET roams; the tunnel does not.** ET survives a closed lid and a changed IP address.
  The `ssh -R` beside it is a plain TCP connection, so a network change kills it, and
  `clip_et` does not bring it back. The session looks fine but paste stops working:
  `xclip -t TARGETS -o` prints nothing. Open a fresh session to get the tunnel back. A
  machine left connected overnight can show every `et` client still attached and no
  tunnel at all.
- **Don't start several clients in the same second without `--logdir`.** `et` 6.2.x
  names its client log after the current second and creates it exclusively. So when a
  script opens several sessions at once, all but one abort with
  `FATAL ... createLogFile` (the errno it prints is wrong). Give each one its own
  directory: `clip_et host --logdir /tmp/et-$RANDOM` (`clip_et` passes extra arguments
  through to `et`).
- **Through a jumphost, spell everything out.** ET reads `ProxyJump` from `~/.ssh/config`,
  then opens TCP to the alias *name* and logs in with the *destination's* user. Pass the
  jump explicitly, and remember `-p` is the destination's etserver port as the jumphost
  sees it:
  `clip_et dest --jumphost user@jump.example.com -p 2023 --terminal-path 'PATH=/opt/homebrew/bin:$PATH etterminal'`.
  `--terminal-path` applies to *both* hops, so a `PATH=` prefix works on a Linux
  jumphost and a Homebrew destination alike, and an absolute path would break one of them.
- **The crash reason is not in the journal.** systemd only records `status=6/ABRT`. The
  `abort()` message is in `etserver-<start time>_<pid>.log` under etserver's
  `logdirectory` (default `/tmp`). That name carries the process's *start* time, so a
  crash is in the log of the process started *before* it:
  `grep -l 'listen twice' /tmp/etserver-*.log`.
- **Testing `et` needs a real pty.** Without a console fd it aborts at
  `TerminalClient.cpp:244`, so a tty-less harness fails for reasons unrelated to whatever
  you are testing. Drive it with `expect`.

## Keeping it healthy

- **End a session with `exit`, not by closing the window.** `clip_et` can only clean up
  its tunnel after `et` returns. If you close the window, quit the terminal app or kill
  the shell, the `ssh -fN` master is left running. It belongs to init and holds its
  remote port for as long as the server stays up.
- **`clip_reap` finds those orphans; `clip_reap -f` closes them.** It only reports unless
  you pass `-f`. Its only signal is the shell PID embedded in the control path. A live PID
  means leave it alone, so it can miss an orphan but never close a live tunnel. It is
  manual on purpose: an automatic version that also reaped on "control socket missing"
  raced tunnels that had not finished connecting.
- **Keep the client's port ceiling equal to the shim's.** The shim scans only
  `PORT_MIN..PORT_MAX` (8377–8420). A `CLIP_PORT_MAX` above that claims ports the shim
  will never look at, and paste stops with no error.
- **Read the server's port table before calling anything a leak.**
  `ss -ltnp '( sport >= :8377 and sport <= :8420 )'`: ports held by `sshd` are
  current-style tunnels, one per live session. Ports held by `etserver` are legacy
  `et -r` tunnels, which clear only when those sessions end. If they squat the bottom
  of the range, set `CLIP_PORT_MIN` above them.
- **`CLIP_ET_DEBUG=1 clip_et host`** prints per-stage timings (bridge, master, port
  claimed, handoff). Measure before you guess.

## Warp's rc hook can hijack an ET session

Warp's "Warpify" setup puts a line in the server's `~/.bashrc` that prints a
`SourcedRcFileForWarp` escape on every interactive shell. On some Warp builds, seeing it
come back over ET makes Warp type its bootstrap into the pane. Warp then also opens a
hidden ssh connection of its own and waits forever on *"Starting shell…"*. The ET session
is alive the whole time; Warp is waiting on a connection that never answers. If your build
does this, keep the hook quiet under ET and leave it on for plain ssh. Under ET the
shell's parent is `etterminal`; under ssh it is `sshd`:

```bash
[[ "$-" == *i* ]] \
  && [[ "$(ps -o comm= -p $PPID 2>/dev/null)" != *etterminal* ]] \
  && printf '\eP$f{"hook": "SourcedRcFileForWarp", ...}\x9c'   # Warp's original line
```

## Persistence: what helped, what didn't

- `tmux` on the server is fine and the shim handles it (it asks tmux which client is
  attached *now*). But don't auto-start it from a login hook to survive `etserver`
  crashes. tmux does not stop the crash, it only lets you re-attach afterwards. Fix the
  crash instead (no `et -r`) and drop the hook.
- A client-side `dtach` around `clip_et` makes sessions survive quitting the terminal app,
  and the server never sees a reconnect. But Warp's blocks stop working through it. Pick
  one.

## Status

Tested with Claude Code 2.1.220 on both ends — macOS client, Ubuntu 24.04 server, over
both Eternal Terminal and OpenSSH. A PNG round-tripped byte-identical across both, and
three concurrent sessions each pulled the same image. In daily use since with `et` 6.2.x
clients against `etserver` 7.0.0, with several sessions open at once.

The client-side clipboard reader has branches for macOS, Linux and Windows. Only the
macOS branch has been run; the other two follow the same shape but are untested.

## Security

While the tunnel is up, anyone with shell access on that server can pull whatever image
is on your clipboard. Fine for a machine you own, bad for a shared one. The token limits
casual access, not someone who can read the shim.

**Between machines**, the shim will not guess. With several people tunnelled to one host,
"use the first port that answers" hands your session someone else's clipboard — a silent
leak of whatever they last copied, which looks only like "my paste didn't update". Each
session is therefore matched to the tunnel whose owning process is connected to *that
session's* client address, read from the kernel rather than from the environment, so a
session cannot claim another machine's tunnel by editing its own variables. Two caveats
worth knowing:

- Ownership is only asserted when the process holding a tunnel serves exactly one client
  address. A legacy `et -r` tunnel is held by `etserver`, which holds every session at
  once, so with two machines connected it is deliberately left unattributed.
- Inside `tmux` a pane keeps the environment of whichever client created the session, so
  the currently attached client is asked instead — otherwise re-attaching from a second
  machine would resolve to the first machine's clipboard.

When ownership cannot be established and more than one clipboard is reachable, the paste
is refused. A missing paste is recoverable; a leaked clipboard is not.
