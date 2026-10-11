-- Plugin entry point. Hooks into the KOReader screensaver and menu systems.

local _plugin_dir = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/"

if not package.path:find(_plugin_dir, 1, true) then
    package.path = _plugin_dir .. "?.lua;" .. package.path
end

require("css_l10n").install()

local logger                = require("logger")
local util                  = require("util")
local Device                = require("device")
local Dispatcher            = require("dispatcher")
local Screensaver           = require("ui/screensaver")
local UIManager             = require("ui/uimanager")
local ScreenSaverWidget     = require("ui/widget/screensaverwidget")
local WidgetContainer       = require("ui/widget/container/widgetcontainer")

local _           = require("gettext")
local config      = require("css_config")
local USER_CONFIG = config.USER_CONFIG
local SETTINGS    = config.SETTINGS

local css_settings = require("css_settings")

local meta = (loadfile(_plugin_dir .. "_meta.lua") or function() return {} end)()
package.loaded["customisablesleepscreen/_meta"] = meta

local PATCH_VERSION = meta.version
local Screen        = Device.screen

-- Lazy module accessors (avoid circular requires at load time)

local function getReaderUI()
    return package.loaded["apps/reader/readerui"]
end

local function getInfobox()
    return require("css_infobox")
end

local function getMenu()
    return require("css_menu")
end

local function getRender()
    return require("css_infobox_render")
end

local CustomisableSleepScreen = WidgetContainer:extend {
    name             = "customisablesleepscreen",
    _hooks_installed = false,
    _saved_rotation  = nil,
}

-- Settings migrations

local function parseVersion(v)
    if not v then return 0, 0, 0 end
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
    return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

local function versionLessThan(v, major, minor, patch)
    local a, b, c = parseVersion(v)
    if a ~= major then return a < major end
    if b ~= minor then return b < minor end
    return c < patch
end

local KOREADER_OWNED_KEYS = {
    [SETTINGS.TYPE]          = true,
    [SETTINGS.SHOW_MSG_GLOBAL] = true,
    [SETTINGS.MSG_TEXT]      = true,
}

local PRESET_STORE_KEYS = {
    [SETTINGS.PRESETS]           = true,
    [SETTINGS.CYCLE_INDEX]       = true,
    [SETTINGS.LAST_LOADED_PRESET] = true,
}

local function migrateFromGlobalSettings()
    local needs_migration = false
    for raw_key in pairs(G_reader_settings.data) do
        if type(raw_key) == "string"
            and raw_key:match("^customisable_ss_")
            and not KOREADER_OWNED_KEYS[raw_key] then
            needs_migration = true
            break
        end
    end
    if not needs_migration then return end

    local plugin_store = css_settings.plugin()
    local preset_store = css_settings.presets()

    for _, raw_key in pairs(SETTINGS) do
        if not KOREADER_OWNED_KEYS[raw_key] then
            local val = G_reader_settings:readSetting(raw_key)
            if val ~= nil then
                if PRESET_STORE_KEYS[raw_key] then
                    preset_store:saveSetting(raw_key, val)
                else
                    plugin_store:saveSetting(raw_key, val)
                end
                G_reader_settings:delSetting(raw_key)
            end
        end
    end

    local orphans = {}
    for raw_key in pairs(G_reader_settings.data) do
        if type(raw_key) == "string"
            and raw_key:match("^customisable_ss_")
            and not KOREADER_OWNED_KEYS[raw_key] then
            table.insert(orphans, raw_key)
        end
    end
    for _, raw_key in ipairs(orphans) do
        G_reader_settings:delSetting(raw_key)
    end

    G_reader_settings:delSetting("customisable_ss_presets_migrated")

    css_settings.flush()
    G_reader_settings:flush()
end

