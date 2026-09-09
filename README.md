# Opencode Prompt Popper

Your premade prompts, one click away — everywhere. A Windows tray app with a
searchable popup + global hotkeys that pastes any prompt into whatever app is
focused (Opencode Desktop included), plus native Opencode slash commands and
agent tools so the same prompts work **inside** Desktop sessions too.

Personal tool, open sourced. No telemetry, no network except GitHub sync.

## What you get

| Where | How |
|---|---|
| Any app (Opencode Desktop input, browser, chat) | Tray icon popup, or `Ctrl+Alt+1..8`, or `Ctrl+Alt+P` |
| Inside Opencode Desktop / TUI / web | Slash commands, one per prompt (21 total: `/pp-go`, `/pp-fix`, …) |
| For the agent itself | Tools `pp_list` / `pp_get` ("use the pp-fix prompt on these errors") |
| On the go (phone) | Edit `prompts.json` on github.com → tray right-click **Sync from GitHub** |

## Install (Windows)

```powershell
git clone https://github.com/MaximKonovalovDev/opencode-prompt-popper.git
cd opencode-prompt-popper
pwsh -NoProfile -STA -File install-global.ps1
```

This copies the app to `~/.config/opencode/prompt-popper/`, writes the
`/pp-*` commands, installs the plugin, adds a Startup shortcut, and starts
the tray. Look near the clock for the dark `>_` icon.

## Daily use

1. Click into the Opencode Desktop input (or any text box).
2. Left-click the tray icon, type a few letters, hit Enter — or press `Ctrl+Alt+2`.
3. The prompt is pasted and Enter is pressed for you.

Right-click the tray icon for the full menu: all prompts, sync, reload,
edit, log, restart, quit.

## Edit on the go

1. Open this repo on your phone (GitHub mobile app or browser).
2. Edit `prompts.json`, commit.
3. Back at the PC: tray right-click → **Sync from GitHub**.
4. Done — popup, hotkeys, and agent tools update instantly. Your old file is
   kept as `prompts.json.backup-<timestamp>` and the tray logs to
   `prompt-popper.log`.

First 8 prompts get `Ctrl+Alt+1..8`. Extra prompts are search-only in the
popup but still work as slash commands and agent tools. Omit `enter` on a
prompt to use the default in `settings.pressEnterByDefault`.

## Files

- `prompt-popper.ps1` — the tray app (built-in Windows Forms only).
- `prompts.json` — the prompts + settings (`syncRepo`, `syncOnStart`).
- `plugin/prompt-popper.mjs` — Opencode plugin (`pp_list`, `pp_get`).
- `install-global.ps1` / `uninstall-global.ps1` / `start-popper.cmd`.
- `icon.ico` — tray icon (`make-icon.py` regenerates it).

## Uninstall

```powershell
pwsh -NoProfile -File uninstall-global.ps1
```

Kills the tray, removes the Startup link, commands, and plugin. Your prompts
are backed up first.

## License

MIT — see `LICENSE`.
