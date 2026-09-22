-- Central settings store: plugin data lives in two dedicated LuaSettings files in koreader/settings (separate from settings.reader.lua).

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local _plugin  = nil
local _presets = nil

local function plugin()
    if not _plugin then
        _plugin = LuaSettings:open(DataStorage:getSettingsDir() .. "/customisablesleepscreen.lua")
    end
    return _plugin
end

local function presets()
    if not _presets then
        _presets = LuaSettings:open(DataStorage:getSettingsDir() .. "/customisablesleepscreen_presets.lua")
    end
    return _presets
end

local function flush()
    if _plugin  then pcall(function() _plugin:flush()  end) end
    if _presets then pcall(function() _presets:flush() end) end
end

local function reset()
    _plugin  = nil
    _presets = nil
end

return {
    plugin  = plugin,
    presets = presets,
    flush   = flush,
    reset   = reset,
}
