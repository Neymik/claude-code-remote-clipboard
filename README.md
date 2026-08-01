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

## One port per session

A reverse-tunnel port is bound by the `etserver` *daemon*, not by your session. Point a
second session at a port another one already holds and Eternal Terminal kills it
outright: you get `Session terminated` and no shell at all. Give every session its own
server-side port and keep the client port fixed — the shim finds the live tunnel by
scanning, so it does not care which port it got.

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
