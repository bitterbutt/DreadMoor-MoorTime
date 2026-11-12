local UEHelpers = require("UEHelpers")

local DAY_MULTIPLIER = 0.50
local NIGHT_MULTIPLIER = 1.00
local ACTIVE_MULTIPLIER = 0.50
local TIME_INPUT_MODE = "multiplier"
local MIN_MULTIPLIER = 0.01
local MAX_MULTIPLIER = 100.0
local MULTIPLIER_TOLERANCE = 0.0001
local LOG_INTERVAL_MS = 30000
local SCALE_TICK_MS = 33
local HUD_TIME_FONT_SIZE = 12
local HUD_TIME_FONT_OBJECT_PATH = "/Game/Dreadmoor/UI/Fonts/Font_OldSoviet.Font_OldSoviet"
local HUD_TIME_SHADOW_ALPHA = 0.85
local HUD_TIME_SHADOW_OFFSET_X = 1.0
local HUD_TIME_SHADOW_OFFSET_Y = 1.0
local HUD_MULTIPLIER_TOAST_ENABLED = true
local HUD_MULTIPLIER_TOAST_MS = 2200
local HUD_MULTIPLIER_TOAST_SHOW_VALUE = true
local PREFERRED_CONFIG_WRITE_PATH = "Mods\\MoorTime\\config.lua"
local CONFIG_PATHS = {
    "Mods\\MoorTime\\config.lua",
    "ue4ss\\Mods\\MoorTime\\config.lua",
    "Dreadmoor\\Binaries\\Win64\\ue4ss\\Mods\\MoorTime\\config.lua",
}

local GAMETIME_ASSET_STATIC_PATHS = {
    "/Game/Dreadmoor/Data/Configs/DA_GD_Gametime.DA_GD_Gametime",
}
local GAMETIME_ASSET_LOAD_PATHS = {
    "/Game/Dreadmoor/Data/Configs/DA_GD_Gametime",
    "/Game/Dreadmoor/Data/Configs/DA_GD_Gametime.DA_GD_Gametime",
}
local DRD_GAMEPLAY_TIME_SUBSYSTEM_CLASS_PATH = "/Script/Dreadmoor.DrdGameplayTimeSubsystem"
local SUBSYSTEM_BLUEPRINT_LIBRARY_PATH = "/Script/Engine.Default__SubsystemBlueprintLibrary"

local State = {
    GametimeAsset = CreateInvalidObject(),
    SubsystemClass = CreateInvalidObject(),
    SubsystemBlueprintLibrary = CreateInvalidObject(),
    AssetResolveLogged = false,
    InstancedStructAccessLogged = false,
    OnInitializeHooked = false,
    RuntimeScaleWriteFailedLogged = false,
    LastObservedGameTicks = nil,
    StatusAccumulatorMs = 0,
    LastIsDay = nil,
    ConfigPath = nil,
    CanUseConfigContainer = true,
    ScaleLoopHandle = nil,
    HudTimeTextWidget = CreateInvalidObject(),
    HudTimeWidgetResolved = false,
    HudTimeLastLabel = nil,
    HudTimeVisibilityFailedLogged = false,
    HudTimeSetTextFailedLogged = false,
    HudTimeStyleApplied = false,
    HudTimeStyleFailedLogged = false,
    MultiplierDriftActive = false,
    LastMultiplierDriftSignature = nil,
    SubsystemSpeedUnreadableLogged = false,
    ScaleLoopStarted = false,
    ScaleLoopTickCount = 0,
    LastScaleLoopWallSeconds = nil,
    ScaleLoopStallLogged = false,
    LastSetGameTimeTicks = nil,
    RuntimeSetGameTimeIneffectiveLogged = false,
    HudToastText = nil,
    HudToastRemainingMs = 0,
}

local function Log(Message)
    print(string.format("[MoorTime] %s\n", Message))
end

local function ClampMultiplier(Value, Label)
    if type(Value) ~= "number" then
        Log(string.format("Invalid %s '%s'. Must be a number.", Label, tostring(Value)))
        return nil
    end

    local clamped = Value
    if clamped < MIN_MULTIPLIER then
        clamped = MIN_MULTIPLIER
    elseif clamped > MAX_MULTIPLIER then
        clamped = MAX_MULTIPLIER
    end

    if clamped ~= Value then
        Log(string.format(
            "%s %.4f clamped to %.4f (allowed range %.2f..%.2f).",
            Label,
            Value,
            clamped,
            MIN_MULTIPLIER,
            MAX_MULTIPLIER
        ))
    end

    return clamped
end

local function ClampInputMode(Value)
    if Value == "factor" then
        return "factor"
    end
    return "multiplier"
end

local function MultiplierToLengthFactor(Multiplier)
    if type(Multiplier) ~= "number" or Multiplier <= 0 then
        return 1.0
    end
    return 1.0 / Multiplier
end

local function ConvertLengthFactorToMultiplier(Factor, Label)
    if type(Factor) ~= "number" then
        Log(string.format("Invalid %s '%s'. Must be a number.", Label, tostring(Factor)))
        return nil
    end
    if Factor <= 0 then
        Log(string.format("Invalid %s '%.4f'. Must be > 0.", Label, Factor))
        return nil
    end

    local multiplier = 1.0 / Factor
    local clamped = ClampMultiplier(multiplier, Label)
    if not clamped then
        return nil
    end

    Log(string.format("%s %.4f -> multiplier %.4f", Label, Factor, clamped))
    return clamped
end

