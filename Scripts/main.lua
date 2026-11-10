local UEHelpers = require("UEHelpers")

local DAY_MULTIPLIER = 0.50
local NIGHT_MULTIPLIER = 0.50
local ACTIVE_MULTIPLIER = 0.50
local LOG_INTERVAL_MS = 30000
local SCALE_TICK_MS = 1000
local PREFERRED_CONFIG_WRITE_PATH = "Mods\\MoorTime\\config.lua"
local CONFIG_PATHS = {
    "Mods\\MoorTime\\Scripts\\config.lua",
    "ue4ss\\Mods\\MoorTime\\Scripts\\config.lua",
    "Dreadmoor\\Binaries\\Win64\\ue4ss\\Mods\\MoorTime\\Scripts\\config.lua",
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
}

local function Log(Message)
    print(string.format("[MoorTime] %s\n", Message))
end

local function PersistConfig()
    local configPath = State.ConfigPath or PREFERRED_CONFIG_WRITE_PATH

    local file, openErr = io.open(configPath, "w")
    if not file then
        Log(string.format("Failed to open config for write '%s': %s", configPath, tostring(openErr)))
        return false
    end

    local configText = string.format(
        "return {\n" ..
        "    default_multiplier = %.4f,\n" ..
        "    day_multiplier = %.4f,\n" ..
        "    night_multiplier = %.4f,\n" ..
        "    log_interval_ms = %d,\n" ..
        "}\n",
        DAY_MULTIPLIER,
        DAY_MULTIPLIER,
        NIGHT_MULTIPLIER,
        LOG_INTERVAL_MS
    )

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

    local loadedDefault = nil
    if type(loaded.default_multiplier) == "number" and loaded.default_multiplier > 0 then
        loadedDefault = loaded.default_multiplier
        DAY_MULTIPLIER = loaded.default_multiplier
        NIGHT_MULTIPLIER = loaded.default_multiplier
    elseif loaded.default_multiplier ~= nil then
        Log("Invalid config.default_multiplier, keeping defaults.")
    end

    if type(loaded.day_multiplier) == "number" and loaded.day_multiplier > 0 then
        DAY_MULTIPLIER = loaded.day_multiplier
    elseif loaded.day_multiplier ~= nil then
        Log("Invalid config.day_multiplier, keeping current value.")
    end

    if type(loaded.night_multiplier) == "number" and loaded.night_multiplier > 0 then
        NIGHT_MULTIPLIER = loaded.night_multiplier
    elseif loaded.night_multiplier ~= nil then
        Log("Invalid config.night_multiplier, keeping current value.")
    end

    if loadedDefault == nil and loaded.day_multiplier == nil and loaded.night_multiplier == nil then
        Log("No multiplier keys in config, keeping defaults.")
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

    Log(string.format(
        "Config loaded: day_multiplier=%.4f, night_multiplier=%.4f, log_interval_ms=%d",
        DAY_MULTIPLIER,
        NIGHT_MULTIPLIER,
        LOG_INTERVAL_MS
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

local GetGameplayTimeSubsystem

local function GetPhaseMultiplier(isDay)
    if isDay == false then
        return NIGHT_MULTIPLIER
    end
    return DAY_MULTIPLIER
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
    if type(Multiplier) ~= "number" or Multiplier <= 0 then
        Log(string.format("Invalid multiplier '%s'. Must be > 0.", tostring(Multiplier)))
        return false
    end

    ACTIVE_MULTIPLIER = Multiplier
    State.LastObservedGameTicks = nil

    local Subsystem = GetGameplayTimeSubsystem()
    if Subsystem:IsValid() then
        local hadOld, oldValue = TryGetSpeedFromSubsystem(Subsystem)
        if TrySetSpeedOnSubsystem(Subsystem, Multiplier) then
            if hadOld then
                Log(string.format("Subsystem GameplayTimeSpeedMultiplier %.4f -> %.4f", oldValue, Multiplier))
            else
                Log(string.format("Subsystem GameplayTimeSpeedMultiplier set to %.4f", Multiplier))
            end
        else
            Log(string.format("Target multiplier set to %.4f (subsystem write not available).", Multiplier))
        end
    end

    local SpeedConfig = GetSpeedContainer()
    if not SpeedConfig then
        return true
    end

    local hadOld, oldValue = TryGetSpeedFromContainer(SpeedConfig)
    if not TrySetSpeedOnContainer(SpeedConfig, Multiplier) then
        if not State.InstancedStructAccessLogged then
            State.InstancedStructAccessLogged = true
            Log("ConfigData[1] is an InstancedStruct; direct field mutation is not available in this UE4SS binding.")
        end
        return true
    end

    if hadOld then
        Log(string.format("Config GameplayTimeSpeedMultiplier %.4f -> %.4f", oldValue, Multiplier))
    else
        Log(string.format("Config GameplayTimeSpeedMultiplier set to %.4f", Multiplier))
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

local function SetDayMultiplier(Multiplier)
    if type(Multiplier) ~= "number" or Multiplier <= 0 then
        Log(string.format("Invalid day multiplier '%s'. Must be > 0.", tostring(Multiplier)))
        return false
    end

    DAY_MULTIPLIER = Multiplier
    local Subsystem = GetGameplayTimeSubsystem()
    local Active = RefreshActiveMultiplier(Subsystem)
    ApplyActiveMultiplier(Active)
    PersistConfig()
    return true
end

local function SetNightMultiplier(Multiplier)
    if type(Multiplier) ~= "number" or Multiplier <= 0 then
        Log(string.format("Invalid night multiplier '%s'. Must be > 0.", tostring(Multiplier)))
        return false
    end

    NIGHT_MULTIPLIER = Multiplier
    local Subsystem = GetGameplayTimeSubsystem()
    local Active = RefreshActiveMultiplier(Subsystem)
    ApplyActiveMultiplier(Active)
    PersistConfig()
    return true
end

local function SetUniformMultiplier(Multiplier)
    if type(Multiplier) ~= "number" or Multiplier <= 0 then
        Log(string.format("Invalid multiplier '%s'. Must be > 0.", tostring(Multiplier)))
        return false
    end

    DAY_MULTIPLIER = Multiplier
    NIGHT_MULTIPLIER = Multiplier
    local Subsystem = GetGameplayTimeSubsystem()
    local Active = RefreshActiveMultiplier(Subsystem)
    ApplyActiveMultiplier(Active)
    PersistConfig()
    return true
end

local function LogTimeStatus()
    local Subsystem = GetGameplayTimeSubsystem()
    local EffectiveMultiplier = RefreshActiveMultiplier(Subsystem)
    local CurrentSpeed = "N/A"
    local UsedAppliedFallback = false
    if Subsystem:IsValid() then
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
            Log(string.format("speed=%s (applied) | day=%.4f | night=%.4f | gameplayTimeSubsystem=not-ready",
                CurrentSpeed, DAY_MULTIPLIER, NIGHT_MULTIPLIER))
        else
            Log(string.format("speed=%s | day=%.4f | night=%.4f | gameplayTimeSubsystem=not-ready", CurrentSpeed,
                DAY_MULTIPLIER, NIGHT_MULTIPLIER))
        end
        return
    end

    local CurrentGameTime = Subsystem:GetCurrentGameTime()
    local IsDay = Subsystem:GetIsDay()
    State.LastIsDay = IsDay
    if UsedAppliedFallback then
        Log(string.format("speed=%s (applied) | day=%.4f | night=%.4f | gameTime=%s | isDay=%s", CurrentSpeed,
            DAY_MULTIPLIER, NIGHT_MULTIPLIER, FormatTimespan(CurrentGameTime), tostring(IsDay)))
    else
        Log(string.format("speed=%s | day=%.4f | night=%.4f | gameTime=%s | isDay=%s", CurrentSpeed, DAY_MULTIPLIER,
            NIGHT_MULTIPLIER, FormatTimespan(CurrentGameTime), tostring(IsDay)))
    end
end

local function ApplyRuntimeTimeScalingStep()
    local Subsystem = GetGameplayTimeSubsystem()
    if not Subsystem:IsValid() then
        State.LastObservedGameTicks = nil
        return
    end

    local CurrentGameTime = Subsystem:GetCurrentGameTime()
    if not CurrentGameTime or type(CurrentGameTime.Ticks) ~= "number" then
        State.LastObservedGameTicks = nil
        return
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
    if EffectiveMultiplier == 1 then
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        return
    end

    local ExtraTicks = math.floor(DeltaTicks * (EffectiveMultiplier - 1.0))
    if ExtraTicks == 0 then
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        return
    end

    local NewTicks = CurrentGameTime.Ticks + ExtraTicks
    local AdjustedGameTime = CurrentGameTime
    AdjustedGameTime.Ticks = NewTicks

    local WriteOK = pcall(function()
        Subsystem:SetGameTime(AdjustedGameTime)
    end)

    if WriteOK then
        State.LastObservedGameTicks = NewTicks
        State.RuntimeScaleWriteFailedLogged = false
    else
        State.LastObservedGameTicks = CurrentGameTime.Ticks
        if not State.RuntimeScaleWriteFailedLogged then
            State.RuntimeScaleWriteFailedLogged = true
            Log("Runtime SetGameTime write failed; multiplier changes may not affect progression.")
        end
    end
end

local function StartStatusLoop()
    ExecuteInGameThreadWithDelay(SCALE_TICK_MS, function()
        ApplyRuntimeTimeScalingStep()
        State.StatusAccumulatorMs = State.StatusAccumulatorMs + SCALE_TICK_MS
        if State.StatusAccumulatorMs >= LOG_INTERVAL_MS then
            State.StatusAccumulatorMs = 0
            LogTimeStatus()
        end
        StartStatusLoop()
    end)
end

local function TryHookGameplayTimeInitialize()
    if State.OnInitializeHooked then
        return
    end

    local ok, preId, postId = pcall(RegisterHook, "/Script/Dreadmoor.DrdGameplayTimeSubsystem:OnInitialize",
        function(selfParam, configParam)
            local okConfig, configValue = pcall(function()
                return configParam:get()
            end)
            if not okConfig or not configValue then
                Log("OnInitialize hook fired, but config param could not be accessed.")
                return
            end

            local desired = GetPhaseMultiplier(State.LastIsDay)
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

    SetNightMultiplier(NewMultiplier)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_log", function(FullCommand, Parameters, Ar)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_get", function(FullCommand, Parameters, Ar)
    LogTimeStatus()
    return true
end)

RegisterConsoleCommandHandler("drd_time_reset", function(FullCommand, Parameters, Ar)
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
