# Operator Runbook — "Audio went silent / nothing is transcribing"

> One-page triage for the #1 support symptom. Every signal below is real and code-grounded
> (`file:line` in [../../ARCHITECTURE.md](../../ARCHITECTURE.md) §4 and §6). Date: 2026-05-30 (v2.7.0).

## 0. First, read the app's own signals

| Signal | Where to look | Meaning |
|---|---|---|
| **STT status pill** (4 states) | overlay / interface | `awaiting-audio` = started, no verified audio yet ("Listening for audio…"); `connected` = audio + socket OK; `reconnecting` = socket dropped, backing off; `failed` = provider gave up |
| **Banner** | top of overlay | Renderer shows `systemAudioWarning.message` **verbatim** — read it; it names the cause |
| **Level bars** | Settings → Audio tab | Mic bar (green) + System bar (blue) move with real audio. System bar amber = Screen Recording denied |
| **Debug log** | `~/Documents/natively_debug.log` (Win: `%USERPROFILE%\Documents\natively_debug.log`) | Main + renderer console, key-redacted, rotates at 10 MB (`.log.1`). Set **`verboseLogging`** in settings for native-loader detail |

## 1. Triage decision tree

```mermaid
flowchart TD
    A["Audio silent / not transcribing"] --> B{STT status pill?}
    B -->|"failed"| F["Provider gave up: auth/quota/max-retries.<br/>→ verify API key + quota; switch provider; restart meeting"]
    B -->|"reconnecting"| R["Socket drops, backing off (see §3).<br/>→ check network/DNS/VPN; it self-recovers when stable 5s"]
    B -->|"connected, but no text"| G{Level bars moving? (Settings→Audio)}
    B -->|"awaiting-audio (stuck)"| C{Which channel is dead?}
    C -->|"mic / 'user'"| MIC["Mic muted at OS or wrong device.<br/>Win: Settings→Privacy→Microphone. mac: re-grant Microphone"]
    C -->|"system / 'interviewer'"| SYS{Banner text?}
    SYS -->|"screen-recording-revoked-rebuild (mac)"| TCC["macOS TCC broke after update (cdhash changed).<br/>→ System Settings→Privacy→Screen Recording: toggle Natively OFF then ON, restart"]
    SYS -->|"system-audio-permission-denied"| PERM["Screen Recording never granted (mac).<br/>→ grant it; Windows has no such permission"]
    SYS -->|"system-audio-stuck (~12s no chunks)"| STUCK["Output device changed (AirPods/HFP / BlackHole / HDMI).<br/>→ app rebuilds capture; re-select output or restart meeting"]
    SYS -->|"no banner, just silence"| NONE["STT provider = 'none' (silent-null) or key missing.<br/>→ Settings→Audio: confirm provider + key are set"]
    G -->|no| NATIVE{Native module loaded?}
    G -->|yes| NONE
    NATIVE -->|"dev build / no .node"| NB["loadNativeModule()=null → empty device list, no capture.<br/>→ run npm run build:native (dev) or reinstall the official app"]
    NATIVE -->|loaded| NONE
```

## 2. Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| Mic bar dead, system bar fine | Mic muted at OS / wrong input device / mic permission | Unmute; pick device in Settings → Audio; Win: Settings→Privacy→Microphone; mac: re-grant Microphone |
| System bar dead/amber (mac) | Screen Recording denied **or** revoked-after-update (TCC binds to cdhash; ad-hoc signing changes it every update) | Settings→Privacy→**Screen Recording**: toggle Natively off/on, relaunch. Use the in-app **Repair Permissions** button |
| Both bars move, **no transcript** | STT provider misconfig (`sttProvider='none'` with a key present → `createSTTProvider()` returns null, **zero logs**) | Settings → Audio: re-select provider + confirm key. (Newer builds self-heal `none`→`natively`) |
| Transcript stalls mid-meeting, `reconnecting` | WS dropped / DNS flap / VPN / sleep | Wait — capped backoff (1–30 s) auto-reconnects; buffer holds ~10 s. Check network/VPN/DNS |
| `failed` after repeated retries | Auth (bad key) / quota exhausted / max attempts (10) | Fix key or quota; switch STT provider; restart meeting |
| False "stuck" right after a **short** meeting | watchdog not disarmed before stop (legacy bug, fixed) | Update to current build |
| "system-audio-stuck" after plugging AirPods/headphones | Default output device changed; capture rebuilds on the new device | Let it recover (~1–2 s) or restart meeting; re-select output |
| Nothing works in a **dev clone** | Native module not built (`npm install` does **not** build it) | `npm run build:native`, then `npm start` |

## 3. How reconnect behaves (so you know "wait" vs "act")

- Drop → **capped exponential backoff** (base 1–1.5 s, cap 30 s, ±20 % jitter); audio is buffered up to ~10 s.
- DNS errors (`ENOTFOUND`/`EAI_AGAIN`) → fixed **10 s** retry (doesn't burn backoff).
- Backoff resets **only after 5 s of stable connection** (prevents 1006 storms).
- **Auth/quota errors are terminal** → status goes `failed`; reconnect will NOT fix it — fix the key/quota.
- There is **no automatic switch to a different provider** mid-meeting; only same-provider reconnect.

## 4. Platform notes

- **macOS:** system-audio capture needs **Screen Recording** (TCC); mic needs **Microphone**. The common
  "I granted it but it stopped working" case is the **cdhash/DR change after an update** — re-grant.
  Dev bypass: `NATIVELY_DEV_BYPASS_SCREEN_TCC=1`.
- **Windows:** no Screen Recording permission exists; mic is prompted on first meeting
  (Settings → Privacy → Microphone). System audio = **WASAPI loopback on the default output device** — if
  meeting audio is routed elsewhere, capture may not follow it.
- **Linux:** system audio unsupported (capture stub errors); mic only.

## 5. What to capture for escalation

1. Platform + version; STT provider + LLM provider.
2. The exact **banner text** and the **STT status** when it failed.
3. `~/Documents/natively_debug.log` (already key-redacted) — last ~200 lines around the failure.
4. Did Settings → Audio **level bars** move? Mic? System?
5. Dev only: did `npm run build:native` succeed and produce a `.node`?