local function PersistConfig()
    local configPath = State.ConfigPath or PREFERRED_CONFIG_WRITE_PATH

    local file, openErr = io.open(configPath, "w")
    if not file then
        Log(string.format("Failed to open config for write '%s': %s", configPath, tostring(openErr)))
        return false
    end

    local lines = {
        "-- MoorTime config",
        "-- Multipliers affect in-game time progression (1.0 = default speed).",
        "-- Factors control desired day/night length (2.0 = twice as long, 0.5 = half as long).",
        "-- Runtime changes from console commands are persisted to this file.",
        "return {",
        "    -- Input mode: \"multiplier\" or \"factor\"",
        string.format("    time_input_mode = %q,", ClampInputMode(TIME_INPUT_MODE)),
        "",
        "    -- Time scaling",
    }
    if DAY_MULTIPLIER == NIGHT_MULTIPLIER then
        table.insert(lines, string.format("    default_multiplier = %.4f,", DAY_MULTIPLIER))
    end
    table.insert(lines, string.format("    day_multiplier = %.4f,", DAY_MULTIPLIER))
    table.insert(lines, string.format("    night_multiplier = %.4f,", NIGHT_MULTIPLIER))
    table.insert(lines, "")
    table.insert(lines, "    -- Length factors (derived from multipliers, optional for editing)")
    if DAY_MULTIPLIER == NIGHT_MULTIPLIER then
        table.insert(lines, string.format("    default_length_factor = %.4f,", MultiplierToLengthFactor(DAY_MULTIPLIER)))
    end
    table.insert(lines, string.format("    day_length_factor = %.4f,", MultiplierToLengthFactor(DAY_MULTIPLIER)))
    table.insert(lines, string.format("    night_length_factor = %.4f,", MultiplierToLengthFactor(NIGHT_MULTIPLIER)))
    table.insert(lines, string.format("    log_interval_ms = %d,", LOG_INTERVAL_MS))
    table.insert(lines, string.format("    runtime_scale_tick_ms = %d,", SCALE_TICK_MS))
    table.insert(lines, "")
    table.insert(lines, "    -- HUD clock styling")
    table.insert(lines, string.format("    hud_time_font_size = %d,", HUD_TIME_FONT_SIZE))
    table.insert(lines, "    -- Optional font object path. Leave empty to use widget default.")
    table.insert(lines, "    -- Example: \"/Game/Dreadmoor/UI/Fonts/Font_OldSoviet.Font_OldSoviet\"")
    if HUD_TIME_FONT_OBJECT_PATH and HUD_TIME_FONT_OBJECT_PATH ~= "" then
        table.insert(lines, string.format("    hud_time_font_object_path = %q,", HUD_TIME_FONT_OBJECT_PATH))
    else
        table.insert(lines, "    hud_time_font_object_path = \"\",")
    end
    table.insert(lines, "")
    table.insert(lines, "    -- HUD toast on multiplier changes")
    table.insert(lines, string.format("    hud_multiplier_toast_enabled = %s,", tostring(HUD_MULTIPLIER_TOAST_ENABLED)))
    table.insert(lines, string.format("    hud_multiplier_toast_ms = %d,", HUD_MULTIPLIER_TOAST_MS))
    table.insert(lines,
        string.format("    hud_multiplier_toast_show_value = %s,", tostring(HUD_MULTIPLIER_TOAST_SHOW_VALUE)))
    table.insert(lines, "}")
    table.insert(lines, "")
    local configText = table.concat(lines, "\n")

    local okWrite, writeErr = pcall(function()
        file:write(configText)
        file:flush()
        file:close()
    end)

    if not okWrite then
        Log(string.format("Failed writing config '%s': %s", configPath, tostring(writeErr)))
        return false
    end

    State.ConfigPath = configPath
    Log(string.format("Saved config to '%s'.", configPath))
    return true
end

