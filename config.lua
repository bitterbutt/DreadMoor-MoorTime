-- MoorTime config
-- Multipliers affect in-game time progression (1.0 = default speed).
-- Runtime changes from console commands are persisted to this file.
return {
    -- Time scaling
    default_multiplier = 0.5000,
    day_multiplier = 0.5000,
    night_multiplier = 1.0000,
    log_interval_ms = 30000,
    runtime_scale_tick_ms = 16,

    -- HUD clock styling
    hud_time_font_size = 12,
    -- Optional font object path. Leave empty to use widget default.
    -- Example: "/Game/Dreadmoor/UI/Fonts/Font_OldSoviet.Font_OldSoviet"
    hud_time_font_object_path = "",

    -- HUD toast on multiplier changes
    hud_multiplier_toast_enabled = true,
    hud_multiplier_toast_ms = 5000,
    hud_multiplier_toast_show_value = true,
}
