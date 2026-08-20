# cgm-statusline

Dexcom CGM glucose, trend arrow, and a coloured sparkline in your
[Claude Code](https://code.claude.com) status line.

```
ctin · ⎇ main · ⚕ 116 → ▅▅▄▄▃▃▄▄▄▄▄▄ 12:13 (1m)
```

Folder, git branch, current glucose, trend arrow, 1–3h sparkline, reading time,
and age. The value is coloured by range; each sparkline bar is coloured by *its
own* reading, so a low two hours ago stays visibly red while you're green now.

> **Not a medical device.** This is a convenience readout. It inherits Dexcom
> Share's ~5 minute delay, and it stops updating when your laptop sleeps or the
> phone stops uploading. Your CGM app and receiver are what alarm on lows — do
> not let a status bar displace them, and do not dose from it.

## How it works

Two pieces, deliberately separated:

- **`cgm-daemon.py`** — a long-lived poller. Logs in to Dexcom Share once,
  fetches the last ~3h of readings, pre-renders the sparklines, and writes a
  small JSON cache. Sleeps until the next reading is actually due.
- **`statusline.sh`** — reads that cache and prints a line. **No network, no
  rendering.** It runs on every message, so it stays around 30ms.

That split is not premature optimisation. Claude Code re-runs the status line on
every assistant message and cancels the in-flight script when a new one starts —
a network call there would flicker, and it would hammer Share with logins for
data that only changes every 5 minutes.

## Install

Requires macOS (Keychain + launchd), Python 3.9+, `jq`, and a Dexcom G6/G7/ONE+
with **Share enabled and at least one follower**.

```bash
git clone https://github.com/ygolde/cgm-statusline ~/.claude/cgm
cd ~/.claude/cgm
./install.sh          # venv + pydexcom, launchd agent, Claude Code settings
$EDITOR config.json   # username, region: us | ous | jp
./setup.sh            # password -> Keychain, test login, start the poller
```

`setup.sh` needs a real terminal (it prompts for the password). If credentials
are already stored, `./verify-start.sh` is non-interactive and safe to run from
Claude Code's `!` bash mode.

Use **his/your Dexcom account** — the *sharer's*, not a Follow account. Follow
logins cannot authenticate as a publisher.

## Choosing a layout

Out of the box it rotates through the layouts once a minute, labelling each one,
so you can pick by living with them:

```bash
./cgm-style.sh 1h       # or 2h, 3h, 2line, none, rotate
```

| style | width | shows |
|---|---|---|
| `none` | – | value, arrow, time |
| `1h` | 12 chars | one hour of history |
| `2h` | 24 chars | two hours |
| `3h` | 36 chars | three hours |
| `2line` | second row | 3h trace on its own row |

## Design notes

Three decisions that are load-bearing, each of which looked fine until it was
rendered against real data:

**Adaptive scale, anchored to the target band.** Auto-scaling min→max turns a
flat, healthy 98–136 morning into a cliff face — visually alarming, medically
meaningless. A fixed 40–300 scale is honest but flatlines everything, because
8 block levels over 260 mg/dL puts a whole good day in one level. So the scale
anchors on 70–180 and expands only for genuine excursions: height means the same
thing day to day, and a real swing looks like one.

**Gaps are binned by timestamp, not list position.** A sensor dropout renders as
dim `·` in the correct slot. Otherwise the axis silently compresses and 12
characters quietly stop meaning one hour.

**The axis anchors on the newest reading, not on `now`.** Anchoring on `now`
leaves the final slot permanently empty — the latest reading is always up to 5
minutes old — which draws a phantom dropout on every single render.

Staleness is handled the same way: past 15 minutes the whole segment dims and
shows its age, and past an hour it refuses to print a number at all, showing
`⚕ no data · last 11:00 (1h15m)`. A stale number displayed confidently is worse
than no number.

## Security

- The password goes to the **macOS Keychain** via `security`, which prompts for
  it — never a file, never a command argument (so never visible in `ps`), never
  shell history.
- `config.json` holds only a username and region, is `chmod 600`, and is
  gitignored along with the reading cache and logs.
- Auth failures back off 5m → 15m → 30m → 1h. A tight retry loop on a bad
  password triggers `SSO_AuthenticateMaxAttemptsExceeded`, which locks the
  account and would break the *real* Follow alerts. That is the failure this
  guards against.
- The only dependency is [`pydexcom`](https://github.com/gagebenne/pydexcom)
  (which itself depends only on `requests`), pinned to `0.5.1`. Its published
  wheel is byte-identical to the GitHub tag and carries a Sigstore attestation
  binding it to the maintainer's CI. Its entire network surface is three
  Dexcom Share endpoints.

## Credits

Glucose data via [pydexcom](https://github.com/gagebenne/pydexcom) by Gage Benne.

## License

MIT
