# MoorTime (UE4SS Mod for DREADMOOR)

MoorTime is a UE4SS Lua mod that lets you control DREADMOOR in-game time speed with separate **day** and **night** multipliers, runtime console commands, and a HUD clock/notification overlay.

## Features

- Separate day/night time scaling
- Runtime scaling loop (works even when direct config-struct mutation is unavailable)
- Console commands for live tuning
- Config persistence when changing multipliers via console
- HUD in-game clock (`HH:MM`)
- Optional HUD toast on multiplier changes

## Requirements

- DREADMOOR (Windows)
- UE4SS installed and working

## Installation

1. Copy this mod folder to:
   - `Dreadmoor\Binaries\Win64\ue4ss\Mods\MoorTime`
2. Ensure the mod is enabled via UE4SS (`enabled.txt` / `mods.txt` flow used by your setup).
3. Launch the game.
4. Confirm startup in `UE4SS.log` (look for `[Lua] [MoorTime] Config loaded...`).

## Console Commands

- `drd_time_set <multiplier>`
  - Sets both day and night multipliers.
- `drd_time_set_day <multiplier>`
  - Sets day-only multiplier.
- `drd_time_set_night <multiplier>`
  - Sets night-only multiplier.
- `drd_time_get`
  - Logs current state and game time.
- `drd_time_validate`
  - Runs validation/enforcement diagnostics.
- `drd_time_reset`
  - Resets both multipliers to `1.0`.

> Valid multiplier range: `0.01` to `100.0`.

## Configuration

Edit `config.lua`:

- `default_multiplier` (optional convenience when day/night are equal)
- `day_multiplier`
- `night_multiplier`
- `log_interval_ms`
- `runtime_scale_tick_ms`
- `hud_time_font_size`
- `hud_time_font_object_path` (optional)
- `hud_multiplier_toast_enabled`
- `hud_multiplier_toast_ms`
- `hud_multiplier_toast_show_value`

### Font path format

Use Unreal object paths, for example:

`/Game/Dreadmoor/UI/Fonts/Font_OldSoviet.Font_OldSoviet`

## Notes / Limitations

- In this game/runtime, `DA_GD_Gametime.ConfigData[1]` may be an `InstancedStruct`, so direct field mutation is not always available through UE4SS Lua bindings.
- MoorTime compensates with runtime `SetGameTime` scaling and subsystem target enforcement.
- Some builds expose subsystem speed as effectively write-only; `drd_time_validate` logs this explicitly.
