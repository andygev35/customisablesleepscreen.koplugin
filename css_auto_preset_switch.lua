-- Automatically switches between two presets, triggered by a time window or KOReader's own night mode setting.

local Device = require("device")

local config     = require("css_config")
local SETTINGS   = config.SETTINGS
local getSetting = config.getSetting

local css_settings = require("css_settings")
local PresetStore  = css_settings.presets()

-- Night detection

local function isInNightWindow()
    local start_min = getSetting("AUTO_PRESET_SWITCH_START_HOUR") * 60 + getSetting("AUTO_PRESET_SWITCH_START_MIN")
    local end_min    = getSetting("AUTO_PRESET_SWITCH_END_HOUR") * 60 + getSetting("AUTO_PRESET_SWITCH_END_MIN")
    if start_min == end_min then return false end

    local now = os.date("*t")
    local now_min = now.hour * 60 + now.min

    if start_min < end_min then
        return now_min >= start_min and now_min < end_min
    else
        return now_min >= start_min or now_min < end_min
    end
end

local function isNightModeActive()
    return (Device.screen.night_mode == true) or G_reader_settings:isTrue("night_mode")
end

local function isNightNow()
    if getSetting("AUTO_PRESET_SWITCH_TRIGGER") == "night_mode" then
        return isNightModeActive()
    end
    return isInNightWindow()
end

-- Whether the automatic switching is turned on at all.
local function isEnabled()
    return getSetting("AUTO_PRESET_SWITCH_ENABLED") == true
end

-- True when the night side is in effect: decided by the loaded preset (what the sleep screen shows), else by the schedule / night mode.
local function isNightPresetActive()
    local current = PresetStore:readSetting(SETTINGS.LAST_LOADED_PRESET)
    local day_name   = getSetting("AUTO_PRESET_SWITCH_DAY_PRESET")
    local night_name = getSetting("AUTO_PRESET_SWITCH_NIGHT_PRESET")
    if current ~= nil and day_name ~= night_name then
        if current == night_name then return true end
        if current == day_name then return false end
    end
    return isNightNow()
end

-- Switching

local function applyIfDue(force)
    if not getSetting("AUTO_PRESET_SWITCH_ENABLED") then return end

    local day_name   = getSetting("AUTO_PRESET_SWITCH_DAY_PRESET")
    local night_name = getSetting("AUTO_PRESET_SWITCH_NIGHT_PRESET")
    if day_name == night_name then return end

    local current_name = PresetStore:readSetting(SETTINGS.LAST_LOADED_PRESET)
    if not force and current_name ~= day_name and current_name ~= night_name then return end

    local target_name = isNightNow() and night_name or day_name
    if target_name == current_name then return end

    local preset_obj    = require("css_presets").getPresetObj()
    local target_preset = preset_obj.presets[target_name]
    if not target_preset then return end

    preset_obj.loadPreset(target_preset, target_name)
end

return {
    isInNightWindow   = isInNightWindow,
    isNightModeActive = isNightModeActive,
    isNightNow        = isNightNow,
    isEnabled         = isEnabled,
    isNightPresetActive = isNightPresetActive,
    applyIfDue        = applyIfDue,
}