local function runMigrations(saved_version)
    local plugin_store = css_settings.plugin()
    local preset_store = css_settings.presets()

    if saved_version == nil then return end

    if versionLessThan(saved_version, 2, 2, 0) then
        local old_bold = plugin_store:readSetting("customisable_ss_book_title_bold")
        if old_bold ~= nil then
            plugin_store:saveSetting(SETTINGS.ALL_TITLES_BOLD, old_bold)
            plugin_store:delSetting("customisable_ss_book_title_bold")
        end
    end

    if versionLessThan(saved_version, 2, 3, 0) then
        if plugin_store:readSetting(SETTINGS.SHOW_BATT_DATE) == true then
            plugin_store:saveSetting(SETTINGS.SHOW_BATT_CLOCK, false)
        end
    end

    if versionLessThan(saved_version, 2, 4, 0) then
        if plugin_store:readSetting("customisable_ss_show_in_filemanager") == false then
            plugin_store:saveSetting(SETTINGS.FM_ALT_MODE, true)
            plugin_store:saveSetting(SETTINGS.FM_BG_TYPE, "transparent")
        end
        plugin_store:delSetting("customisable_ss_show_in_filemanager")

        if plugin_store:readSetting(SETTINGS.EXPORT_FORMAT) == nil then
            plugin_store:saveSetting(SETTINGS.EXPORT_FORMAT, "png")
        end
    end

    local renamed_presets = {
        ["Default"] = "Default Day",
        ["Night"]   = "Default Night",
    }
    local last_loaded = preset_store:readSetting(SETTINGS.LAST_LOADED_PRESET)
    if last_loaded and renamed_presets[last_loaded] then
        preset_store:saveSetting(SETTINGS.LAST_LOADED_PRESET, renamed_presets[last_loaded])
    end
end

-- Plugin lifecycle

