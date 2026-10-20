# Clipboard image bridge for remote Claude Code sessions -- source from ~/.zshrc.
#
#   clip_et <host> [et args...]   connect with the clipboard tunnelled alongside
#   clip_reap [-f]                report (and with -f, close) orphaned tunnels
#
# Serves the local clipboard on 127.0.0.1:$CLIP_IMAGE_PORT and reverse-tunnels it,
# so Ctrl+V pastes screenshots on the remote. Lives only as long as the connection.

# Report tunnel masters whose session is gone -- and, only with -f, close them.
#
# `ssh -fN` detaches to init, so nothing reaps it: clip_et's own teardown runs
# only when `et` returns. Close the terminal window, quit the terminal app or
# kill the shell, and that master keeps its remote port for the life of the
# host. The range is finite, so leaks do eventually block connecting.
#
# Deliberately NOT called automatically, and it never acts without -f:
#   * an earlier auto-running version also reaped on "control socket missing",
#     which races a tunnel that simply has not finished connecting yet;
#   * closing an ssh nobody asked to close is not this function's decision.
#
# The only signal is the PID embedded in the control path
# (clip-et-<pid>-<rand>.ctl): the shell that ran clip_et. A living PID means
# leave alone, so this can only ever under-reap.
clip_reap() {
    local act=0
    [[ $1 == -f ]] && act=1
    local proc cpath base spid n=0
    for proc in ${(f)"$(pgrep -f 'ControlPath=[^ ]*clip-et-' 2>/dev/null)"}; do
        [[ -n $proc ]] || continue
        [[ $(ps -o comm= -p "$proc" 2>/dev/null) == *ssh ]] || continue
        cpath=$(ps -o command= -p "$proc" 2>/dev/null |
                sed -n 's/.*ControlPath=\([^ ]*\).*/\1/p')
        [[ -n $cpath ]] || continue
        base=${cpath:t}
        spid=${${base#clip-et-}%%-*}
        [[ $spid == <-> ]] || continue
        kill -0 "$spid" 2>/dev/null && continue
        (( n++ ))
        if (( act )); then
            print -r "clip_reap: closing ssh $proc (owner $spid gone)"
            kill "$proc" 2>/dev/null
            rm -f "$cpath"
        else
            print -r "clip_reap: orphan ssh $proc, owner $spid gone"
        fi
    done
    (( n )) || { print -r "clip_reap: no orphaned tunnels"; return 0 }
    (( act )) || print -r "clip_reap: nothing closed -- run 'clip_reap -f' to close them"
}

clip_et() {
    local host="${1:?usage: clip_et <host> [et args...]}"
    shift
    local local_port="${CLIP_IMAGE_PORT:-8377}"
    # The ceiling must match PORT_MAX in the server's xclip shim, which only
    # scans PORT_MIN..PORT_MAX: a port claimed above it is invisible to the shim
    # and paste silently stops working. If something permanently squats the
    # bottom of the range (legacy `et -r` tunnels held by etserver, say), raise
    # CLIP_PORT_MIN past it rather than paying a probe per squatter on every
    # connect.
    local port_min="${CLIP_PORT_MIN:-8377}" port_max="${CLIP_PORT_MAX:-8420}"
    local pid= remote_port= ctl=

    # CLIP_ET_DEBUG=1 clip_et host  ->  where the time actually goes. Off by default.
    zmodload zsh/datetime 2>/dev/null
    local _t0=${EPOCHREALTIME:-0}
    _clip_lap() {
        [[ -n $CLIP_ET_DEBUG ]] || return 0
        printf 'clip_et: %-22s %6.2fs\n' "$1" $(( ${EPOCHREALTIME:-0} - _t0 )) >&2
    }

    # One bridge per machine, shared by every session
    if ! nc -z 127.0.0.1 "$local_port" 2>/dev/null; then
        python3 "$HOME/.local/bin/clip-image-server" \
            >>"$HOME/clip-image-server.log" 2>&1 &
        pid=$!
        local i
        for i in {1..50}; do
            nc -z 127.0.0.1 "$local_port" 2>/dev/null && break
            sleep 0.1
        done
        nc -z 127.0.0.1 "$local_port" 2>/dev/null ||
            print -u2 "clip_et: clipboard bridge failed to start on :$local_port (see ~/clip-image-server.log)"
    fi
    _clip_lap "bridge ready"

    # etserver binds a reverse-tunnel port globally, not per session, so two
    # sessions sharing one port kill each other. Claim a port by BINDING it,
    # never by asking whether it is free: asking and using the answer later is a
    # TOCTOU wide enough to drive the whole handshake through. The answer comes
    # from server state every client is racing to change, so several machines
    # asking at once are all told the same port is free — and etserver's second
    # listen() is a hard abort() (TcpSocketHandler.cpp:156) that kills EVERY
    # session on the host, not just the loser. So the bind IS the test.
    #
    # Probe over ONE multiplexed connection rather than logging in per port:
    # sshd still performs the listen() and reports the failure, so the guarantee
    # is unchanged, but a taken port costs a round trip (~0.3s) instead of a full
    # handshake (~3s). That is not a micro-optimisation — every port below the
    # first free one is held by a live session, so the walk happens on every
    # connect, and at this RTT the login-per-port version took >20s to open a
    # terminal.
    #
    # Call the ssh BINARY, never the bare word. Warp rewrites ssh invocations to
    # reuse its own connection (warpify.ssh.reuse_existing_control_master) and
    # PREPENDS -o ControlMaster=yes -o ControlPath=~/.ssh/<hash> -t. ssh keeps the
    # FIRST value of an option, so its path wins and ours is never created: the
    # probes then address a socket we do not own (hangs for minutes) and -O exit
    # would tear down WARP's master, dropping every other session on it. An
    # absolute path dodges the rewrite whether it is an alias, a function or a
    # PATH shim, since all three only match the bare word.
    local SSH=/usr/bin/ssh
    [[ -x $SSH ]] || SSH=$(whence -p ssh) || SSH=ssh

    # The clipboard is a convenience; it must NEVER gate the terminal. Claim the
    # port in the background and hand off to et immediately, so opening a session
    # costs et's own connect and nothing else — however slow, rewritten or
    # contended the tunnel setup turns out to be. The tunnel attaches a moment
    # into the session; a paste in the first seconds may need one retry, and the
    # shim already refuses rather than guesses when no tunnel is attributable.
    ctl="${TMPDIR:-/tmp}/clip-et-$$-${RANDOM}.ctl"
    local claimer=
    {
        if $SSH -o ControlMaster=yes -o ControlPath="$ctl" \
                -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
                -o ConnectTimeout=10 -o BatchMode=yes \
                -fN "$host" 2>/dev/null && [[ -S $ctl ]]
        then
            _clip_lap "master up"
            local p
            for p in {${port_min}..${port_max}}; do
                if $SSH -O forward -R "${p}:127.0.0.1:${local_port}" \
                        -o ControlPath="$ctl" "$host" 2>/dev/null
                then
                    remote_port=$p
                    break
                fi
            done
            _clip_lap "port ${remote_port:-none} claimed"
            # An idle master with no forward is just a leak
            [[ -n $remote_port ]] || $SSH -O exit -o ControlPath="$ctl" "$host" 2>/dev/null
        fi
    } &!
    claimer=$!   # &! disowns, so zsh never prints a job-control line over the session

    # Deliberately no -r: etserver never listen()s on our behalf, so the abort
    # above is unreachable rather than merely less likely.
    _clip_lap "handing off to et"
    et "$@" "$host"
    local rc=$?

    # Stop a claim still in flight, so a slow or wedged one cannot outlive the
    # session it was for. Killing the subshell does not reap an ssh -fN that has
    # already detached, so give its socket a moment to appear — otherwise a master
    # born just after teardown holds its port for good, and leaked ports are what
    # made this slow in the first place. This runs after et has exited, so the
    # wait is invisible.
    if [[ -n $claimer ]]; then
        kill "$claimer" 2>/dev/null
        local w
        for w in {1..8}; do
            [[ -S $ctl ]] && break
            sleep 0.2
        done
    fi

    # The tunnel still dies with the session. Guarded on the socket being ours:
    # -O exit against a control path we did not create would close someone else's
    # master and take their sessions with it.
    if [[ -n $ctl ]]; then
        [[ -S $ctl ]] && $SSH -O exit -o ControlPath="$ctl" "$host" 2>/dev/null
        # A master whose handshake outlived the wait above would otherwise hold its
        # port for good, and accumulated ports are what made connecting slow to
        # begin with. This control path is unique to this invocation, so it can
        # only ever match our own ssh — never Warp's master or another session's.
        ( sleep 12; pkill -f "ControlPath=$ctl" 2>/dev/null; rm -f "$ctl" ) >/dev/null 2>&1 &!
        rm -f "$ctl"
    fi

    # Stop the bridge only if we started it and no other session is still
    # tunnelling. Match on the ControlPath, not on -R: the forward is now
    # requested over the mux, so it no longer appears in the master's argv and
    # matching it would miss live sessions and kill the bridge under them. If our
    # own master is still winding down we simply leave the bridge up, which is
    # the harmless direction to be wrong in.
    if [[ -n $pid ]] &&
       ! pgrep -f "ControlPath=${TMPDIR:-/tmp}/clip-et-" >/dev/null 2>&1; then
        kill "$pid" 2>/dev/null
    fi
    return $rc
}

alias myserver="clip_et user@host"
