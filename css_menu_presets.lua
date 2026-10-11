-- Preset management menu: save, load, and organise presets.

local UIManager  = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local Presets    = require("ui/presets")

local _        = require("gettext")
local config   = require("css_config")
local SETTINGS = config.SETTINGS

local css_settings = require("css_settings")
local PluginStore  = css_settings.plugin()
local PresetStore  = css_settings.presets()

local presets_mod            = require("css_presets")
local initializePresetSystem = presets_mod.getPresetObj
local PRELOADED_PRESETS      = presets_mod.PRELOADED_PRESETS
local saveUserPresets        = presets_mod.saveUserPresets
local getAllSettingKeys      = presets_mod.getAllSettingKeys
local captureCurrentSettings = presets_mod.captureCurrentSettings

local h                = require("css_menu_helpers")
local getSetting       = h.getSetting
local createRadioItem  = h.createRadioItem
local buildSleepScreenPreviewWidget = h.buildSleepScreenPreviewWidget
local showSleepScreenPreviewWidget  = h.showSleepScreenPreviewWidget

-- Automatic preset switching submenu

local function buildAutoPresetSwitchMenu()
    local preset_obj = initializePresetSystem()

    local function isAutoSwitchEnabled()
        return PluginStore:isTrue(SETTINGS.AUTO_PRESET_SWITCH_ENABLED)
    end

    local function buildPresetPickerMenu(setting_key)
        local names = {}
        for name, _ in pairs(preset_obj.presets) do
            names[#names + 1] = name
        end
        table.sort(names)
        local items = {}
        for _, name in ipairs(names) do
            items[#items + 1] = createRadioItem(name, nil, SETTINGS[setting_key], name)
        end
        return items
    end

    return {
        {
            text      = _("Enable automatic preset switching"),
            help_text = _("When enabled, switches between the day and night presets below as needed. If you manually switch to a different preset, this pauses until you switch back to one of the two, or use \"Sync now\" below."),
            checked_func = function()
                return PluginStore:isTrue(SETTINGS.AUTO_PRESET_SWITCH_ENABLED)
            end,
            callback = function(touchmenu_instance)
                local now_enabled = not PluginStore:isTrue(SETTINGS.AUTO_PRESET_SWITCH_ENABLED)
                PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_ENABLED, now_enabled)
                if now_enabled then
                    require("css_auto_preset_switch").applyIfDue(true)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end
            end,
        },
        {
            text           = _("Sync now"),
            help_text      = _("Immediately switches to the correct day/night preset, even if a different preset is currently active."),
            enabled_func   = isAutoSwitchEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local auto_preset_switch = require("css_auto_preset_switch")
                local day_name    = getSetting("AUTO_PRESET_SWITCH_DAY_PRESET")
                local night_name  = getSetting("AUTO_PRESET_SWITCH_NIGHT_PRESET")
                local target_name = auto_preset_switch.isNightNow() and night_name or day_name
                local before      = PresetStore:readSetting(SETTINGS.LAST_LOADED_PRESET)

                auto_preset_switch.applyIfDue(true)

                local after = PresetStore:readSetting(SETTINGS.LAST_LOADED_PRESET)
                local text, timeout
                if after ~= target_name then
                    text = string.format(
                        _("Couldn't switch to '%s' - it may no longer exist. Check the day/night preset pickers below."),
                        target_name)
                    timeout = 4
                elseif before ~= after then
                    text, timeout = string.format(_("Switched to '%s'"), after), 2
                else
                    text, timeout = string.format(_("Already on '%s' - no change needed"), target_name), 2
                end

                UIManager:show(require("ui/widget/infomessage"):new { text = text, timeout = timeout })
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            separator = true,
        },
        {
            text_func = function()
                return string.format(_("Day preset: %s"), getSetting("AUTO_PRESET_SWITCH_DAY_PRESET"))
            end,
            help_text    = _("Preset to switch to outside the night window."),
            enabled_func = isAutoSwitchEnabled,
            sub_item_table_func = function() return buildPresetPickerMenu("AUTO_PRESET_SWITCH_DAY_PRESET") end,
        },
        {
            text_func = function()
                return string.format(_("Night preset: %s"), getSetting("AUTO_PRESET_SWITCH_NIGHT_PRESET"))
            end,
            help_text    = _("Preset to switch to during the night window."),
            enabled_func = isAutoSwitchEnabled,
            sub_item_table_func = function() return buildPresetPickerMenu("AUTO_PRESET_SWITCH_NIGHT_PRESET") end,
            separator = true,
        },
        {
            text_func = function()
                local label = getSetting("AUTO_PRESET_SWITCH_TRIGGER") == "night_mode"
                    and _("Follow KOReader's night mode") or _("Time window")
                return string.format(_("Trigger: %s"), label)
            end,
            help_text    = _("How the schedule decides when to switch: a fixed time window, or KOReader's own night mode setting (useful if you toggle that manually rather than on a fixed schedule)."),
            enabled_func = isAutoSwitchEnabled,
            sub_item_table = {
                createRadioItem(
                    _("Time window"),
                    _("Switch based on the start/end times."),
                    SETTINGS.AUTO_PRESET_SWITCH_TRIGGER, "time"
                ),
                createRadioItem(
                    _("Follow KOReader's night mode"),
                    _("Switch to the night preset whenever KOReader's own night mode is turned on, and back to the day preset when it's off."),
                    SETTINGS.AUTO_PRESET_SWITCH_TRIGGER, "night_mode"
                ),
            },
        },
        {
            text_func = function()
                return string.format(_("Night window start: %02d:%02d"),
                    getSetting("AUTO_PRESET_SWITCH_START_HOUR"), getSetting("AUTO_PRESET_SWITCH_START_MIN"))
            end,
            help_text      = _("Time of day the night preset starts being used."),
            enabled_func   = function()
                return isAutoSwitchEnabled() and getSetting("AUTO_PRESET_SWITCH_TRIGGER") ~= "night_mode"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local DateTimeWidget = require("ui/widget/datetimewidget")
                UIManager:show(DateTimeWidget:new {
                    title_text = _("Night window start"),
                    info_text  = _("Enter time in hours and minutes."),
                    hour       = getSetting("AUTO_PRESET_SWITCH_START_HOUR"),
                    min        = getSetting("AUTO_PRESET_SWITCH_START_MIN"),
                    ok_text    = _("Set time"),
                    callback = function(time)
                        PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_START_HOUR, time.hour)
                        PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_START_MIN, time.min)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
        {
            text_func = function()
                return string.format(_("Night window end: %02d:%02d"),
                    getSetting("AUTO_PRESET_SWITCH_END_HOUR"), getSetting("AUTO_PRESET_SWITCH_END_MIN"))
            end,
            help_text      = _("Time of day the day preset resumes being used."),
            enabled_func   = function()
                return isAutoSwitchEnabled() and getSetting("AUTO_PRESET_SWITCH_TRIGGER") ~= "night_mode"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local DateTimeWidget = require("ui/widget/datetimewidget")
                UIManager:show(DateTimeWidget:new {
                    title_text = _("Night window end"),
                    info_text  = _("Enter time in hours and minutes."),
                    hour       = getSetting("AUTO_PRESET_SWITCH_END_HOUR"),
                    min        = getSetting("AUTO_PRESET_SWITCH_END_MIN"),
                    ok_text    = _("Set time"),
                    callback = function(time)
                        PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_END_HOUR, time.hour)
                        PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_END_MIN, time.min)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
    }
end

local management_menu_tables = {}

-- Shared helpers

local function markPresetListForRefresh(hide_save_options)
    local parent_table = management_menu_tables[hide_save_options == true]
    if parent_table then
        parent_table.needs_refresh = true
    end
end

local function getPresetContext()
    local preset_obj = initializePresetSystem()

    if not preset_obj._loadPreset_wrapped then
        local original_loadPreset = preset_obj.loadPreset
        preset_obj.loadPreset = function(preset, preset_name)
            original_loadPreset(preset, preset_name)
            if not preset_name then
                for name, data in pairs(preset_obj.presets) do
                    if data == preset then preset_name = name; break end
                end
            end
            if preset_name then
                PresetStore:saveSetting(SETTINGS.LAST_LOADED_PRESET, preset_name)
            end
        end
        preset_obj._loadPreset_wrapped = true
    end

    local current_preset_name = _("None")
    local last_loaded = PresetStore:readSetting(SETTINGS.LAST_LOADED_PRESET)
    if last_loaded and preset_obj.presets[last_loaded] then
        current_preset_name = last_loaded
    end

    return preset_obj, current_preset_name
end

local function buildActivePresetLine(current_preset_name, help_text, separator)
    if separator == nil then separator = true end
    local active_preset_text = _("Active preset: ") .. current_preset_name

    if PluginStore:isTrue(SETTINGS.AUTO_PRESET_SWITCH_ENABLED) then
        local day_name   = config.getSetting("AUTO_PRESET_SWITCH_DAY_PRESET")
        local night_name = config.getSetting("AUTO_PRESET_SWITCH_NIGHT_PRESET")
        if current_preset_name == day_name then
            active_preset_text = active_preset_text .. _(" (auto-switch: day)")
        elseif current_preset_name == night_name then
            active_preset_text = active_preset_text .. _(" (auto-switch: night)")
        end
    end

    return {
        text           = h.icons.label(h.icons.ACTIVE, active_preset_text),
        help_text      = help_text,
        keep_menu_open = true,
        callback       = function() end,
        separator      = separator,
    }
end

-- Preview-from-hold-dialog

local function previewHeldPreset(po, held_preset_name, ui)
    local preset_data = po.presets[held_preset_name]
    if not preset_data then return end

    local original_snapshot = captureCurrentSettings()

    for _, setting_key in ipairs(getAllSettingKeys()) do
        PluginStore:delSetting(setting_key)
    end
    for setting_key, value in pairs(preset_data) do
        PluginStore:saveSetting(setting_key, value)
    end

    local widget, err, saved_rotation, night_mode_state = buildSleepScreenPreviewWidget(ui)

    for _, setting_key in ipairs(getAllSettingKeys()) do
        PluginStore:delSetting(setting_key)
    end
    for setting_key, value in pairs(original_snapshot) do
        PluginStore:saveSetting(setting_key, value)
    end

    if not widget then
        UIManager:show(require("ui/widget/infomessage"):new { text = err })
        return
    end
    showSleepScreenPreviewWidget(widget, saved_rotation, night_mode_state)
end

local function confirmPreviewBuiltinPreset(po, preset_name, ui)
    UIManager:show(ConfirmBox:new {
        text        = string.format(_("Preview preset '%s'?"), preset_name),
        icon        = "notice-question",
        ok_text     = _("Preview"),
        ok_callback = function() previewHeldPreset(po, preset_name, ui) end,
    })
end

-- Hold dialog wiring (rename/delete/update/preview)

local function wirePresetItemRefresh(item, hide_save_options, refresh_fn, ui)
    local original_callback = item.callback
    if original_callback then
        item.callback = function(touchmenu_instance)
            original_callback(touchmenu_instance)
            markPresetListForRefresh(hide_save_options)
            if touchmenu_instance then
                touchmenu_instance.item_table = refresh_fn()
                touchmenu_instance:updateItems()
            end
        end
    end
    if item.hold_callback then
        local held_preset_name = item.text
        item.hold_callback = function(touchmenu_instance, _menu_item)
            local last_before = PresetStore:readSetting(SETTINGS.LAST_LOADED_PRESET)
            local po          = initializePresetSystem()

            local function refreshMenu()
                markPresetListForRefresh(hide_save_options)
                if touchmenu_instance then
                    UIManager:scheduleIn(0.1, function()
                        touchmenu_instance.item_table = refresh_fn()
                        touchmenu_instance:updateItems()
                    end)
                end
            end

            local ButtonDialog = require("ui/widget/buttondialog")
            local dialog
            dialog = ButtonDialog:new {
                title       = string.format(_("What would you like to do with preset '%s'?"), held_preset_name),
                title_align = "center",
                buttons = {
                    {
                        {
                            text = _("Delete"),
                            callback = function()
                                UIManager:close(dialog)
                                UIManager:show(ConfirmBox:new {
                                    text        = string.format(_("Are you sure you want to delete preset '%s'?"), held_preset_name),
                                    ok_text     = _("Delete"),
                                    ok_callback = function()
                                        po.presets[held_preset_name] = nil
                                        saveUserPresets(po.presets)
                                        if last_before == held_preset_name then
                                            local default_data = po.presets["Default Day"]
                                                or presets_mod.getDefaultSettings()
                                            po.loadPreset(default_data, "Default Day")
                                        end
                                        
                                        if getSetting("AUTO_PRESET_SWITCH_DAY_PRESET") == held_preset_name then
                                            PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_DAY_PRESET, "Default Day")
                                        end
                                        if getSetting("AUTO_PRESET_SWITCH_NIGHT_PRESET") == held_preset_name then
                                            PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_NIGHT_PRESET, "Default Night")
                                        end
                                        refreshMenu()
                                    end,
                                })
                            end,
                        },
                        {
                            text = _("Rename"),
                            callback = function()
                                UIManager:close(dialog)
                                Presets.editPresetName({
                                    title               = _("Enter new preset name"),
                                    initial_value       = held_preset_name,
                                    confirm_button_text = _("Rename"),
                                }, po, function(new_name)
                                    po.presets[new_name] = po.presets[held_preset_name]
                                    po.presets[held_preset_name] = nil
                                    saveUserPresets(po.presets)
                                    if last_before == held_preset_name then
                                        PresetStore:saveSetting(SETTINGS.LAST_LOADED_PRESET, new_name)
                                    end
                                    
                                    if getSetting("AUTO_PRESET_SWITCH_DAY_PRESET") == held_preset_name then
                                        PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_DAY_PRESET, new_name)
                                    end
                                    if getSetting("AUTO_PRESET_SWITCH_NIGHT_PRESET") == held_preset_name then
                                        PluginStore:saveSetting(SETTINGS.AUTO_PRESET_SWITCH_NIGHT_PRESET, new_name)
                                    end
                                    refreshMenu()
                                end)
                            end,
                        },
                    },
                    {
                        {
                            text = _("Preview"),
                            callback = function()
                                UIManager:close(dialog)
                                previewHeldPreset(po, held_preset_name, ui)
                            end,
                        },
                        {
                            text = _("Update"),
                            callback = function()
                                UIManager:close(dialog)
                                UIManager:show(ConfirmBox:new {
                                    text = string.format(_("Are you sure you want to overwrite preset '%s' with current settings?"), held_preset_name),
                                    ok_callback = function()
                                        po.presets[held_preset_name] = po.buildPreset()
                                        saveUserPresets(po.presets)
                                        UIManager:show(require("ui/widget/infomessage"):new {
                                            text    = string.format(_("Preset '%s' was updated with current settings"), held_preset_name),
                                            timeout = 2,
                                        })
                                        refreshMenu()
                                    end,
                                })
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
        end
    end
end

-- Built-in & custom preset lists

local function buildBuiltinPresetsMenu(hide_save_options, ui)
    local preset_obj, current_preset_name = getPresetContext()
    local preset_menu_items = Presets.genPresetMenuItemTable(
        preset_obj, _("Save current settings as new preset"), nil)

    local builtin_presets, default_item, default_night_item = {}, nil, nil
    for _, item in ipairs(preset_menu_items) do
        if item.text and not item.separator and PRELOADED_PRESETS[item.text] then
            item.hold_callback        = nil
            item.hold_may_update_menu = nil
            if item.text == "Default Day" then default_item = item
            elseif item.text == "Default Night" then default_night_item = item
            else table.insert(builtin_presets, item) end
        end
    end

    local refresh_fn = function() return buildBuiltinPresetsMenu(hide_save_options, ui) end
    local menu_items = { buildActivePresetLine(current_preset_name,
        _("Hold a preset below to preview it.")) }

    if default_item then
        wirePresetItemRefresh(default_item, hide_save_options, refresh_fn, ui)
        default_item.hold_callback = function() confirmPreviewBuiltinPreset(preset_obj, "Default Day", ui) end
        menu_items[#menu_items + 1] = default_item
    end
    if default_night_item then
        wirePresetItemRefresh(default_night_item, hide_save_options, refresh_fn, ui)
        default_night_item.hold_callback = function() confirmPreviewBuiltinPreset(preset_obj, "Default Night", ui) end
        menu_items[#menu_items + 1] = default_night_item
    end
    table.sort(builtin_presets, function(a, b) return a.text < b.text end)
    for _, item in ipairs(builtin_presets) do
        wirePresetItemRefresh(item, hide_save_options, refresh_fn, ui)
        local preset_name = item.text
        item.hold_callback = function() confirmPreviewBuiltinPreset(preset_obj, preset_name, ui) end
        menu_items[#menu_items + 1] = item
    end

    return menu_items
end

local function buildCustomPresetsMenu(hide_save_options, ui)
    local preset_obj, current_preset_name = getPresetContext()
    local preset_menu_items = Presets.genPresetMenuItemTable(
        preset_obj, _("Save current settings as new preset"), nil)

    local custom_presets = {}
    for _, item in ipairs(preset_menu_items) do
        if item.text and not item.separator and not PRELOADED_PRESETS[item.text] then
            table.insert(custom_presets, item)
        end
    end

    local refresh_fn = function() return buildCustomPresetsMenu(hide_save_options, ui) end
    local menu_items = { buildActivePresetLine(current_preset_name,
        _("Hold a custom preset below to preview, update, rename, or delete it.")) }

    if #custom_presets == 0 then
        menu_items[#menu_items + 1] = { text = _("No custom presets currently saved"), enabled = false }
    else
        table.sort(custom_presets, function(a, b) return a.text < b.text end)
        for _, item in ipairs(custom_presets) do
            wirePresetItemRefresh(item, hide_save_options, refresh_fn, ui)
            menu_items[#menu_items + 1] = item
        end
    end

    return menu_items
end

-- Top-level Presets menu

local function buildPresetManagementMenu(hide_save_options, ui)
    local preset_obj, current_preset_name = getPresetContext()
    local menu_items = {}

    if not hide_save_options then
        menu_items[#menu_items + 1] = buildActivePresetLine(current_preset_name, nil, false)
        menu_items[#menu_items + 1] = h.buildPreviewMenuItem(ui)

        menu_items[#menu_items + 1] = {
            text           = _("Save current settings as new preset"),
            help_text      = _("Save your current sleep screen settings as a new custom preset."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local po = initializePresetSystem()
                Presets.editPresetName({}, po, function(entered_name)
                    po.presets[entered_name] = po.buildPreset()
                    saveUserPresets(po.presets)
                    po.loadPreset(po.presets[entered_name], entered_name)
                    if touchmenu_instance then
                        touchmenu_instance.item_table = buildPresetManagementMenu(hide_save_options, ui)
                        touchmenu_instance:updateItems()
                    end
                end)
            end,
        }

        menu_items[#menu_items + 1] = {
            text      = _("Automatic preset switching"),
            help_text = _("Automatically switch between two presets - e.g. a light one by day and a dark one at night."),
            sub_item_table_func = function()
                return buildAutoPresetSwitchMenu()
            end,
            separator = true,
        }

        menu_items[#menu_items + 1] = {
            text      = _("Built-in Presets"),
            help_text = _("Load one of the built-in presets."),
            sub_item_table_func = function()
                return buildBuiltinPresetsMenu(hide_save_options, ui)
            end,
        }
        menu_items[#menu_items + 1] = {
            text      = _("Your Custom Presets"),
            help_text = _("Load, rename, update or delete one of your saved presets."),
            sub_item_table_func = function()
                return buildCustomPresetsMenu(hide_save_options, ui)
            end,
        }
    else
        local preset_menu_items = Presets.genPresetMenuItemTable(
            preset_obj, _("Save current settings as new preset"), nil)

        local builtin_presets, custom_presets = {}, {}
        local default_item, default_night_item = nil, nil
        for _, item in ipairs(preset_menu_items) do
            if item.text and not item.separator then
                local preset_name = item.text
                local is_builtin  = PRELOADED_PRESETS[preset_name] ~= nil
                if is_builtin then
                    item.hold_callback        = nil
                    item.hold_may_update_menu = nil
                end
                if preset_name == "Default Day" then default_item = item
                elseif preset_name == "Default Night" then default_night_item = item
                elseif is_builtin then table.insert(builtin_presets, item)
                else table.insert(custom_presets, item) end
            end
        end

        local refresh_fn = function() return buildPresetManagementMenu(hide_save_options, ui) end
        if default_item then
            wirePresetItemRefresh(default_item, hide_save_options, refresh_fn, ui)
            default_item.hold_callback = function() confirmPreviewBuiltinPreset(preset_obj, "Default Day", ui) end
            menu_items[#menu_items + 1] = default_item
        end
        if default_night_item then
            wirePresetItemRefresh(default_night_item, hide_save_options, refresh_fn, ui)
            default_night_item.hold_callback = function() confirmPreviewBuiltinPreset(preset_obj, "Default Night", ui) end
            menu_items[#menu_items + 1] = default_night_item
        end
        table.sort(builtin_presets, function(a, b) return a.text < b.text end)
        for _, item in ipairs(builtin_presets) do
            wirePresetItemRefresh(item, hide_save_options, refresh_fn, ui)
            local preset_name = item.text
            item.hold_callback = function() confirmPreviewBuiltinPreset(preset_obj, preset_name, ui) end
            menu_items[#menu_items + 1] = item
        end
        table.sort(custom_presets, function(a, b) return a.text < b.text end)
        for _, item in ipairs(custom_presets) do
            wirePresetItemRefresh(item, hide_save_options, refresh_fn, ui)
            menu_items[#menu_items + 1] = item
        end
    end

    menu_items.refresh_func = function()
        return buildPresetManagementMenu(hide_save_options, ui)
    end
    management_menu_tables[hide_save_options == true] = menu_items

    return menu_items
end

return {
    buildPresetManagementMenu = buildPresetManagementMenu,
}