function CustomisableSleepScreen:init()
    logger.info(string.format("[Customisable Sleep Screen] v%s initialised", PATCH_VERSION))

    migrateFromGlobalSettings()

    local plugin_store  = css_settings.plugin()
    local saved_version = plugin_store:readSetting(SETTINGS.VERSION)
    if saved_version ~= PATCH_VERSION then
        runMigrations(saved_version)
        plugin_store:saveSetting(SETTINGS.VERSION, PATCH_VERSION)

        local settings_to_init_if_missing = {
            "FONT_FACE_TITLE", "FONT_FACE_SUBTITLE", "FONT_SIZE_TITLE",
            "FONT_SIZE_SUBTITLE", "BATT_STAT_TYPE", "TEXT_ALIGN", "MSG_SHOW_FULL_BAR",
            "OPACITY", "GOAL_STAT_SCOPE", "POS", "BG_TYPE",
            "MESSAGE_SOURCE", "BG_COVER_FILL_COLOR",
            "GOAL_TYPE", "DAILY_GOAL_MINUTES", "GOAL_TITLE_TYPE",
            "SHOW_QUOTE_ATTRIBUTION", "SLEEP_ORIENTATION",
            "AUTO_PRESET_SWITCH_TRIGGER", "AUTO_PRESET_SWITCH_DAY_PRESET", "AUTO_PRESET_SWITCH_NIGHT_PRESET",
        }
        for _, key in ipairs(settings_to_init_if_missing) do
            if plugin_store:readSetting(SETTINGS[key]) == nil then
                plugin_store:saveSetting(SETTINGS[key], USER_CONFIG[key])
            end
        end
        css_settings.flush()
    end

    local function installBundledFonts()
        local lfs         = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local Font        = require("ui/font")

        local src_root = _plugin_dir .. "fonts"
        if lfs.attributes(src_root, "mode") ~= "directory" then return end

        local dst_dir = DataStorage:getDataDir() .. "/fonts"
        if lfs.attributes(dst_dir, "mode") ~= "directory" then
            lfs.mkdir(dst_dir)
        end

        local style_suffixes = {
            "%-Regular$",      "%-Bold$",           "%-Italic$",         "%-BoldItalic$",
            "%-Light$",        "%-Medium$",          "%-SemiBold$",       "%-ExtraBold$",
            "%-Thin$",         "%-Black$",           "%-ExtraLight$",     "%-LightItalic$",
            "%-MediumItalic$", "%-SemiBoldItalic$",  "%-BoldItalicalt$",
            "_Regular$",       "_Bold$",             "_Italic$",
        }
        local function filenameToFamilyName(filename)
            local base = filename:match("^(.+)%.[^%.]+$") or filename
            for _, suffix in ipairs(style_suffixes) do
                base = base:gsub(suffix, "")
            end

            base = base:gsub("(%l)(%u)", "%1 %2")
                       :gsub("(%u+)(%u%l)", "%1 %2")
            return base
        end

        local installed = {}

        local function processFont(src_path, filename)
            local ext = filename:match("%.([^%.]+)$")
            if not ext or not (ext == "ttf" or ext == "otf" or ext == "ttc") then return end

            local dst_path = dst_dir .. "/" .. filename

            if lfs.attributes(dst_path, "mode") ~= "file" then
                local src_f = io.open(src_path, "rb")
                if src_f then
                    local data = src_f:read("*a")
                    src_f:close()
                    local dst_f = io.open(dst_path, "wb")
                    if dst_f then
                        dst_f:write(data)
                        dst_f:close()
                    end
                end
            end

            local family    = filenameToFamilyName(filename)
            local is_regular = filename:lower():match("regular") ~= nil
            if not installed[family] or is_regular then
                installed[family] = filename
            end
        end

        local function walkFonts(dir)
            if lfs.attributes(dir, "mode") ~= "directory" then return end
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." and not entry:match("^%.") then
                    local full = dir .. "/" .. entry
                    local mode = lfs.attributes(full, "mode")
                    if mode == "file" then
                        processFont(full, entry)
                    elseif mode == "directory" then
                        walkFonts(full)
                    end
                end
            end
        end

        walkFonts(src_root)

        if Font.fontmap and next(installed) then
            for family, path in pairs(installed) do
                if not Font.fontmap[family] then
                    Font.fontmap[family] = path
                end
            end
        end

        local ok_fl, FontList = pcall(require, "fontlist")
        if ok_fl and FontList then
            FontList.font_list = nil
        end
    end
    pcall(installBundledFonts)

    if Dispatcher and Dispatcher.registerAction then
        Dispatcher:registerAction("customisable_ss_settings", {
            category = "none",
            event    = "ShowCustomisableSleepScreenSettings",
            title    = _("Customisable sleep screen settings"),
            general  = true,
        })
        Dispatcher:registerAction("customisable_ss_presets", {
            category = "none",
            event    = "ShowCustomisableSleepScreenPresets",
            title    = _("Customisable sleep screen presets"),
            general  = true,
        })
        Dispatcher:registerAction("cycle_customisable_ss_presets", {
            category = "none",
            event    = "CycleCustomisableSleepScreenPresets",
            title    = _("Cycle through customisable sleep screen presets"),
            general  = true,
        })
        Dispatcher:registerAction("customisable_ss_export_now", {
            category = "none",
            event    = "ExportCustomisableSleepScreenNow",
            title    = _("Export sleep screen now"),
            general  = true,
        })
    end

    self.ui.menu:registerToMainMenu(self)

    -- Forgot-PIN recovery
    if plugin_store:readSetting(SETTINGS.LOCK_PIN_HASH) ~= nil or plugin_store:isTrue(SETTINGS.LOCK_ENABLED) then
        pcall(function() require("css_lockscreen").applyResetFile() end)
    end

    if plugin_store:isTrue(SETTINGS.LOCK_ENABLED) and plugin_store:isTrue(SETTINGS.LOCK_ON_LAUNCH) then
        pcall(function() require("css_lockscreen").lockOnLaunch() end)
    end

    if not CustomisableSleepScreen._hooks_installed then
        self:_installScreensaverHook()
        CustomisableSleepScreen._hooks_installed = true
    end

    local self_ref = self

    self.onCloseDocument = function()
        self_ref:_cancelPeriodicExport()
        if config.getSetting("EXPORT_TRIGGER_CLOSE") then
            pcall(function() self_ref:_exportCurrentBookData() end)
        end
    end

    self.onReaderReady = function()
        if config.getSetting("EXPORT_TRIGGER_OPEN") then
            pcall(function() self_ref:_exportCurrentBookData() end)
        end
        self_ref:_schedulePeriodicExport()
    end

    self.onResume = function()
        self_ref:_schedulePeriodicExport()
    end

    self.onShowCustomisableSleepScreenSettings = function() return self_ref:_onShowSettings() end
    self.onShowCustomisableSleepScreenPresets  = function() return self_ref:_onShowPresets()  end
    self.onCycleCustomisableSleepScreenPresets = function() return self_ref:_onCyclePresets() end
    self.onExportCustomisableSleepScreenNow    = function() return self_ref:_onExportNow()    end
    self.onPowerOff = function()
        return self_ref:_onPowerOff()
    end