local function LoadConfig()
    local loaded = nil
    local loadedPath = nil

    for _, path in ipairs(CONFIG_PATHS) do
        local chunk, loadErr = loadfile(path)
        if chunk then
            local ok, result = pcall(chunk)
            if ok and type(result) == "table" then
                loaded = result
                loadedPath = path
                break
            end
            Log(string.format("Config '%s' failed to execute: %s", path, tostring(result)))
        elseif loadErr and not string.find(loadErr, "No such file or directory", 1, true) then
            Log(string.format("Config '%s' could not be loaded: %s", path, tostring(loadErr)))
        end
    end

    if not loaded then
        Log("Using built-in defaults (config.lua not found).")
        State.ConfigPath = PREFERRED_CONFIG_WRITE_PATH
        return
    end
    State.ConfigPath = loadedPath

    if type(loaded.time_input_mode) == "string" then
        local mode = ClampInputMode(loaded.time_input_mode)
        TIME_INPUT_MODE = mode
        if mode ~= loaded.time_input_mode then
            Log(string.format("Invalid config.time_input_mode '%s', using 'multiplier'.",
                tostring(loaded.time_input_mode)))
        end
    elseif loaded.time_input_mode ~= nil then
        Log("Invalid config.time_input_mode, using 'multiplier'.")
    end

    local loadedDefault = nil
    local loadedDay = nil
    local loadedNight = nil

    if TIME_INPUT_MODE == "factor" then
        if type(loaded.default_length_factor) == "number" then
            loadedDefault = ConvertLengthFactorToMultiplier(loaded.default_length_factor, "default_length_factor")
        elseif loaded.default_length_factor ~= nil then
            Log("Invalid config.default_length_factor, keeping defaults.")
        end

        if type(loaded.day_length_factor) == "number" then
            loadedDay = ConvertLengthFactorToMultiplier(loaded.day_length_factor, "day_length_factor")
        elseif loaded.day_length_factor ~= nil then
            Log("Invalid config.day_length_factor, keeping current value.")
        end

        if type(loaded.night_length_factor) == "number" then
            loadedNight = ConvertLengthFactorToMultiplier(loaded.night_length_factor, "night_length_factor")
        elseif loaded.night_length_factor ~= nil then
            Log("Invalid config.night_length_factor, keeping current value.")
        end

        if loadedDefault == nil and loadedDay == nil and loadedNight == nil then
            Log("No factor keys in config, falling back to multiplier keys.")
            TIME_INPUT_MODE = "multiplier"
        end
    end

    if TIME_INPUT_MODE == "multiplier" then
        if type(loaded.default_multiplier) == "number" then
            loadedDefault = ClampMultiplier(loaded.default_multiplier, "default_multiplier")
        elseif loaded.default_multiplier ~= nil then
            Log("Invalid config.default_multiplier, keeping defaults.")
        end

        if type(loaded.day_multiplier) == "number" then
            loadedDay = ClampMultiplier(loaded.day_multiplier, "day_multiplier")
        elseif loaded.day_multiplier ~= nil then
            Log("Invalid config.day_multiplier, keeping current value.")
        end

        if type(loaded.night_multiplier) == "number" then
            loadedNight = ClampMultiplier(loaded.night_multiplier, "night_multiplier")
        elseif loaded.night_multiplier ~= nil then
            Log("Invalid config.night_multiplier, keeping current value.")
        end
    end

    if loadedDefault then
        DAY_MULTIPLIER = loadedDefault
        NIGHT_MULTIPLIER = loadedDefault
    end
    if loadedDay then
        DAY_MULTIPLIER = loadedDay
    end
    if loadedNight then
        NIGHT_MULTIPLIER = loadedNight
    end

    if loadedDefault == nil and loadedDay == nil and loadedNight == nil then
        Log("No scaling keys in config, keeping defaults.")
    end

    ACTIVE_MULTIPLIER = DAY_MULTIPLIER
    if State.LastIsDay == false then
        ACTIVE_MULTIPLIER = NIGHT_MULTIPLIER
    end

    if type(loaded.log_interval_ms) == "number" and loaded.log_interval_ms >= 1000 then
        LOG_INTERVAL_MS = math.floor(loaded.log_interval_ms)
    else
        Log("Invalid config.log_interval_ms, keeping default 30000.")
    end

    if type(loaded.runtime_scale_tick_ms) == "number" and loaded.runtime_scale_tick_ms >= 16 and loaded.runtime_scale_tick_ms <= 5000 then
        SCALE_TICK_MS = math.floor(loaded.runtime_scale_tick_ms)
    elseif loaded.runtime_scale_tick_ms ~= nil then
        Log("Invalid config.runtime_scale_tick_ms, keeping default 33.")
    end

    if type(loaded.hud_time_font_size) == "number" and loaded.hud_time_font_size >= 8 and loaded.hud_time_font_size <= 48 then
        HUD_TIME_FONT_SIZE = math.floor(loaded.hud_time_font_size)
    elseif loaded.hud_time_font_size ~= nil then
        Log("Invalid config.hud_time_font_size, keeping default 12.")
    end

    if type(loaded.hud_time_font_object_path) == "string" then
        if loaded.hud_time_font_object_path ~= "" then
            HUD_TIME_FONT_OBJECT_PATH = loaded.hud_time_font_object_path
        else
            HUD_TIME_FONT_OBJECT_PATH = nil
        end
    elseif loaded.hud_time_font_object_path ~= nil then
        Log("Invalid config.hud_time_font_object_path, ignoring.")
    end

    if type(loaded.hud_time_shadow_alpha) == "number" and loaded.hud_time_shadow_alpha >= 0 and loaded.hud_time_shadow_alpha <= 1 then
        HUD_TIME_SHADOW_ALPHA = loaded.hud_time_shadow_alpha
    elseif loaded.hud_time_shadow_alpha ~= nil then
        Log("Invalid config.hud_time_shadow_alpha, keeping default 0.85.")
    end

    if type(loaded.hud_time_shadow_offset_x) == "number" then
        HUD_TIME_SHADOW_OFFSET_X = loaded.hud_time_shadow_offset_x
    elseif loaded.hud_time_shadow_offset_x ~= nil then
        Log("Invalid config.hud_time_shadow_offset_x, keeping default 1.0.")
    end

    if type(loaded.hud_time_shadow_offset_y) == "number" then
        HUD_TIME_SHADOW_OFFSET_Y = loaded.hud_time_shadow_offset_y
    elseif loaded.hud_time_shadow_offset_y ~= nil then
        Log("Invalid config.hud_time_shadow_offset_y, keeping default 1.0.")
    end

    if type(loaded.hud_multiplier_toast_enabled) == "boolean" then
        HUD_MULTIPLIER_TOAST_ENABLED = loaded.hud_multiplier_toast_enabled
    elseif loaded.hud_multiplier_toast_enabled ~= nil then
        Log("Invalid config.hud_multiplier_toast_enabled, keeping default true.")
    end

    if type(loaded.hud_multiplier_toast_ms) == "number" and loaded.hud_multiplier_toast_ms >= 500 and loaded.hud_multiplier_toast_ms <= 10000 then
        HUD_MULTIPLIER_TOAST_MS = math.floor(loaded.hud_multiplier_toast_ms)
    elseif loaded.hud_multiplier_toast_ms ~= nil then
        Log("Invalid config.hud_multiplier_toast_ms, keeping default 2200.")
    end

    if type(loaded.hud_multiplier_toast_show_value) == "boolean" then
        HUD_MULTIPLIER_TOAST_SHOW_VALUE = loaded.hud_multiplier_toast_show_value
    elseif loaded.hud_multiplier_toast_show_value ~= nil then
        Log("Invalid config.hud_multiplier_toast_show_value, keeping default true.")
    end

    Log(string.format(
        "Config loaded: mode=%s, day_multiplier=%.4f, night_multiplier=%.4f, log_interval_ms=%d, scale_tick_ms=%d, font_size=%d, toast=%s",
        TIME_INPUT_MODE,
        DAY_MULTIPLIER,
        NIGHT_MULTIPLIER,
        LOG_INTERVAL_MS,
        SCALE_TICK_MS,
        HUD_TIME_FONT_SIZE,
        tostring(HUD_MULTIPLIER_TOAST_ENABLED)
    ))
end

local function ResolveGametimeAsset()
    if State.GametimeAsset:IsValid() then
        return State.GametimeAsset
    end

    local Asset = CreateInvalidObject()
    for _, path in ipairs(GAMETIME_ASSET_STATIC_PATHS) do
        local ok, result = pcall(StaticFindObject, path)
        if ok and result and result:IsValid() then
            Asset = result
            Log(string.format("Resolved gametime asset via StaticFindObject: %s", path))
            break
        elseif not ok then
            Log(string.format("StaticFindObject failed for '%s': %s", path, tostring(result)))
        end
    end

    if not Asset or not Asset:IsValid() then
        for _, path in ipairs(GAMETIME_ASSET_LOAD_PATHS) do
            local ok, result = pcall(LoadAsset, path)
            if ok and result and result:IsValid() then
                Asset = result
                Log(string.format("Resolved gametime asset via LoadAsset: %s", path))
                break
            elseif not ok then
                Log(string.format("LoadAsset failed for '%s': %s", path, tostring(result)))
            end
        end
    end

    if Asset and Asset:IsValid() then
        State.GametimeAsset = Asset
        State.AssetResolveLogged = false
    end

    return Asset
end

local function GetSpeedContainer()
    if not State.CanUseConfigContainer then
        return nil
    end

    local Asset = ResolveGametimeAsset()
    if not Asset:IsValid() then
        if not State.AssetResolveLogged then
            State.AssetResolveLogged = true
            Log("Unable to resolve DA_GD_Gametime asset yet (will retry).")
        end
        return nil
    end

    local Config = Asset.Config
    if not Config or not Config.ConfigData or #Config.ConfigData < 1 then
        Log("DA_GD_Gametime is missing Config.ConfigData[1].")
        return nil
    end

    return Config.ConfigData[1]
end

local function TryGetSpeedFromContainer(SpeedContainer)
    local ok, value = pcall(function()
        return SpeedContainer.GameplayTimeSpeedMultiplier
    end)
    if ok and type(value) == "number" then
        return true, value
    end
    return false, nil
end

