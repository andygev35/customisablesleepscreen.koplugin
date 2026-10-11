-- Shared factory functions for building common menu item types.

local logger      = require("logger")
local Device      = require("device")
local UIManager   = require("ui/uimanager")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")

local _           = require("gettext")
local config      = require("css_config")
local SETTINGS    = config.SETTINGS
local getSetting  = config.getSetting

local css_settings = require("css_settings")
local PluginStore  = css_settings.plugin()
local PresetStore  = css_settings.presets()

local icons = {}

icons.PRESETS    = "\xEE\xA2\x92"   -- U+E892  content-save
icons.PREVIEW    = "\xEE\xA4\x9D"   -- U+E91D  file-find
icons.CONTENTS   = "\xEE\xA5\xB8"   -- U+E978  format-list-bulleted
icons.LAYOUT     = "\xEE\xB5\x94"   -- U+ED54  move-resize
icons.COLOURS    = "\xEE\xAB\x97"   -- U+EAD7  palette
icons.FONTS      = "\xEE\xB7\x94"   -- U+EDD4  format-font
icons.BACKGROUND = "\xEE\xA7\xA8"   -- U+E9E8  image
icons.GLOBAL     = "\xEF\x82\xAC"   -- U+F0AC  globe
icons.ABOUT      = "\xEE\xA7\xBC"   -- U+E9FC  information-outline
icons.RESET      = "\xEE\xAD\x98"   -- U+EB58  replay
icons.ACTIVE     = "\xEE\xB3\x9F"   -- U+ECDF  check-circle (the active preset)
icons.LOCK       = "\xEF\x80\xA3"   -- U+F023  lock.1 (same glyph as the PIN pad)

local symbols_font_available = nil

local function isSymbolsFontAvailable()
    if symbols_font_available == nil then
        symbols_font_available = false
        local ok, Font = pcall(require, "ui/font")
        if ok then
            local ok2, face = pcall(Font.getFace, Font, "nerdfonts/symbols.ttf", 16)
            symbols_font_available = ok2 and face ~= nil
        end
    end
    return symbols_font_available
end

function icons.label(glyph, text)
    if type(glyph) ~= "string" or glyph == "" then return text end
    if not isSymbolsFontAvailable() then return text end
    return glyph .. "  " .. text
end

local Screen = Device.screen

-- Preset & colour helpers

local function getActivePresetData()
    local ok, presets_mod = pcall(require, "css_presets")
    if not ok then return nil, nil end
    local preset_name = PresetStore:readSetting(SETTINGS.LAST_LOADED_PRESET)
    if not preset_name then return nil, nil end
    local preset_obj = presets_mod.getPresetObj()
    if not preset_obj or not preset_obj.presets then return nil, nil end
    local preset_data = preset_obj.presets[preset_name]
    return preset_data, preset_name
end

local function getColourWheelWidget()
    return require("css_colourwheelwidget")
end

local function hexToHSV(hex)
    hex = hex:gsub("#", "")
    local r, g, b
    if #hex == 6 then
        r = tonumber(hex:sub(1, 2), 16) / 255
        g = tonumber(hex:sub(3, 4), 16) / 255
        b = tonumber(hex:sub(5, 6), 16) / 255
    else
        return 0, 1, 1
    end
    local max   = math.max(r, g, b)
    local min   = math.min(r, g, b)
    local delta = max - min
    local v     = max
    local s     = max > 0 and delta / max or 0
    local h     = 0
    if delta > 0 then
        if     max == r then h = 60 * (((g - b) / delta) % 6)
        elseif max == g then h = 60 * (((b - r) / delta) + 2)
        else                 h = 60 * (((r - g) / delta) + 4) end
    end
    if h < 0 then h = h + 360 end
    return h, s, v
end

-- Menu-item factories: toggles, radios, colour pickers

local function createToggleItem(text, help_text, setting_key, default_value, separator, enabled_func)
    return {
        text      = text,
        help_text = help_text,
        enabled_func = enabled_func,
        checked_func = function()
            local val = PluginStore:readSetting(setting_key)
            return val == nil and (default_value or false) or val
        end,
        callback = function()
            local current = PluginStore:readSetting(setting_key)
            if current == nil then current = default_value or false end
            PluginStore:saveSetting(setting_key, not current)
        end,
        separator = separator,
    }