end

-- Screenshot export

function CustomisableSleepScreen:_exportToCoverImage(ui, state, book_data)

    if G_reader_settings:readSetting(SETTINGS.TYPE) ~= "customisable_ss" then
        return false
    end

    local plugin_store = css_settings.plugin()
    if not plugin_store:isTrue(SETTINGS.EXPORT_ENABLED) then return false end
    local export_path = plugin_store:readSetting(SETTINGS.EXPORT_PATH)
    if not export_path or export_path == "" then return false end

    local ib = getInfobox()

    local tracking_scope = ib.beginTrackingScope()
    local widget = ib.buildInfoBox(ui, state, book_data)

    if not widget then
        ib.endTrackingScope(tracking_scope)
        return false
    end

    local Blitbuffer     = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")

    local w  = Screen:getWidth()
    local h  = Screen:getHeight()

    local grayscale = plugin_store:isTrue(SETTINGS.EXPORT_GRAYSCALE)
    local bb_type = grayscale and Blitbuffer.TYPE_BB8 or Blitbuffer.TYPE_BBRGB32
    local ok_bb, bb = pcall(Blitbuffer.new, w, h, bb_type)
    if not ok_bb then
        logger.warn("[Customisable Sleep Screen] export failed: could not create blitbuffer: " .. tostring(bb))
        ib.endTrackingScope(tracking_scope)
        return false
    end

    local wrapped = FrameContainer:new {
        bordersize = 0,
        padding    = 0,
        widget,
    }
    local night_mode_state = getRender().suppressNightMode()
    wrapped:paintTo(bb, 0, 0)
    getRender().restoreNightMode(night_mode_state)

    local filename  = plugin_store:readSetting(SETTINGS.EXPORT_FILENAME) or USER_CONFIG.EXPORT_FILENAME
    local format    = plugin_store:readSetting(SETTINGS.EXPORT_FORMAT) or "jpg"
    export_path = export_path:gsub("/$", "") .. "/" .. filename .. "." .. format
    local ok = bb:writeToFile(export_path, format, 90, grayscale)
    if not ok then
        logger.warn("[Customisable Sleep Screen] export failed: could not write " .. tostring(export_path))
    else
        logger.info("[Customisable Sleep Screen] exported sleep screen to " .. tostring(export_path))
    end
    bb:free()

    ib.endTrackingScope(tracking_scope)
    return ok
end

function CustomisableSleepScreen:_exportCurrentBookData()
    local ReaderUI = getReaderUI()
    local ui       = ReaderUI and ReaderUI.instance
    local ib       = getInfobox()

    if ui and ui.document then
        if ui.statistics and ui.statistics.id_curr_book then
            local avg_time_before = ui.statistics.avg_time
            pcall(function() ui.statistics:insertDB(ui.statistics.id_curr_book) end)
            ui.statistics.avg_time = avg_time_before
        end

        if ui.doc_settings then
            pcall(function() ui.doc_settings:flush() end)
        end

        local state     = ui.view and ui.view.state
        local book_data = ib.collectBookData(ui, state)
        if book_data then
            ib.saveLastBookData(book_data)
            return self:_exportToCoverImage(ui, state, book_data)
        end
        return false
    else
        local book_data = ib.loadLastBookData()
        if book_data then
            return self:_exportToCoverImage(nil, nil, book_data)
        end
        return false
    end
end

-- Manual export gesture

