# voice-notify

`voice-notify` sends native Mac notifications through the signed Voice app. It
starts the app without taking focus when needed. The standalone CLI looks for
`/Applications/Voice.app` before asking Launch Services; a CLI embedded in an
app prefers its containing bundle. Both sides authenticate the connection, so
the app and CLI need Apple-issued signatures from the same developer.

Follow the [build and install guide](../README.md#build-and-install) to set up
the toolchain and signing. Then install everything and try a local notification:

```fish
just install
voice-notify --title "Build · Voice" --subtitle "Tests finished" \
    --message "All checks passed." --group voice-build --no-pane
voice-say --notify --notify-title "Build · Voice" \
    --notify-group voice-build "All checks passed."
```

To install only this CLI, run `just install-notify`; `just notify-cli` builds
it without installing. The signed executable goes under
`~/.local/libexec/voice-notify`, with an exec wrapper in `~/.local/bin`.
The app also includes `Voice.app/Contents/MacOS/voice-notify`.

If `configure-push` reports Keychain error `-34018`, the running app lacks a
valid Keychain entitlement or provisioning profile. Complete the
[signing setup](../README.md#build-and-install), run `just install-app`, and
retry configuration. The token stays in the device-bound Keychain; it is not
saved to the older login Keychain as a fallback.
If the build rejects a wildcard profile for missing Enhanced Security, enable
that capability on Voice's App ID and regenerate the provisioning profile.

For persistent alerts, open **System Settings → Notifications → Voice → Alert
Style → Persistent**. The first notification request asks for permission.
Sending the same `--group` again replaces that group's notification.

`--pane %3` records a tmux pane for the click action. The default comes from
`TMUX_PANE`; use `--no-pane` to omit the tmux target or `--tmux-socket PATH` to
choose a server. On a click, Voice finds the pane's current session and the
most recently active client already showing it. It selects that pane and
window, then raises the client's terminal app. If no client shows the session,
Voice only raises the latest client's terminal app. It never switches a client
to another session.

`voice-notify` exits 0 when every requested channel accepts the notification,
64 for invalid arguments, and 1 for delivery or configuration failure. A
successful exit means the request was accepted; it doesn't prove that someone
saw the alert.

## Zed projects

Add `--zed-project PATH` to open or focus a local project when you click the
notification. The path must be an absolute, existing directory on a local
volume. Voice resolves symlinks and records the full path, so two projects
named `dotfiles` aren't treated as the same project.
Install the updated app and CLI together with `just install`; an older Voice
app rejects project-aware requests.

```fish
voice-notify --title "Build · dotfiles" --message "Ready for review." \
    --group dotfiles-build \
    --zed-project /Users/blacktop/Developer/Mine/blacktop/dotfiles --no-pane
```

To include the current tmux pane, omit `--no-pane`. A hook that already resolved
an exact target can pass `--pane %3 --tmux-socket /absolute/path/to/socket`
alongside `--zed-project`. Voice performs the usual tmux selection first, then
asks Zed to open the project. If Zed fails, Voice raises the tmux client's host
app. No phone notification is sent by these examples.

Voice uses the running Zed installation. When Zed is closed, it prefers
`/Applications/Zed.app`, then checks registered Stable, Preview, Nightly, and
Dev builds in that order. It invokes that app's bundled CLI with `--existing`.
In the
[audited Zed 1.22.0 implementation](https://github.com/zed-industries/zed/blob/v1.22.0/crates/zed/src/zed/open_listener.rs#L791),
this reuses a project by full path or opens it in the current window. Zed's
public CLI cannot enumerate project roots, choose a native window by ID, or
reveal an existing terminal tab by PID. Multiple project windows are supported;
if the exact same project is open more than once, Zed chooses which copy to
focus. Voice still refuses to choose between different running Zed installations.
On failure, it shows a local error notification and retains the tmux host-app
fallback. A hidden terminal tab may need to be selected manually.

## With voice-say

`voice-say --notify` posts a short preview once it acquires the speech lock.
Skipped speech posts nothing. Notification delivery runs alongside speech,
and the command waits for its result after releasing the lock. Use
`--notify-title`, `--notify-subtitle`, `--notify-message`, `--notify-group`,
`--notify-pane`, `--notify-no-pane`, `--notify-tmux-socket`, and
`--notify-zed-project` to override the notification fields. A delivery failure
is printed without interrupting speech, then the command exits nonzero.

## Phone notifications

Phone push uses [ntfy](https://docs.ntfy.sh/), which you can self-host. Install
the [ntfy iOS app](https://docs.ntfy.sh/subscribe/phone/), create a private topic
with authenticated read/write access, and subscribe to it. Then save the
server, topic, and access token in Voice:

```fish
voice-notify configure-push --server https://ntfy.example.com \
    --topic private-agent-alerts
voice-notify --title "Build · Voice" --message "Ready for review." \
    --group voice-build --no-pane --push
```

`configure-push` asks for the token without echoing it. For automation, pass
`--token-stdin` and pipe one token line. Voice stores the destination and token
together in its device-bound Keychain. You can override them with
`VOICE_NOTIFY_NTFY_SERVER`, `VOICE_NOTIFY_NTFY_TOPIC`, and
`VOICE_NOTIFY_NTFY_TOKEN`. Changing the server requires an explicit token.

Phone delivery only happens with `--push` or `voice-say --notify --notify-push`.
The title is unchanged, and the subtitle goes above the message. If push
fails, an accepted Mac notification stays in place. The ntfy provider controls
its own retention, and self-hosted iOS setups may use an
[upstream relay and Apple's push service](https://docs.ntfy.sh/config/#ios-instant-notifications).
Read the [privacy details](privacy.md) before enabling it.