local function TrySetSpeedOnContainer(SpeedContainer, Multiplier)
    local ok = pcall(function()
        SpeedContainer.GameplayTimeSpeedMultiplier = Multiplier
    end)
    return ok
end

local function TryGetSpeedFromSubsystem(Subsystem)
    local ok, value = pcall(function()
        return Subsystem.GameplayTimeSpeedMultiplier
    end)
    if ok and type(value) == "number" then
        return true, value
    end
    return false, nil
end

local function TrySetSpeedOnSubsystem(Subsystem, Multiplier)
    local ok = pcall(function()
        Subsystem.GameplayTimeSpeedMultiplier = Multiplier
    end)
    return ok
end

local function ValidateAndReapplySubsystemMultiplier(Subsystem, DesiredMultiplier)
    if not Subsystem or not Subsystem:IsValid() then
        return false, nil, "subsystem-invalid"
    end

    local hasCurrent, current = TryGetSpeedFromSubsystem(Subsystem)
    if not hasCurrent then
        local reapplyOk = TrySetSpeedOnSubsystem(Subsystem, DesiredMultiplier)
        if not State.SubsystemSpeedUnreadableLogged then
            State.SubsystemSpeedUnreadableLogged = true
            Log("Subsystem speed is write-only in this UE4SS binding; validating by target enforcement only.")
        end
        if reapplyOk then
            State.MultiplierDriftActive = false
            State.LastMultiplierDriftSignature = nil
            return true, nil, "unreadable-reapplied"
        end
        State.MultiplierDriftActive = true
        return true, nil, "unreadable-reapply-failed"
    end

    State.SubsystemSpeedUnreadableLogged = false
    local diff = math.abs(current - DesiredMultiplier)
    if diff <= MULTIPLIER_TOLERANCE then
        if State.MultiplierDriftActive then
            Log(string.format("Subsystem multiplier realigned at %.4f (desired %.4f).", current, DesiredMultiplier))
        end
        State.MultiplierDriftActive = false
        State.LastMultiplierDriftSignature = nil
        return true, current, "readable"
    end

    local reapplyOk = TrySetSpeedOnSubsystem(Subsystem, DesiredMultiplier)
    local finalValue = current
    if reapplyOk then
        local hasFinal, postValue = TryGetSpeedFromSubsystem(Subsystem)
        if hasFinal then
            finalValue = postValue
        end
    end

    local signature = string.format("%.4f|%.4f|%s", DesiredMultiplier, finalValue, tostring(reapplyOk))
    if State.LastMultiplierDriftSignature ~= signature then
        if reapplyOk then
            Log(string.format(
                "Detected subsystem multiplier drift %.4f (desired %.4f); reapplied -> %.4f.",
                current,
                DesiredMultiplier,
                finalValue
            ))
        else
            Log(string.format(
                "Detected subsystem multiplier drift %.4f (desired %.4f); failed to reapply.",
                current,
                DesiredMultiplier
            ))
        end
        State.LastMultiplierDriftSignature = signature
    end

    State.MultiplierDriftActive = math.abs(finalValue - DesiredMultiplier) > MULTIPLIER_TOLERANCE
    if not State.MultiplierDriftActive then
        State.LastMultiplierDriftSignature = nil
    end

    return true, finalValue, "readable"
end

local GetGameplayTimeSubsystem
local StartStatusLoop

local function GetPhaseMultiplier(isDay)
    if isDay == false then
        return NIGHT_MULTIPLIER
    end
    return DAY_MULTIPLIER
end

local function GetScaleLoopStallThresholdSeconds()
    local tickSeconds = math.max(1, math.floor(SCALE_TICK_MS / 1000))
    local threshold = tickSeconds * 4
    if threshold < 5 then
        threshold = 5
    end
    return threshold
end

local function EnsureScaleLoopRunning()
    local now = os.time()
    if not State.ScaleLoopStarted then
        return false
    end
    if not State.LastScaleLoopWallSeconds then
        return true
    end

    local threshold = GetScaleLoopStallThresholdSeconds()
    local age = now - State.LastScaleLoopWallSeconds
    if age <= threshold then
        State.ScaleLoopStallLogged = false
        return true
    end

    if not State.ScaleLoopStallLogged then
        State.ScaleLoopStallLogged = true
        Log(string.format("Scale loop stalled for %ds (threshold=%ds); re-arming.", age, threshold))
    end
    State.ScaleLoopStarted = false
    return false
end

local function RefreshActiveMultiplier(Subsystem)
    if Subsystem and Subsystem:IsValid() then
        local ok, isDay = pcall(function()
            return Subsystem:GetIsDay()
        end)
        if ok and type(isDay) == "boolean" then
            State.LastIsDay = isDay
            ACTIVE_MULTIPLIER = GetPhaseMultiplier(isDay)
            return ACTIVE_MULTIPLIER
        end
    end

    if State.LastIsDay ~= nil then
        ACTIVE_MULTIPLIER = GetPhaseMultiplier(State.LastIsDay)
    else
        ACTIVE_MULTIPLIER = DAY_MULTIPLIER
    end
    return ACTIVE_MULTIPLIER
end

local function ApplyActiveMultiplier(Multiplier)
    local sanitized = ClampMultiplier(Multiplier, "multiplier")
    if not sanitized then
        return false
    end

    ACTIVE_MULTIPLIER = sanitized
    State.LastObservedGameTicks = nil

    local Subsystem = GetGameplayTimeSubsystem()
    if Subsystem:IsValid() then
        local hadOld, oldValue = TryGetSpeedFromSubsystem(Subsystem)
        if TrySetSpeedOnSubsystem(Subsystem, sanitized) then
            if hadOld then
                Log(string.format("Subsystem GameplayTimeSpeedMultiplier %.4f -> %.4f", oldValue, sanitized))
            else
                Log(string.format("Subsystem GameplayTimeSpeedMultiplier set to %.4f", sanitized))
            end
        else
            Log(string.format("Target multiplier set to %.4f (subsystem write not available).", sanitized))
        end
    end

    if not State.CanUseConfigContainer then
        return true
    end

    local SpeedConfig = GetSpeedContainer()
    if not SpeedConfig then
        return true
    end

    local hadOld, oldValue = TryGetSpeedFromContainer(SpeedConfig)
    if not TrySetSpeedOnContainer(SpeedConfig, sanitized) then
        State.CanUseConfigContainer = false
        if not State.InstancedStructAccessLogged then
            State.InstancedStructAccessLogged = true
            Log("ConfigData[1] is an InstancedStruct; direct field mutation is not available in this UE4SS binding.")
        end
        return true
    end

    if hadOld then
        Log(string.format("Config GameplayTimeSpeedMultiplier %.4f -> %.4f", oldValue, sanitized))
    else
        Log(string.format("Config GameplayTimeSpeedMultiplier set to %.4f", sanitized))
    end
    return true