function CustomisableSleepScreen:_onExportNow()
    local InfoMessage = require("ui/widget/infomessage")

    if G_reader_settings:readSetting(SETTINGS.TYPE) ~= "customisable_ss" then
        return true
    end

    local plugin_store = css_settings.plugin()
    if not plugin_store:isTrue(SETTINGS.EXPORT_ENABLED) then
        UIManager:show(InfoMessage:new {
            text    = _("Sleep screen export is turned off. Enable it under 'Export sleep screen to file' to use this."),
            timeout = 3,
        })
        return true
    end

    local ok = self:_exportCurrentBookData()
    UIManager:show(InfoMessage:new {
        text    = ok and _("Sleep screen exported.") or _("Export failed. Check that an export folder is set."),
        timeout = 2,
    })
    return true
end

-- Power-off hook

function CustomisableSleepScreen:_onPowerOff()
    if G_reader_settings:readSetting(SETTINGS.TYPE) ~= "customisable_ss" then return end

    pcall(function()
        local ib  = getInfobox()
        local ReaderUI = getReaderUI()
        local ui       = ReaderUI and ReaderUI.instance
        local widget   = nil

        local tracking_scope = ib.beginTrackingScope()

        if ui and ui.document then
            if ui.statistics and ui.statistics.id_curr_book then
                local avg_time_before = ui.statistics.avg_time
                pcall(function() ui.statistics:insertDB(ui.statistics.id_curr_book) end)
                ui.statistics.avg_time = avg_time_before
            end
            local state     = ui.view and ui.view.state
            local book_data = ib.collectBookData(ui, state)
            if book_data then
                ib.saveLastBookData(book_data)
                widget = ib.buildInfoBox(ui, state, book_data)
            end
        else
            local book_data = ib.loadLastBookData()
            if book_data then
                widget = ib.buildInfoBox(nil, nil, book_data)
            end
        end

        if not widget then
            ib.endTrackingScope(tracking_scope)
            return
        end

        local FrameContainer = require("ui/widget/container/framecontainer")
        local wrapped = FrameContainer:new {
            bordersize = 0,
            padding    = 0,
            widget,
        }
        local night_mode_state = getRender().suppressNightMode()
        wrapped:paintTo(Screen.bb, 0, 0)
        Screen:refreshFull()
        getRender().restoreNightMode(night_mode_state)
        ib.endTrackingScope(tracking_scope)
        ib.restorePatches()
    end)
end

-- KOReader menu integration

function CustomisableSleepScreen:addToMainMenu(menu_items)
    menu_items.customisable_sleep_screen = {
        text         = _("Customisable sleep screen"),
        sorting_hint = "screen",
        checked_func = function()
            return G_reader_settings:readSetting(SETTINGS.TYPE) == "customisable_ss"
        end,
        sub_item_table_func = function()
            local ok, menu_mod = pcall(require, "css_menu")
            local settings_items = (ok and type(menu_mod) == "table")
                and (function()
                    local ok2, items = pcall(menu_mod.getCustomisableSleepScreenSettingsMenu, false, self.ui)
                    if not ok2 then
                        logger.warn("[CSS] addToMainMenu: settings build failed: " .. tostring(items))
                    end
                    return ok2 and items or nil
                end)()
                or nil

            local enable_item = {
                text = _("Enable customisable sleep screen"),
                checked_func = function()
                    return G_reader_settings:readSetting(SETTINGS.TYPE) == "customisable_ss"
                end,
                callback = function()
                    if G_reader_settings:readSetting(SETTINGS.TYPE) == "customisable_ss" then
                        G_reader_settings:saveSetting(SETTINGS.TYPE, "disable")
                    else
                        G_reader_settings:saveSetting(SETTINGS.TYPE, "customisable_ss")
                    end
                end,
                separator = true,
            }

            if not settings_items then
                return { enable_item }
            end

            local function isEnabled()
                return G_reader_settings:readSetting(SETTINGS.TYPE) == "customisable_ss"
            end
            for _, item in ipairs(settings_items) do
                item.enabled_func = isEnabled
            end

            table.insert(settings_items, 1, enable_item)
            return settings_items
        end,
    }
end

-- Widget teardown & suspend