end

local function createFlipNilOrTrueItem(text, help_text, setting_key, separator)
    return {
        text      = text,
        help_text = help_text,
        checked_func = function()
            local val = PluginStore:readSetting(setting_key)
            return val == nil or val == true
        end,
        callback = function()
            PluginStore:flipNilOrTrue(setting_key)
        end,
        separator = separator,
    }
end

local function createFlipNilOrFalseItem(text, help_text, setting_key, separator)
    return {
        text      = text,
        help_text = help_text,
        checked_func = function()
            return PluginStore:isTrue(setting_key)
        end,
        callback = function()
            PluginStore:flipNilOrFalse(setting_key)
        end,
        separator = separator,
    }
end

local function createRadioItem(text, help_text, setting_key, value, enabled_func)
    return {
        text         = text,
        help_text    = help_text,
        enabled_func = enabled_func,
        checked_func = function()
            return PluginStore:readSetting(setting_key) == value
        end,
        callback = function()
            PluginStore:saveSetting(setting_key, value)
        end,
        radio = true,
    }
end

local function createColorMenuItem(name, setting_key, default_value, help_text, enabled_func)
    return {
        text           = name,
        help_text      = help_text,
        enabled_func   = enabled_func,
        keep_menu_open = true,
        callback = function()
            local saved_color   = PluginStore:readSetting(setting_key)
            local current_color = saved_color or default_value
            if not Device:isTouchDevice() then
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new {
                    title      = name,
                    input      = current_color,
                    input_hint = "#RRGGBB",
                    buttons = {{
                        {
                            text     = _("Cancel"),
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text             = _("Apply"),
                            is_enter_default = true,
                            callback         = function()
                                local text = dialog:getInputText()
                                if text and text:match("^#%x%x%x%x%x%x$") then
                                    PluginStore:saveSetting(setting_key, text:upper())
                                    UIManager:close(dialog)
                                    UIManager:setDirty(nil, "ui")
                                else
                                    UIManager:show(require("ui/widget/infomessage"):new {
                                        text    = _("Invalid hex code. Use format: #RRGGBB"),
                                        timeout = 2,
                                    })
                                end
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
                return
            end
            local h, s, v = hexToHSV(current_color)
            if not saved_color then v = 1 end
            local wheel = getColourWheelWidget():new({
                title_text      = name,
                hue             = h,
                saturation      = s,
                value           = v,
                callback = function(hex)
                    PluginStore:saveSetting(setting_key, hex)
                    UIManager:setDirty(nil, "ui")
                end,
                cancel_callback = function() UIManager:setDirty(nil, "ui") end,
            })
            UIManager:show(wheel)
        end,
    }
end

local function withUnlockedFileChooser(fn)
    local FileChooser = require("ui/widget/filechooser")
    local Menu_orig   = require("ui/widget/menu")

    local was_hidden             = FileChooser.show_hidden
    local was_lock_home          = G_reader_settings:readSetting("lock_home_folder")
    local was_updateItems        = FileChooser.updateItems
    local was_recalculateDimen   = FileChooser._recalculateDimen
    local was_updateItemsBuildUI = FileChooser._updateItemsBuildUI
    local was_onCloseWidget      = FileChooser.onCloseWidget

    FileChooser.show_hidden         = true
    FileChooser.updateItems         = Menu_orig.updateItems
    FileChooser._recalculateDimen   = Menu_orig._recalculateDimen
    FileChooser._updateItemsBuildUI = Menu_orig._updateItemsBuildUI
    FileChooser.onCloseWidget       = Menu_orig.onCloseWidget
    G_reader_settings:saveSetting("lock_home_folder", false)

    local restored = false
    local function restore()
        if restored then return end
        restored = true
        FileChooser.show_hidden         = was_hidden
        FileChooser.updateItems         = was_updateItems
        FileChooser._recalculateDimen   = was_recalculateDimen
        FileChooser._updateItemsBuildUI = was_updateItemsBuildUI
        FileChooser.onCloseWidget       = was_onCloseWidget
        G_reader_settings:saveSetting("lock_home_folder", was_lock_home)
    end

    fn(restore)
end

local function createImagePathPickerItem(text, help_text, setting_key, enabled_func)
    return {
        text           = text,
        help_text      = help_text,
        enabled_func   = enabled_func,
        keep_menu_open = true,
        callback = function()
            local PathChooser = require("ui/widget/pathchooser")
            withUnlockedFileChooser(function(restore)
                UIManager:show(PathChooser:new {
                    select_directory = false,
                    select_file      = true,
                    show_files       = true,
                    path             = PluginStore:readSetting(setting_key) or "/",
                    onConfirm = function(file_path)
                        restore()
                        local lower = file_path:lower()
                        if not (lower:match("%.png$") or lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.webp$")) then
                            UIManager:show(require("ui/widget/infomessage"):new {
                                text    = _("This doesn't look like a supported image file (png, jpg, or webp). No background will be shown."),
                                timeout = 3,
                            })
                        end
                        PluginStore:saveSetting(setting_key, file_path)
                    end,
                    onCancel = function() restore() end,
                })
            end)
        end,
    }
end

local function createFolderPickerItem(text, help_text, setting_key, enabled_func)
    return {
        text           = text,
        help_text      = help_text,
        enabled_func   = enabled_func,
        keep_menu_open = true,
        callback = function()
            local lfs         = require("libs/libkoreader-lfs")
            local PathChooser = require("ui/widget/pathchooser")
            withUnlockedFileChooser(function(restore)
                UIManager:show(PathChooser:new {
                    select_directory = true,
                    select_file      = false,
                    show_files       = false,
                    path             = PluginStore:readSetting(setting_key) or "/",
                    onConfirm = function(dir_path)
                        restore()
                        PluginStore:saveSetting(setting_key, dir_path)
                        local valid_extensions = { "%.png$", "%.jpg$", "%.jpeg$", "%.webp$" }
                        local has_images = false
                        pcall(function()
                            local scan_path = dir_path:gsub("/$", "")
                            for entry in lfs.dir(scan_path) do
                                local lower = entry:lower()
                                for _, ext in ipairs(valid_extensions) do
                                    if lower:match(ext) then
                                        has_images = true
                                        break
                                    end
                                end
                                if has_images then break end
                            end
                        end)
                        if not has_images then
                            UIManager:show(require("ui/widget/infomessage"):new {
                                text    = _("No images found in the selected folder. No background will be shown."),
                                timeout = 3,
                            })
                        end
                    end,
                    onCancel = function() restore() end,
                })
            end)
        end,
    }
end

-- Reset-to-default menu item

local RESET_STRINGS = {
    ["layout, spacing & frame"] = {
        menu    = _("Reset layout, spacing & frame settings to default"),
        confirm = _("Are you sure you want to reset layout, spacing & frame settings?"),
        done    = _("Layout, spacing & frame settings reset to defaults"),
    },
    ["contents"] = {
        menu    = _("Reset contents settings to default"),
        confirm = _("Are you sure you want to reset contents settings?"),
        done    = _("Contents settings reset to defaults"),
    },
    ["colours, icons & bars"] = {
        menu    = _("Reset colours, icons & bars settings to default"),
        confirm = _("Are you sure you want to reset colours, icons & bars settings?"),
        done    = _("Colours, icons & bars settings reset to defaults"),
    },
    ["fonts & text"] = {
        menu    = _("Reset fonts & text settings to default"),
        confirm = _("Are you sure you want to reset fonts & text settings?"),
        done    = _("Fonts & text settings reset to defaults"),
    },
    ["background"] = {
        menu    = _("Reset background settings to default"),
        confirm = _("Are you sure you want to reset background settings?"),
        done    = _("Background settings reset to defaults"),
    },
}

local function createResetMenuItem(section_name, settings_to_delete)
    local strings = RESET_STRINGS[section_name]
    if not strings then
        logger.warn("[CSS] createResetMenuItem: unknown section '" .. section_name .. "'")
        return nil
    end
    return {
        text           = icons.label(icons.RESET, strings.menu),
        help_text      = _("Reset the settings in this part of the menu to their defaults."),
        separator      = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local ConfirmBox  = require("ui/widget/confirmbox")
            local InfoMessage = require("ui/widget/infomessage")

            local preset_name = select(2, getActivePresetData())
            local source_label = preset_name and ("'" .. preset_name .. "' preset") or _("factory defaults")

            local box = ConfirmBox:new {
                text        = strings.confirm .. "\n\n" .. string.format(_("Values will be restored from: %s"), source_label),
                ok_text     = _("Reset"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    local active_preset = getActivePresetData()
                    if active_preset then

                        for _, setting_key in ipairs(settings_to_delete) do
                            local preset_val = active_preset[setting_key]
                            if preset_val ~= nil then
                                PluginStore:saveSetting(setting_key, preset_val)
                            else
                                PluginStore:delSetting(setting_key)
                            end
                        end
                    else
                        for _, setting_key in ipairs(settings_to_delete) do
                            PluginStore:delSetting(setting_key)
                        end
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new {
                        text    = strings.done .. " (" .. source_label .. ")",
                        timeout = 2,
                    })
                end,
            }
            UIManager:show(box)
        end,
    }
end

-- Dialog & numeric-menu factories

local function createSpinDialog(title, current_value, min_val, max_val, step, on_save, info_text, precision, hold_step)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new {
        title_text      = title,
        info_text       = info_text,
        value           = tonumber(current_value) or min_val,
        value_min       = min_val,
        value_max       = max_val,
        value_step      = step or 1,
        value_hold_step = hold_step or (step or 1) * 5,
        precision       = precision,
        callback = function(spin)
            on_save(spin.value)
        end,
    })
end

local function createTextInputDialog(title, current_value, on_save, allow_newline)
    local InputDialog = require("ui/widget/inputdialog")
    local box
    box = InputDialog:new {
        title  = title,
        input  = current_value,
        width  = Screen:getWidth() * 0.8,
        allow_newline = allow_newline or false,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(box) end },
            { text = _("Save"), is_enter_default = not allow_newline, callback = function()
                on_save(box:getInputText())
                UIManager:close(box)
            end },
        }},
    }
    UIManager:show(box)
    box:onShowKeyboard()
end

local function createNumericRadioMenu(setting_key, min_val, max_val, step, suffix, get_current_func)
    local options = {}
    suffix = suffix or ""
    local key_name = nil
    for k, v in pairs(SETTINGS) do
        if v == setting_key then key_name = k; break end
    end
    get_current_func = get_current_func or function()
        return getSetting(key_name or setting_key)
    end
    for val = min_val, max_val, step do
        options[#options + 1] = {
            text         = tostring(val) .. suffix,
            radio        = true,
            checked_func = function() return get_current_func() == val end,
            callback     = function() PluginStore:saveSetting(setting_key, val) end,
        }
    end
    return options
end

local function buildNumericMenu(setting_key, options)
    local sub_menu = {}
    for i, opt in ipairs(options) do
        sub_menu[i] = {
            text         = opt.text,
            checked_func = function() return getSetting(setting_key) == opt.val end,
            callback     = function() PluginStore:saveSetting(SETTINGS[setting_key], opt.val) end,
            radio        = true,
        }
    end
    return sub_menu
end

-- Sleep screen preview

local PreviewWidget = InputContainer:extend{}

function PreviewWidget:init()
    local Screen_ = Device.screen
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen_:getWidth(), h = Screen_:getHeight() }
    self[1] = self.widget
    self.modal    = true
    self.dithered = true
    self.ges_events = {}
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
end

