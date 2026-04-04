---
name: humanize-browser
description: Use when automating a browser — navigating pages, scraping content, filling forms, clicking buttons, or taking screenshots. Also use when bot detection is a concern or when you need a persistent browser session across multiple commands.
---

# humanize-browser

## When to Use

- Navigating websites and extracting structured content
- Filling and submitting forms without triggering bot detection
- Scraping data from pages via accessibility snapshot
- Any task requiring a persistent, stealth browser session

## Installation Check

Before using, verify the CLI is available:

```bash
humanize-browser status
```

If the command is not found:

```bash
pipx install git+https://github.com/vvbeliaev/humanize-browser.git
python3 -m camoufox fetch   # downloads the stealth browser binary (one-time)
```

## Configuration File

Create `humanize-browser.json` in your project root to set persistent defaults.
This file is read on every command — no manual setup needed per session.

```json
{
  "profile": "my-profile",
  "headed": false,
  "humanize": true
}
```

| Field      | Default | Description                                                                                               |
| ---------- | ------- | --------------------------------------------------------------------------------------------------------- |
| `profile`  | none    | Behaviour profile to load (mouse curves, typing delays). Path: `~/.humanize-browser/profiles/<name>.json` |
| `headed`   | `false` | Show browser window                                                                                       |
| `humanize` | `true`  | Enable human-like interaction                                                                             |

A global fallback config lives at `~/.humanize-browser/config.json` — same format, lower priority than the project file.

Use `--config <path>` to point at a custom config file explicitly.

## How It Works

Persistent background daemon — browser stays open between commands, auto-starts on first use, persists until `humanize-browser close`.

## Core Workflow

Every automation follows this pattern:

1. **Open**: `humanize-browser open <url>`
2. **Snapshot**: get element refs like `@e1`, `@e2`
3. **Interact**: use refs to click, fill, type
4. **Re-snapshot**: after navigation or DOM changes, always get fresh refs

```bash
humanize-browser open https://example.com
humanize-browser snapshot
# Output:
# [1] heading "Welcome" @e1
# [2] textbox "Email" @e2
# [3] textbox "Password" @e3
# [4] button "Sign In" @e4

humanize-browser fill @e2 "user@example.com"
humanize-browser type @e3 "password"   # human-like delays
humanize-browser click @e4
humanize-browser wait ".dashboard"
humanize-browser snapshot              # re-snapshot after navigation
```

## Essential Commands

```bash
# Navigation
humanize-browser open <url>            # navigate (aliases: goto, navigate)
humanize-browser close                 # close browser and stop daemon

# Snapshot
humanize-browser snapshot              # interactive elements with @eN refs

# Interaction (use @refs from snapshot, or CSS selectors)
humanize-browser click @e1             # click element
humanize-browser type @e2 "text"       # type with per-character human delays
humanize-browser fill @e2 "text"       # instant fill (no delays — for hidden/auto fields)
humanize-browser hover @e1             # hover

# Wait
humanize-browser wait 2000             # wait milliseconds
humanize-browser wait ".selector"      # wait for element to appear

# Capture
humanize-browser screenshot            # screenshot to screenshot.png
humanize-browser screenshot path.png   # screenshot to custom path

# Daemon
humanize-browser status                # check daemon state
```

## type vs fill

| Command | When to use                                                                |
| ------- | -------------------------------------------------------------------------- |
| `type`  | Visible text inputs where human-like timing matters (login, search, forms) |
| `fill`  | Hidden fields, file paths, auto-populated fields, bulk data                |

`type` only adds delays when a behaviour `profile` is active. Without a profile, both commands behave identically in speed.

## Ref Lifecycle

Refs (`@e1`, `@e2`) are invalidated when the page changes. Always re-snapshot after:

- Clicking a link or button that navigates
- Form submissions
- Dynamic content loading (modals, dropdowns, SPAs)

```bash
humanize-browser click @e4             # navigates
humanize-browser snapshot              # MUST re-snapshot before next interaction
humanize-browser click @e1             # use new refs
```

## Output Format

| Situation                           | Output                                            |
| ----------------------------------- | ------------------------------------------------- |
| `snapshot`                          | Accessibility tree text, printed to stdout        |
| `screenshot`                        | File path printed to stdout                       |
| Action commands (click, type, fill) | Empty on success                                  |
| Error                               | `Error: <message>` printed to stderr, exit code 1 |

Use `--json` to get raw `{"success": bool, "data": {...}}`:

```bash
humanize-browser --json snapshot
humanize-browser --json status
```

## Flags

```bash
--headed         show browser window (overrides config)
--no-humanize    disable human-like behaviour for this call only (resets next call)
--config PATH    use a specific config file
--json           output raw JSON
```

## Anti-Detection Notes

- Camoufox patches browser fingerprints (canvas, WebGL, fonts, timezone)
- `geoip=True` aligns browser locale with detected IP location
- playwright-stealth removes automation flags (`navigator.webdriver`, etc.)
- Use `type` (not `fill`) for fields where human-like input matters
- Add `wait` between actions on slow or dynamic pages

## Common Mistakes

**Using stale refs after navigation** — refs are invalidated on every page change. Always re-snapshot after click/submit/navigation before the next interaction.

**Using `fill` instead of `type` on visible form fields** — `fill` bypasses keyboard events; some sites detect this. Use `type` for fields where human input is expected.

**Not waiting for dynamic content** — snapshot before the page finishes loading returns an empty or incomplete tree. Use `wait <selector>` or `wait <ms>` before snapshot on slow/SPA pages.

**Interacting without opening a page** — all commands except `status` require an open page. Always call `open` first.

**Daemon left running between projects** — the daemon uses one shared pid file. If you switch projects with different configs, run `humanize-browser close` to force a fresh start that picks up the new config.

```bash
# Empty snapshot fix
humanize-browser wait 2000 && humanize-browser snapshot

# Stale ref fix
humanize-browser snapshot   # re-snapshot, then use new @eN refs

# Daemon unresponsive fix
humanize-browser close      # next command auto-restarts it
```