function CustomisableSleepScreen:onCloseWidget()
    if UIManager._entered_poweroff_stage then
        pcall(function() css_settings.flush() end)
        pcall(function() G_reader_settings:flush() end)
        return
    end

    self:_cancelPeriodicExport()

    if CustomisableSleepScreen._hooks_installed then
        pcall(function() self._screensaver_hook:revert() end)
        pcall(function() self._screensaver_close_hook:revert() end)
        pcall(function() self._screensaver_widget_close_hook:revert() end)
        CustomisableSleepScreen._hooks_installed = false
    end

    pcall(function()
        local ok, ib = pcall(require, "css_infobox")
        if ok then
            ib.freeTrackedBBs()
            ib.restorePatches()
        end
    end)

    pcall(function() css_settings.flush() end)
    pcall(function() G_reader_settings:flush() end)
end

-- Periodic export scheduling

function CustomisableSleepScreen:_cancelPeriodicExport()
    if self._periodic_export_action then
        UIManager:unschedule(self._periodic_export_action)
        self._periodic_export_action = nil
    end
end

function CustomisableSleepScreen:_schedulePeriodicExport()
    self:_cancelPeriodicExport()

    if G_reader_settings:readSetting(SETTINGS.TYPE) ~= "customisable_ss" then return end
    local plugin_store = css_settings.plugin()
    if not plugin_store:isTrue(SETTINGS.EXPORT_ENABLED) then return end
    if not plugin_store:isTrue(SETTINGS.EXPORT_TRIGGER_PERIODIC) then return end

    local minutes = plugin_store:readSetting(SETTINGS.EXPORT_TRIGGER_PERIODIC_MINUTES)
        or USER_CONFIG.EXPORT_TRIGGER_PERIODIC_MINUTES

    local self_ref = self
    self._periodic_export_action = function()
        pcall(function() self_ref:_exportCurrentBookData() end)
        self_ref:_schedulePeriodicExport()
    end
    UIManager:scheduleIn(minutes * 60, self._periodic_export_action)
end

function CustomisableSleepScreen:onSuspend()
    self:_cancelPeriodicExport()
    if config.getSetting("EXPORT_TRIGGER_SUSPEND") then
        pcall(function() self:_exportCurrentBookData() end)
    end
    pcall(function() css_settings.flush() end)
    pcall(function() G_reader_settings:flush() end)
end

-- Screensaver hook (the actual sleep-screen display logic)