function PreviewWidget:onTapClose()
    UIManager:close(self)
    return true
end

function PreviewWidget:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

function PreviewWidget:onCloseWidget()
    if self.saved_rotation ~= nil then
        Device.screen:setRotationMode(self.saved_rotation)
        self.saved_rotation = nil
    end
    if self.night_mode_state then
        require("css_infobox_render").restoreNightMode(self.night_mode_state)
        self.night_mode_state = nil
    end
end

local function showSleepScreenPreviewWidget(widget, saved_rotation, night_mode_state)
    UIManager:show(PreviewWidget:new{
        widget           = widget,
        saved_rotation   = saved_rotation,
        night_mode_state = night_mode_state,
    }, "full")
end

-- Preview what the sleep screen shows from the file manager

local function buildSleepScreenPreviewWidget(ui, as_file_manager)
    local ib = require("css_infobox")

    ib.freeTrackedBBs()
    collectgarbage("collect")

    local orientation_setting = PluginStore:readSetting(SETTINGS.SLEEP_ORIENTATION) or "auto"
    local saved_rotation = nil
    if orientation_setting ~= "auto" then
        saved_rotation = Screen:getRotationMode()
        if orientation_setting == "portrait" then
            Screen:setRotationMode(0)
        elseif orientation_setting == "landscape" then
            Screen:setRotationMode(1)
        elseif orientation_setting == "uportrait" then
            Screen:setRotationMode(2)
        elseif orientation_setting == "ulandscape" then
            Screen:setRotationMode(3)
        end
    end

    local function restoreRotation()
        if saved_rotation ~= nil then
            Screen:setRotationMode(saved_rotation)
            saved_rotation = nil
        end
    end

    local widget
    if as_file_manager and getSetting("FM_ALT_MODE") then
        widget = ib.buildFileManagerBackground()
    else
        local book_data
        local doc_ui, doc_state
        if not as_file_manager and ui and ui.document then
            doc_ui, doc_state = ui, ui.view and ui.view.state
            book_data = ib.collectBookData(doc_ui, doc_state)
        else
            book_data = ib.loadLastBookData()
        end

        if not book_data then
            restoreRotation()
            return nil, _("No book data available to preview yet.\n\nOpen a book and show the sleep screen at least once before previewing.")
        end

        widget = ib.buildInfoBox(doc_ui, doc_state, book_data)
    end
    if not widget then
        restoreRotation()
        return nil, _("Couldn't build a preview - check crash.log for details.")
    end

    local night_mode_state = require("css_infobox_render").suppressNightMode()

    return widget, nil, saved_rotation, night_mode_state