end

local function FormatTimespan(TimespanValue)
    if not TimespanValue or type(TimespanValue.Ticks) ~= "number" then
        return "N/A"
    end

    local TotalSeconds = math.floor(TimespanValue.Ticks / 10000000)
    if TotalSeconds < 0 then
        TotalSeconds = 0
    end

    local Hours = math.floor(TotalSeconds / 3600) % 24
    local Minutes = math.floor(TotalSeconds / 60) % 60
    local Seconds = TotalSeconds % 60
    return string.format("%02d:%02d:%02d", Hours, Minutes, Seconds)
end

local function GetMultiplierState(EffectiveMultiplier)
    if EffectiveMultiplier < 1.0 - MULTIPLIER_TOLERANCE then
        return "slow"
    end
    if EffectiveMultiplier > 1.0 + MULTIPLIER_TOLERANCE then
        return "fast"
    end
    return "normal"
end

local function BuildMultiplierToastLabel(ContextLabel, Multiplier)
    local mode = GetMultiplierState(Multiplier)
    local modeLabel = "Normal"
    if mode == "slow" then
        modeLabel = "Slower"
    elseif mode == "fast" then
        modeLabel = "Faster"
    end

    if HUD_MULTIPLIER_TOAST_SHOW_VALUE then
        return string.format("%s\n%s x%.2f", ContextLabel, modeLabel, Multiplier)
    end
    return string.format("%s\n%s", ContextLabel, modeLabel)
end

local function StartMultiplierToast(ContextLabel, Multiplier)
    if not HUD_MULTIPLIER_TOAST_ENABLED then
        return
    end

    State.HudToastText = BuildMultiplierToastLabel(ContextLabel, Multiplier)
    State.HudToastRemainingMs = HUD_MULTIPLIER_TOAST_MS
    State.HudTimeLastLabel = nil
end

local function TickMultiplierToast()
    if State.HudToastRemainingMs <= 0 then
        return
    end

    State.HudToastRemainingMs = State.HudToastRemainingMs - SCALE_TICK_MS
    if State.HudToastRemainingMs <= 0 then
        State.HudToastRemainingMs = 0
        State.HudToastText = nil
        State.HudTimeLastLabel = nil
    end
end

local function BuildHudTimeLabel(TimespanValue, _EffectiveMultiplier)
    if State.HudToastText and State.HudToastRemainingMs > 0 then
        return State.HudToastText
    end

    if not TimespanValue or type(TimespanValue.Ticks) ~= "number" then
        return nil
    end

    local TotalSeconds = math.floor(TimespanValue.Ticks / 10000000)
    if TotalSeconds < 0 then
        TotalSeconds = 0
    end

    local Hours = math.floor(TotalSeconds / 3600) % 24
    local Minutes = math.floor(TotalSeconds / 60) % 60
    return string.format("%02d:%02d", Hours, Minutes)
end

GetGameplayTimeSubsystem = function()
    if not State.SubsystemBlueprintLibrary:IsValid() then
        State.SubsystemBlueprintLibrary = StaticFindObject(SUBSYSTEM_BLUEPRINT_LIBRARY_PATH)
    end
    if not State.SubsystemClass:IsValid() then
        State.SubsystemClass = StaticFindObject(DRD_GAMEPLAY_TIME_SUBSYSTEM_CLASS_PATH)
    end

    local World = UEHelpers.GetWorld()
    if World:IsValid() and State.SubsystemBlueprintLibrary:IsValid() and State.SubsystemClass:IsValid() then
        local Subsystem = State.SubsystemBlueprintLibrary:GetWorldSubsystem(World, State.SubsystemClass)
        if Subsystem and Subsystem:IsValid() then
            return Subsystem
        end
    end

    local FallbackSubsystem = FindFirstOf("DrdGameplayTimeSubsystem")
    if FallbackSubsystem and FallbackSubsystem:IsValid() then
        return FallbackSubsystem
    end

    return CreateInvalidObject()
end

local function ResolveHudTimeTextWidget()
    if State.HudTimeTextWidget:IsValid() then
        return State.HudTimeTextWidget
    end

    local candidate = nil
    local playerHud = FindFirstOf("WBP_PlayerHud_C")
    if playerHud and playerHud:IsValid() then
        local ok, timeWidget = pcall(function()
            return playerHud.WBP_Time
        end)
        if ok and timeWidget and timeWidget:IsValid() then
            local okText, textWidget = pcall(function()
                return timeWidget.TimeText
            end)
            if okText and textWidget and textWidget:IsValid() then
                candidate = textWidget
            end
        end
    end

    if not candidate then
        local timeWidget = FindFirstOf("WBP_Time_C")
        if timeWidget and timeWidget:IsValid() then
            local okText, textWidget = pcall(function()
                return timeWidget.TimeText
            end)
            if okText and textWidget and textWidget:IsValid() then
                candidate = textWidget
            end
        end
    end

    if candidate and candidate:IsValid() then
        State.HudTimeTextWidget = candidate
        State.HudTimeStyleApplied = false
        if not State.HudTimeWidgetResolved then
            State.HudTimeWidgetResolved = true
            Log("Resolved WBP_Time.TimeText; enabling in-game clock text.")
        end
        return candidate
    end

    return CreateInvalidObject()
end

local function BuildFontAssetCandidates(rawPath)
    local candidates = {}
    local seen = {}
    local function push(path)
        if type(path) == "string" and path ~= "" and not seen[path] then
            table.insert(candidates, path)
            seen[path] = true
        end
    end

    if type(rawPath) ~= "string" then
        return candidates
    end

    push(rawPath)

    local objectDot = string.match(rawPath, "%.[^%.]+$")
    if objectDot then
        local packagePath = string.gsub(rawPath, "%.[^%.]+$", "")
        if packagePath ~= rawPath then
            push(packagePath)
        end
    else
        local lastSegment = string.match(rawPath, "([^/]+)$")
        if lastSegment then
            push(rawPath .. "." .. lastSegment)
        end
    end

    return candidates
end