function CustomisableSleepScreen:_installScreensaverHook()
    if not util.wrapMethod then
        logger.warn("[CSS] util.wrapMethod not available - screensaver hook cannot be installed")
        return
    end

    local css = self

    self._screensaver_close_hook = util.wrapMethod(Screensaver, "close", function(ss_self)
        if css._lock_gate then
            local gate = css._lock_gate
            if UIManager:isWidgetShown(gate) then
                local deferred = false
                pcall(function()
                    deferred = require("css_lockscreen").deferralApplies(css._lock_slept_at, css._lock_was_locked)
                end)
                if not deferred then
                    return
                end
                UIManager:close(gate)
            end
            css._lock_gate = nil
        end
        if css._saved_rotation ~= nil then
            Screen:setRotationMode(css._saved_rotation)
            css._saved_rotation = nil
        end
        return css._screensaver_close_hook:raw_call(ss_self)
    end)

    self._screensaver_widget_close_hook = util.wrapMethod(ScreenSaverWidget, "onCloseWidget", function(sw_self)
        if css._night_mode_state then
            getRender().restoreNightMode(css._night_mode_state)
            css._night_mode_state = nil
        end
        return css._screensaver_widget_close_hook:raw_call(sw_self)
    end)

    local function show_sleep_screen(ss_self)
        local screensaver_type = G_reader_settings:readSetting("screensaver_type")
        if screensaver_type ~= "customisable_ss" then
            return css._screensaver_hook:raw_call(ss_self)
        end
        if not Device.screen_saver_mode then
            css._saved_rotation = nil
        end
        local orientation_setting = css_settings.plugin():readSetting(SETTINGS.SLEEP_ORIENTATION) or "auto"
        if orientation_setting ~= "auto" then
            if css._saved_rotation == nil then
                css._saved_rotation = Screen:getRotationMode()
            end
            if orientation_setting == "portrait" then
                Screen:setRotationMode(0)
            elseif orientation_setting == "landscape" then
                Screen:setRotationMode(1)
            elseif orientation_setting == "uportrait" then
                Screen:setRotationMode(2)
            elseif orientation_setting == "ulandscape" then
                Screen:setRotationMode(3)
            end
        else
            css._saved_rotation = nil
        end

        pcall(function() require("css_auto_preset_switch").applyIfDue() end)

        if css_settings.plugin():isTrue(SETTINGS.ANTI_GHOSTING_FLASH) then
            pcall(function()
                if Device:hasEinkScreen() then
                    local Blitbuffer = require("ffi/blitbuffer")
                    local white = css_settings.plugin():readSetting(SETTINGS.ANTI_GHOSTING_FLASH_COLOR) == "white"
                    Screen.bb:fill(white and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
                    Screen:refreshFull(0, 0, Screen:getWidth(), Screen:getHeight())
                end
            end)
        end

        local ib = getInfobox()

        if ss_self.screensaver_widget then
            UIManager:close(ss_self.screensaver_widget)
            ss_self.screensaver_widget = nil
        end
        ib.freeTrackedBBs()
        collectgarbage("collect")

        local ReaderUI = getReaderUI()
        local ui       = ReaderUI and ReaderUI.instance
        local widget   = nil

        if ui and ui.document then

            if ui.statistics and ui.statistics.id_curr_book then
                local avg_time_before = ui.statistics.avg_time
                pcall(function() ui.statistics:insertDB(ui.statistics.id_curr_book) end)
                ui.statistics.avg_time = avg_time_before
            end

            if ui.doc_settings then
                pcall(function() ui.doc_settings:flush() end)
            end

            local state     = ui.view and ui.view.state
            local book_data = ib.collectBookData(ui, state)

            if book_data then
                ib.saveLastBookData(book_data)
                widget = ib.buildInfoBox(ui, state, book_data)
            end
        else
            local render_ref = require("css_infobox_render")
            local fm_alt_mode = render_ref.getSetting("FM_ALT_MODE")
            if fm_alt_mode then
                widget = ib.buildFileManagerBackground()
            else
                local book_data = ib.loadLastBookData()
                if book_data then
                    widget = ib.buildInfoBox(nil, nil, book_data)
                else
                    UIManager:show(require("ui/widget/infomessage"):new {
                        text    = _("Customisable Sleep Screen: no book data found.\n\nOpen a book and trigger the sleep screen at least once before it will work in the file manager."),
                    })
                end
            end
        end

        if not widget then return css._screensaver_hook:raw_call(ss_self) end

        pcall(function() require("css_infobox_background").keepSleepBackground() end)

        logger.info("[Customisable Sleep Screen] Sleep screen built successfully")

        css._night_mode_state = getRender().suppressNightMode()

        Device.screen_saver_mode = true
        UIManager:setIgnoreTouchInput(false)

        ss_self.screensaver_widget = ScreenSaverWidget:new {
            widget            = widget,
            covers_fullscreen = true,
        }

        ss_self.screensaver_widget.modal    = true
        ss_self.screensaver_widget.dithered = true

        UIManager:show(ss_self.screensaver_widget, "full")

        local screensaver_delay = G_reader_settings:readSetting("screensaver_delay")
        if screensaver_delay == "gesture" and ui and not css:_lockActive() then
            local ScreenSaverLockWidget = require("ui/widget/screensaverlockwidget")
            ss_self.screensaver_lock_widget = ScreenSaverLockWidget:new {
                ui = ui,
                onCloseWidget = function()
                    if ss_self.screensaver_widget then
                        UIManager:close(ss_self.screensaver_widget)
                        ss_self.screensaver_widget = nil
                    end
                end
            }
            ss_self.screensaver_lock_widget.showWaitForGestureMessage = function(this)
                this.is_infomessage_visible = true
            end
            UIManager:show(ss_self.screensaver_lock_widget)
        end
    end

    self._screensaver_hook = util.wrapMethod(Screensaver, "show", function(ss_self)
        local result = show_sleep_screen(ss_self)
        css:_installLockGate(ss_self)
        return result
    end)
end

-- Optional passcode lock

function CustomisableSleepScreen:_lockActive()
    local ok, active = pcall(function() return require("css_lockscreen").isEnabled() end)
    return ok and active == true
end

function CustomisableSleepScreen:_installLockGate(ss_self)
    if not self:_lockActive() then return end
    if not Device.screen_saver_mode then return end

    local css = self
    local ok, err = pcall(function()
        local lock = require("css_lockscreen")
        if css._lock_gate then
            UIManager:close(css._lock_gate)
            css._lock_gate = nil
        end
        local gate = lock.Gate:new {
            on_dismiss = function(g) css:_releaseLockGate(g, ss_self) end,
        }
        css._lock_gate = gate
        css._lock_slept_at  = os.time()
        css._lock_was_locked = lock.isUnlockPadShown()
        UIManager:show(gate)
    end)
    if not ok then
        logger.warn("[Customisable Sleep Screen] lock gate failed: " .. tostring(err))
        css._lock_gate = nil
    end
end

function CustomisableSleepScreen:_releaseLockGate(gate, ss_self)
    if self._lock_gate ~= gate then return end
    self._lock_gate = nil

    if self._saved_rotation ~= nil then
        Screen:setRotationMode(self._saved_rotation)
        self._saved_rotation = nil
    end

    local night_state = self._night_mode_state
    self._night_mode_state = nil

    UIManager:close(gate)
    local sleep_widget = ss_self.screensaver_widget
    if sleep_widget then
        sleep_widget:onClose()
    else
        ss_self:cleanup()
    end

    local ok, err = pcall(function() require("css_lockscreen").showUnlock(night_state) end)
    if not ok then
        logger.warn("[Customisable Sleep Screen] passcode pad failed: " .. tostring(err))
        if night_state then pcall(function() getRender().restoreNightMode(night_state) end) end
    end
end

-- Dispatcher actions (gestures/shortcuts)

function CustomisableSleepScreen:_onShowSettings()

    local ok, menu_mod = pcall(require, "css_menu")
    if not ok then
        logger.warn("[Customisable Sleep Screen] css_menu load error: " .. tostring(menu_mod))
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new { text = "CSS: menu load failed - check crash.log", timeout = 5 })
        return true
    end
    local ok2, result = pcall(menu_mod.getCustomisableSleepScreenSettingsMenu, true, self.ui)
    if not ok2 then
        logger.warn("[Customisable Sleep Screen] settings build error: " .. tostring(result))
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new { text = "CSS: settings build failed - check crash.log", timeout = 5 })
        return true
    end
    local menu_widget = require("ui/widget/menu"):new {
        title              = _("Customisable sleep screen settings"),
        item_table         = result,
        width              = Screen:getWidth(),
        height             = Screen:getHeight(),
        is_enable_shortcut = false,
    }
    UIManager:show(menu_widget)

    return true