end

local function showSleepScreenPreview(ui)
    local widget, err, saved_rotation, night_mode_state = buildSleepScreenPreviewWidget(ui)
    if not widget then
        UIManager:show(require("ui/widget/infomessage"):new { text = err })
        return
    end
    showSleepScreenPreviewWidget(widget, saved_rotation, night_mode_state)
end

local function showFileManagerSleepScreenPreview()
    if not getSetting("FM_ALT_MODE") then
        UIManager:show(require("ui/widget/infomessage"):new {
            text = _("The alternative file manager sleep screen is not enabled. Turn on 'Show alternative sleep screen (no infobox)' to preview it."),
        })
        return
    end
    local widget, err, saved_rotation, night_mode_state = buildSleepScreenPreviewWidget(nil, true)
    if not widget then
        UIManager:show(require("ui/widget/infomessage"):new { text = err })
        return
    end
    showSleepScreenPreviewWidget(widget, saved_rotation, night_mode_state)
end

local function buildPreviewMenuItem(ui, separator)
    if separator == nil then separator = true end
    return {
        text           = icons.label(icons.PREVIEW, _("Preview sleep screen")),
        help_text      = _("Shows what the sleep screen currently looks like, without actually suspending the device."),
        keep_menu_open = true,
        callback       = function() showSleepScreenPreview(ui) end,
        separator      = separator,
    }