local function ApplyHudTimeStyle(timeTextWidget)
    if State.HudTimeStyleApplied then
        return
    end

    local styleOK, styleErr = pcall(function()
        local font = timeTextWidget.Font
        if font then
            font.Size = HUD_TIME_FONT_SIZE
            if HUD_TIME_FONT_OBJECT_PATH and HUD_TIME_FONT_OBJECT_PATH ~= "" then
                local tryPaths = BuildFontAssetCandidates(HUD_TIME_FONT_OBJECT_PATH)
                local fontObject = nil
                local usedPath = nil
                for _, candidatePath in ipairs(tryPaths) do
                    local okLoad, loadedAsset = pcall(LoadAsset, candidatePath)
                    if okLoad and loadedAsset and loadedAsset:IsValid() then
                        fontObject = loadedAsset
                        usedPath = candidatePath
                        break
                    end
                end

                if fontObject and fontObject:IsValid() then
                    font.FontObject = fontObject
                    Log(string.format("Loaded HUD font asset: %s", usedPath))
                else
                    Log(string.format("Failed to load HUD font asset from %s. Tried: %s", HUD_TIME_FONT_OBJECT_PATH,
                        table.concat(tryPaths, ", ")))
                end
            end
            timeTextWidget:SetFont(font)
        end

        timeTextWidget:SetShadowOffset({
            X = HUD_TIME_SHADOW_OFFSET_X,
            Y = HUD_TIME_SHADOW_OFFSET_Y,
        })
        timeTextWidget:SetShadowColorAndOpacity({
            R = 0.0,
            G = 0.0,
            B = 0.0,
            A = HUD_TIME_SHADOW_ALPHA,
        })
    end)

    if styleOK then
        State.HudTimeStyleApplied = true
        State.HudTimeStyleFailedLogged = false
        Log(string.format("Applied HUD time style (size=%d).", HUD_TIME_FONT_SIZE))
    elseif not State.HudTimeStyleFailedLogged then
        State.HudTimeStyleFailedLogged = true
        Log(string.format("Failed to apply HUD time style; keeping widget defaults. Error: %s", tostring(styleErr)))
    end
end

local function UpdateHudTimeText(TimespanValue, EffectiveMultiplier)
    local timeTextWidget = ResolveHudTimeTextWidget()
    if not timeTextWidget:IsValid() then
        return
    end

    ApplyHudTimeStyle(timeTextWidget)

    local visibilityOk = pcall(function()
        timeTextWidget:SetVisibility(0)
    end)
    if not visibilityOk and not State.HudTimeVisibilityFailedLogged then
        State.HudTimeVisibilityFailedLogged = true
        Log("Failed to set WBP_Time.TimeText visibility.")
    end

    local Label = BuildHudTimeLabel(TimespanValue, EffectiveMultiplier)
    if not Label or Label == State.HudTimeLastLabel then
        return
    end

    local setTextOk = pcall(function()
        timeTextWidget:SetText(FText(Label))
    end)
    if setTextOk then
        State.HudTimeLastLabel = Label
        State.HudTimeSetTextFailedLogged = false
    elseif not State.HudTimeSetTextFailedLogged then
        State.HudTimeSetTextFailedLogged = true
        Log("Failed to update WBP_Time.TimeText label.")
    end
end

local function SetDayMultiplier(Multiplier)
    local sanitized = ClampMultiplier(Multiplier, "day multiplier")
    if not sanitized then
        return false
    end

    DAY_MULTIPLIER = sanitized
    local Subsystem = GetGameplayTimeSubsystem()
    local Active = RefreshActiveMultiplier(Subsystem)
    ApplyActiveMultiplier(Active)
    if not EnsureScaleLoopRunning() then
        StartStatusLoop()
    end
    StartMultiplierToast("Day", DAY_MULTIPLIER)
    PersistConfig()
    return true
end

local function SetNightMultiplier(Multiplier)
    local sanitized = ClampMultiplier(Multiplier, "night multiplier")
    if not sanitized then
        return false
    end

    NIGHT_MULTIPLIER = sanitized
    local Subsystem = GetGameplayTimeSubsystem()
    local Active = RefreshActiveMultiplier(Subsystem)
    ApplyActiveMultiplier(Active)
    if not EnsureScaleLoopRunning() then
        StartStatusLoop()
    end
    StartMultiplierToast("Night", NIGHT_MULTIPLIER)
    PersistConfig()
    return true
end

local function SetUniformMultiplier(Multiplier)
    local sanitized = ClampMultiplier(Multiplier, "multiplier")
    if not sanitized then
        return false
    end

    DAY_MULTIPLIER = sanitized
    NIGHT_MULTIPLIER = sanitized
    local Subsystem = GetGameplayTimeSubsystem()
    local Active = RefreshActiveMultiplier(Subsystem)
    ApplyActiveMultiplier(Active)
    if not EnsureScaleLoopRunning() then
        StartStatusLoop()
    end
    StartMultiplierToast("Time", sanitized)
    PersistConfig()
    return true
end

local function LogTimeStatus()
    local Subsystem = GetGameplayTimeSubsystem()
    local EffectiveMultiplier = RefreshActiveMultiplier(Subsystem)
    local CurrentSpeed = "N/A"
    local UsedAppliedFallback = false
    if Subsystem:IsValid() then
        local validated, validatedSpeed, _ = ValidateAndReapplySubsystemMultiplier(Subsystem, EffectiveMultiplier)
        if validated and type(validatedSpeed) == "number" then
            CurrentSpeed = string.format("%.4f", validatedSpeed)
        end

        local hasSubsystemSpeed, subsystemSpeed = TryGetSpeedFromSubsystem(Subsystem)
        if hasSubsystemSpeed then
            CurrentSpeed = string.format("%.4f", subsystemSpeed)
        end
    end

    if CurrentSpeed == "N/A" then
        local SpeedConfig = GetSpeedContainer()
        if SpeedConfig then
            local hasConfigSpeed, configSpeed = TryGetSpeedFromContainer(SpeedConfig)
            if hasConfigSpeed then
                CurrentSpeed = string.format("%.4f", configSpeed)
            end
        end
    end

    if CurrentSpeed == "N/A" then
        CurrentSpeed = string.format("%.4f", EffectiveMultiplier)
        UsedAppliedFallback = true
    end

    if not Subsystem:IsValid() then
        if UsedAppliedFallback then
            Log(string.format(
                "speed=%s (applied) | desired=%.4f | day=%.4f | night=%.4f | gameplayTimeSubsystem=not-ready",
                CurrentSpeed, EffectiveMultiplier, DAY_MULTIPLIER, NIGHT_MULTIPLIER))
        else
            Log(string.format("speed=%s | desired=%.4f | day=%.4f | night=%.4f | gameplayTimeSubsystem=not-ready",
                CurrentSpeed, EffectiveMultiplier, DAY_MULTIPLIER, NIGHT_MULTIPLIER))
        end
        return
    end

    local CurrentGameTime = Subsystem:GetCurrentGameTime()
    local IsDay = Subsystem:GetIsDay()
    State.LastIsDay = IsDay
    UpdateHudTimeText(CurrentGameTime, EffectiveMultiplier)
    if UsedAppliedFallback then
        Log(string.format("speed=%s (applied) | desired=%.4f | day=%.4f | night=%.4f | gameTime=%s | isDay=%s",
            CurrentSpeed, EffectiveMultiplier, DAY_MULTIPLIER, NIGHT_MULTIPLIER, FormatTimespan(CurrentGameTime),
            tostring(IsDay)))
    else
        Log(string.format("speed=%s | desired=%.4f | day=%.4f | night=%.4f | gameTime=%s | isDay=%s", CurrentSpeed,
            EffectiveMultiplier, DAY_MULTIPLIER, NIGHT_MULTIPLIER, FormatTimespan(CurrentGameTime), tostring(IsDay)))
    end
