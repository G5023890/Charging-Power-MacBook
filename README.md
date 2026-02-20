# Charging Power Menu Bar (macOS)

Current release: `1.0`

A lightweight macOS menu bar app that shows:
- current charging power (`W`) or power source status (`AC`);
- current battery charge (`%`);
- `Maximum Capacity` and `Condition` in the dropdown menu.

## Features

- Battery icon in the menu bar with 25% level gradations.
- Reduced status text size (about 10%) for cleaner menu bar layout.
- `Launch at Login` toggle.
- Manual refresh via `Update now`.

## Data Refresh Behavior

The app uses different polling intervals to reduce overhead:
- on AC power: fast polling every `2` seconds (for charging power);
- on battery: polling every `20` seconds;
- battery percentage (`%`) refreshes every `20` seconds;
- `Maximum Capacity` and `Condition` refresh only:
  - on app startup;
  - when `Update now` is clicked.

## Requirements

- macOS 13+;
- Xcode Command Line Tools;
- Swift (Swift Package Manager).

## Build and Run (local)

```bash
swift build
swift run
```

## Build and Install `.app`

Use the project script:

```bash
./scripts/build_and_install_app.sh
```

After the script finishes:
- build output: `dist/PowerApp.app`;
- installed app: `/Applications/PowerApp.app`.

## Project Structure

- `Sources/ChargingPowerMenuBar/ChargingPowerMenuBar.swift` — main app logic.
- `scripts/build_and_install_app.sh` — build, sign, and install script.
- `Assets/` — app icon assets (`AppIcon.icns`, `AppIcon.iconset`).

## Notes

- If you update app icons, run the build/install script again.
- Use `Update now` to refresh `Maximum Capacity` and `Condition` without restart.

## License

`Apache-2.0`. See `LICENSE`.
