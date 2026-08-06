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

## Status

Tested with Claude Code 2.1.220 on both ends — macOS client, Ubuntu 24.04 server, over
both Eternal Terminal and OpenSSH. A PNG round-tripped byte-identical across both, and
three concurrent sessions each pulled the same image.

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