end

local function ApplyRuntimeTimeScalingStep()
    TickMultiplierToast()

    local Subsystem = GetGameplayTimeSubsystem()
    if not Subsystem:IsValid() then
        State.LastObservedGameTicks = nil
        State.LastSetGameTimeTicks = nil
        return
    end

    local CurrentGameTime = Subsystem:GetCurrentGameTime()
    if not CurrentGameTime or type(CurrentGameTime.Ticks) ~= "number" then
        State.LastObservedGameTicks = nil
        State.LastSetGameTimeTicks = nil
        return
    end

    if State.LastSetGameTimeTicks and CurrentGameTime.Ticks + 1000000 < State.LastSetGameTimeTicks then
        if not State.RuntimeSetGameTimeIneffectiveLogged then
            State.RuntimeSetGameTimeIneffectiveLogged = true
            Log(string.format(
                "SetGameTime may be overridden by game state (observed %.0f < last written %.0f).",
                CurrentGameTime.Ticks,
                State.LastSetGameTimeTicks
            ))
        end
        State.MultiplierDriftActive = true
    else
        State.RuntimeSetGameTimeIneffectiveLogged = false
    end

    if not State.LastObservedGameTicks then
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        return
    end

    local DeltaTicks = CurrentGameTime.Ticks - State.LastObservedGameTicks
    if DeltaTicks <= 0 then
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        return
    end

    local EffectiveMultiplier = RefreshActiveMultiplier(Subsystem)
    ValidateAndReapplySubsystemMultiplier(Subsystem, EffectiveMultiplier)
    if EffectiveMultiplier == 1 then
        UpdateHudTimeText(CurrentGameTime, EffectiveMultiplier)
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        State.LastSetGameTimeTicks = nil
        return
    end

    local ExtraTicks = math.floor(DeltaTicks * (EffectiveMultiplier - 1.0))
    if ExtraTicks == 0 then
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        State.LastSetGameTimeTicks = nil
        return
    end

    local NewTicks = CurrentGameTime.Ticks + ExtraTicks
    local AdjustedGameTime = CurrentGameTime
    AdjustedGameTime.Ticks = NewTicks

    local WriteOK = pcall(function()
        Subsystem:SetGameTime(AdjustedGameTime)
    end)

    if WriteOK then
        UpdateHudTimeText(AdjustedGameTime, EffectiveMultiplier)
        State.LastObservedGameTicks = NewTicks
        State.LastSetGameTimeTicks = NewTicks
        State.RuntimeScaleWriteFailedLogged = false
    else
        UpdateHudTimeText(CurrentGameTime, EffectiveMultiplier)
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        State.LastSetGameTimeTicks = nil
        if not State.RuntimeScaleWriteFailedLogged then
            State.RuntimeScaleWriteFailedLogged = true
            Log("Runtime SetGameTime write failed; multiplier changes may not affect progression.")
        end
    end
end

StartStatusLoop = function()
    if State.ScaleLoopStarted and EnsureScaleLoopRunning() then
        return
    end

    State.ScaleLoopStarted = true

    local function Tick()
        State.ScaleLoopTickCount = State.ScaleLoopTickCount + 1
        State.LastScaleLoopWallSeconds = os.time()
        State.ScaleLoopStallLogged = false
        ApplyRuntimeTimeScalingStep()
        State.StatusAccumulatorMs = State.StatusAccumulatorMs + SCALE_TICK_MS
        if State.StatusAccumulatorMs >= LOG_INTERVAL_MS then
            State.StatusAccumulatorMs = 0
            LogTimeStatus()
        end
        State.ScaleLoopHandle = ExecuteInGameThreadWithDelay(SCALE_TICK_MS, Tick)
    end

    State.ScaleLoopHandle = ExecuteInGameThreadWithDelay(SCALE_TICK_MS, Tick)
end

local function TryHookGameplayTimeInitialize()
    if State.OnInitializeHooked then
        return
    end

    local ok, preId, postId = pcall(RegisterHook, "/Script/Dreadmoor.DrdGameplayTimeSubsystem:OnInitialize",
        function(selfParam, configParam)
            local subsystem = nil
            local okSubsystem, subsystemValue = pcall(function()
                return selfParam:get()
            end)
            if okSubsystem then
                subsystem = subsystemValue
            end

            local okConfig, configValue = pcall(function()
                return configParam:get()
            end)
            if not okConfig or not configValue then
                Log("OnInitialize hook fired, but config param could not be accessed.")
                return
            end

            local currentIsDay = State.LastIsDay
            if subsystem and subsystem:IsValid() then
                local okIsDay, isDayValue = pcall(function()
                    return subsystem:GetIsDay()
                end)
                if okIsDay and type(isDayValue) == "boolean" then
                    currentIsDay = isDayValue
                    State.LastIsDay = isDayValue
                end
            end

            local desired = GetPhaseMultiplier(currentIsDay)
            ACTIVE_MULTIPLIER = desired

            local readOk, oldValue = pcall(function()
                return configValue.GameplayTimeSpeedMultiplier
            end)
            local writeOk = pcall(function()
                configValue.GameplayTimeSpeedMultiplier = desired
            end)

            if writeOk then
                if readOk and type(oldValue) == "number" then
                    Log(string.format("OnInitialize override %.4f -> %.4f", oldValue, desired))
                else
                    Log(string.format("OnInitialize override set to %.4f", desired))
                end
            else
                Log("OnInitialize hook fired, but GameplayTimeSpeedMultiplier override failed.")
            end
        end)

    if ok then
        State.OnInitializeHooked = true
        Log("Hooked DrdGameplayTimeSubsystem:OnInitialize")
    else
        Log(string.format("Failed to hook OnInitialize: %s", tostring(preId)))
    end
