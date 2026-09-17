# ShakaPachi

**English** | [日本語](README.ja.md)

A window switcher for macOS. Hold Cmd and press Tab to pick a window, then
release Cmd to activate it.

Website: <https://senchan-company.com/en/shakapachi/>

## Features

- App icon, window title, and a live preview of the selection
- Display Unit: *Window* for a flat list, *App* to step between apps and expand one into up to three previews
- Sort Order: most recently used, by app, or by recently used app
- Trigger: Command, Option, or Control, with Tab or grave
- Raise on hover: rest the pointer on a window for 0.4s and it comes to the front (off by default)
- Menu bar resident, no Dock icon
- Themes, accent colors, usage stats

Defaults: Cmd+Tab, flat list, most recently used, preview on, current Space only.

## Requirements

- macOS 13 Ventura or later
- Accessibility permission (event tap, window raising)
- Screen Recording permission (window titles, live preview)

## Build

```
make run
```

Builds, signs, and launches `ShakaPachi.app`.

## Architecture

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## License

[GPL-3.0](LICENSE)