end

return {
    getSetting               = getSetting,
    hexToHSV                 = hexToHSV,
    getColourWheelWidget      = getColourWheelWidget,
    createToggleItem         = createToggleItem,
    createFlipNilOrTrueItem  = createFlipNilOrTrueItem,
    createFlipNilOrFalseItem = createFlipNilOrFalseItem,
    createRadioItem          = createRadioItem,
    createColorMenuItem      = createColorMenuItem,
    createImagePathPickerItem = createImagePathPickerItem,
    createFolderPickerItem    = createFolderPickerItem,
    createResetMenuItem      = createResetMenuItem,
    createSpinDialog         = createSpinDialog,
    createTextInputDialog    = createTextInputDialog,
    createNumericRadioMenu   = createNumericRadioMenu,
    buildNumericMenu         = buildNumericMenu,
    showSleepScreenPreviewWidget = showSleepScreenPreviewWidget,
    buildSleepScreenPreviewWidget = buildSleepScreenPreviewWidget,
    showSleepScreenPreview       = showSleepScreenPreview,
    showFileManagerSleepScreenPreview = showFileManagerSleepScreenPreview,
    buildPreviewMenuItem         = buildPreviewMenuItem,
    icons                        = icons,
    isSymbolsFontAvailable       = isSymbolsFontAvailable,
}