end

RegisterConsoleCommandHandler("drd_time_set", function(FullCommand, Parameters, Ar)
    if #Parameters < 1 then
        Log("Usage: drd_time_set <multiplier>")
        return true
    end

    local NewMultiplier = tonumber(Parameters[1])
    if not NewMultiplier then
        Log(string.format("Could not parse multiplier '%s'.", tostring(Parameters[1])))
        return true
    end

    TIME_INPUT_MODE = "multiplier"
    SetUniformMultiplier(NewMultiplier)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_set_day", function(FullCommand, Parameters, Ar)
    if #Parameters < 1 then
        Log("Usage: drd_time_set_day <multiplier>")
        return true
    end

    local NewMultiplier = tonumber(Parameters[1])
    if not NewMultiplier then
        Log(string.format("Could not parse day multiplier '%s'.", tostring(Parameters[1])))
        return true
    end

    TIME_INPUT_MODE = "multiplier"
    SetDayMultiplier(NewMultiplier)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_set_night", function(FullCommand, Parameters, Ar)
    if #Parameters < 1 then
        Log("Usage: drd_time_set_night <multiplier>")
        return true
    end

    local NewMultiplier = tonumber(Parameters[1])
    if not NewMultiplier then
        Log(string.format("Could not parse night multiplier '%s'.", tostring(Parameters[1])))
        return true
    end

    TIME_INPUT_MODE = "multiplier"
    SetNightMultiplier(NewMultiplier)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_set_length", function(FullCommand, Parameters, Ar)
    if #Parameters < 1 then
        Log("Usage: drd_time_set_length <factor>")
        return true
    end

    local NewFactor = tonumber(Parameters[1])
    if not NewFactor then
        Log(string.format("Could not parse length factor '%s'.", tostring(Parameters[1])))
        return true
    end

    local NewMultiplier = ConvertLengthFactorToMultiplier(NewFactor, "time length factor")
    if not NewMultiplier then
        return true
    end

    TIME_INPUT_MODE = "factor"
    SetUniformMultiplier(NewMultiplier)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_set_day_length", function(FullCommand, Parameters, Ar)
    if #Parameters < 1 then
        Log("Usage: drd_time_set_day_length <factor>")
        return true
    end

    local NewFactor = tonumber(Parameters[1])
    if not NewFactor then
        Log(string.format("Could not parse day length factor '%s'.", tostring(Parameters[1])))
        return true
    end

    local NewMultiplier = ConvertLengthFactorToMultiplier(NewFactor, "day length factor")
    if not NewMultiplier then
        return true
    end

    TIME_INPUT_MODE = "factor"
    SetDayMultiplier(NewMultiplier)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_set_night_length", function(FullCommand, Parameters, Ar)
    if #Parameters < 1 then
        Log("Usage: drd_time_set_night_length <factor>")
        return true
    end

    local NewFactor = tonumber(Parameters[1])
    if not NewFactor then
        Log(string.format("Could not parse night length factor '%s'.", tostring(Parameters[1])))
        return true
    end

    local NewMultiplier = ConvertLengthFactorToMultiplier(NewFactor, "night length factor")
    if not NewMultiplier then
        return true
    end

    TIME_INPUT_MODE = "factor"
    SetNightMultiplier(NewMultiplier)
    LogTimeStatus()
    return true
end)

local function HandleTimeGet()
    LogTimeStatus()
    return true
end

local function HandleTimeValidate()
    if not EnsureScaleLoopRunning() then
        StartStatusLoop()
    end

    local Subsystem = GetGameplayTimeSubsystem()
    local desired = RefreshActiveMultiplier(Subsystem)

    if not Subsystem:IsValid() then
        Log(string.format("validate | desired=%.4f | subsystem=not-ready | day=%.4f | night=%.4f",
            desired, DAY_MULTIPLIER, NIGHT_MULTIPLIER))
        return true
    end

    local validated, actual, mode = ValidateAndReapplySubsystemMultiplier(Subsystem, desired)
    if not validated or type(actual) ~= "number" then
        if mode == "unreadable-reapplied" then
            Log(string.format(
                "validate | desired=%.4f | actual=unreadable | enforcement=ok | loopTicks=%d | day=%.4f | night=%.4f",
                desired, State.ScaleLoopTickCount, DAY_MULTIPLIER, NIGHT_MULTIPLIER
            ))
        elseif mode == "unreadable-reapply-failed" then
            Log(string.format(
                "validate | desired=%.4f | actual=unreadable | enforcement=failed | loopTicks=%d | day=%.4f | night=%.4f",
                desired, State.ScaleLoopTickCount, DAY_MULTIPLIER, NIGHT_MULTIPLIER
            ))
        else
            Log(string.format("validate | desired=%.4f | actual=N/A | loopTicks=%d | day=%.4f | night=%.4f",
                desired, State.ScaleLoopTickCount, DAY_MULTIPLIER, NIGHT_MULTIPLIER))
        end
        return true
    end

    local drift = math.abs(actual - desired) > MULTIPLIER_TOLERANCE
    local isDay = State.LastIsDay
    Log(string.format(
        "validate | desired=%.4f | actual=%.4f | drift=%s | loopTicks=%d | day=%.4f | night=%.4f | isDay=%s",
        desired, actual, tostring(drift), State.ScaleLoopTickCount, DAY_MULTIPLIER, NIGHT_MULTIPLIER, tostring(isDay)))
    return true
end

RegisterConsoleCommandHandler("drd_time_get", function(FullCommand, Parameters, Ar)
    return HandleTimeGet()
end)

RegisterConsoleCommandHandler("drd_time_validate", function(FullCommand, Parameters, Ar)
    return HandleTimeValidate()
end)

RegisterConsoleCommandHandler("drd_time_reset", function(FullCommand, Parameters, Ar)
    TIME_INPUT_MODE = "multiplier"
    SetUniformMultiplier(1.0)
    LogTimeStatus()
    return true
end)

LoadConfig()
TryHookGameplayTimeInitialize()

ExecuteInGameThread(function()
    RefreshActiveMultiplier(GetGameplayTimeSubsystem())
    ApplyActiveMultiplier(ACTIVE_MULTIPLIER)
    LogTimeStatus()
    StartStatusLoop()
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
    ExecuteInGameThread(function()
        RefreshActiveMultiplier(GetGameplayTimeSubsystem())
        ApplyActiveMultiplier(ACTIVE_MULTIPLIER)
        LogTimeStatus()
    end)
end)