end

function CustomisableSleepScreen:_onShowPresets()
    local ok, result = pcall(function()
        return getMenu().buildPresetManagementMenu(true, self.ui)
    end)
    if not ok then
        logger.warn("[Customisable Sleep Screen] presets build error: " .. tostring(result))
        return true
    end
    local menu_widget = require("ui/widget/menu"):new {
        title              = _("Customisable sleep screen presets"),
        item_table         = result,
        width              = Screen:getWidth(),
        height             = Screen:getHeight(),
        is_enable_shortcut = false,
    }
    UIManager:show(menu_widget)
    return true
end

function CustomisableSleepScreen:_onCyclePresets()
    local Presets = require("ui/presets")
    return Presets.cycleThroughPresets(require("css_presets").getPresetObj(), true)
end

-- Uninstall helper

function CustomisableSleepScreen:deletePluginSettings()
    local DataStorage  = require("datastorage")
    local settings_dir = DataStorage:getSettingsDir()

    if G_reader_settings:readSetting(SETTINGS.TYPE) == "customisable_ss" then
        G_reader_settings:saveSetting(SETTINGS.TYPE, "disable")
    end
    pcall(function() G_reader_settings:flush() end)
    pcall(function() css_settings.reset() end)
    os.remove(settings_dir .. "/customisablesleepscreen.lua")
    os.remove(settings_dir .. "/customisablesleepscreen_presets.lua")
end

return CustomisableSleepScreen
