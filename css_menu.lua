-- Assembles the top-level settings menu and its submenus.

local UIManager       = require("ui/uimanager")

local _               = require("gettext")
local config          = require("css_config")
local SETTINGS        = config.SETTINGS
local USER_CONFIG     = config.USER_CONFIG

local meta            = package.loaded["customisablesleepscreen/_meta"] or require("_meta")
local PATCH_VERSION   = meta.version
local GITHUB_REPO     = meta.github

local css_settings = require("css_settings")
local PluginStore  = css_settings.plugin()

local h                     = require("css_menu_helpers")
local getSetting            = h.getSetting
local createSpinDialog      = h.createSpinDialog
local createRadioItem       = h.createRadioItem
local buildPreviewMenuItem  = h.buildPreviewMenuItem
local buildNumericMenu      = h.buildNumericMenu

local presets_mod               = require("css_menu_presets")
local buildPresetManagementMenu = presets_mod.buildPresetManagementMenu

local sections_mod      = require("css_menu_sections")
local buildContentsMenu = sections_mod.buildContentsMenu

local appearance_mod            = require("css_menu_appearance")
local buildLayoutAndSpacingMenu = appearance_mod.buildLayoutAndSpacingMenu
local buildColorsIconsBarsMenu  = appearance_mod.buildColorsIconsBarsMenu
local buildFontsAndTextMenu     = appearance_mod.buildFontsAndTextMenu
local buildBackgroundMenu       = appearance_mod.buildBackgroundMenu

local icons     = h.icons
local iconLabel = icons.label

local has_warned_missing_symbols_font = false

local function warnIfSymbolsFontMissing()
    if has_warned_missing_symbols_font then return end
    has_warned_missing_symbols_font = true
    if h.isSymbolsFontAvailable() then return end
    UIManager:show(require("ui/widget/infomessage"):new {
        text = _("Menu icons are hidden because KOReader's bundled fonts/nerdfonts/symbols.ttf couldn't be found. Restore that font file to bring the menu icons back."),
        timeout = 6,
    })
end

local function isFmAltModeEnabled()
    return PluginStore:isTrue(SETTINGS.FM_ALT_MODE)
end

local function isFmBgTypeEnabled(bg_type)
    return function()
        return isFmAltModeEnabled() and getSetting("FM_BG_TYPE") == bg_type
    end
end

local function isFmBgImageBased()
    local bg_type = getSetting("FM_BG_TYPE")
    return isFmAltModeEnabled() and (bg_type == "custom" or bg_type == "folder")
end

local function isFmBgImageBasedNotStretched()
    return isFmBgImageBased() and not getSetting("FM_BG_STRETCH")
end

local function buildFileManagerBackgroundMenu()
    local bg_type_options = {
        { text = _("Transparent"),              val = "transparent" },
        { text = _("Solid colour"),             val = "solid"       },
        { text = _("Custom image"),             val = "custom"      },
        { text = _("Random image from folder"), val = "folder"      },
    }
    local radio_items = buildNumericMenu("FM_BG_TYPE", bg_type_options)

    local item_after_type = {
        solid  = h.createColorMenuItem(
            _("File manager background colour"),
            SETTINGS.FM_BG_SOLID_COLOR, USER_CONFIG.FM_BG_SOLID_COLOR,
            _("Colour for the alternative file manager background. Independent of your presets - stays the same no matter which preset is active."),
            isFmBgTypeEnabled("solid")
        ),
        custom = h.createImagePathPickerItem(
            _("File manager background image path"),
            _("Choose a single image to use as the alternative file manager background. Independent of your presets - stays the same no matter which preset is active."),
            SETTINGS.FM_BG_IMAGE_PATH, isFmBgTypeEnabled("custom")
        ),
        folder = h.createFolderPickerItem(
            _("File manager background folder path"),
            _("Choose a folder to pick a random image from as the alternative file manager background. Independent of your presets - stays the same no matter which preset is active."),
            SETTINGS.FM_BG_FOLDER, isFmBgTypeEnabled("folder")
        ),
    }

    local sub_menu = {}
    for i, item in ipairs(radio_items) do
        sub_menu[#sub_menu + 1] = item
        local extra = item_after_type[bg_type_options[i].val]
        if extra then sub_menu[#sub_menu + 1] = extra end
    end

    sub_menu[#sub_menu + 1] = {
        text      = _("Stretch image to fill"),
        help_text = _("When disabled, the image will be scaled to fit within the screen while preserving aspect ratio. Independent of your presets - stays the same no matter which preset is active."),
        enabled_func = isFmBgImageBased,
        checked_func = function() return getSetting("FM_BG_STRETCH") end,
        callback = function()
            PluginStore:saveSetting(SETTINGS.FM_BG_STRETCH, not getSetting("FM_BG_STRETCH"))
        end,
    }

    sub_menu[#sub_menu + 1] = h.createColorMenuItem(
        _("Fill colour"),
        SETTINGS.FM_BG_COVER_FILL_COLOR, USER_CONFIG.FM_BG_COVER_FILL_COLOR,
        _("Background colour for the image when not stretched. Independent of your presets - stays the same no matter which preset is active."),
        isFmBgImageBasedNotStretched
    )

    sub_menu[#sub_menu + 1] = {
        text      = _("Image alignment"),
        help_text = _("Horizontal alignment of the image when not stretched. Independent of your presets - stays the same no matter which preset is active."),
        enabled_func = isFmBgImageBasedNotStretched,
        sub_item_table = {
            createRadioItem(_("Left"),   nil, SETTINGS.FM_BG_COVER_ALIGN, "left"),
            createRadioItem(_("Centre"), nil, SETTINGS.FM_BG_COVER_ALIGN, "center"),
            createRadioItem(_("Right"),  nil, SETTINGS.FM_BG_COVER_ALIGN, "right"),
        },
    }

    return sub_menu
end

local function buildOutsideOfBookMenu()
    return {
        {
            text      = _("Show alternative sleep screen (no infobox)"),
            help_text = _("When disabled (default), the regular customisable sleep screen displays in file manager using the last saved book data. When enabled, a simpler alternative is shown instead - just a background, with no information box."),
            checked_func = isFmAltModeEnabled,
            callback = function()
                PluginStore:saveSetting(SETTINGS.FM_ALT_MODE, not isFmAltModeEnabled())
            end,
        },
        {
            text         = _("File manager background"),
            help_text    = _("What to show as the background for the alternative file manager sleep screen. This background is independent of your presets, so it looks the same no matter which preset was last active. Only selectable when \"Show alternative sleep screen\" is turned on."),
            enabled_func = isFmAltModeEnabled,
            sub_item_table = buildFileManagerBackgroundMenu(),
        },
    }
end

-- Global settings submenu

local function buildGlobalSettingsMenu()
    return {
        {
            text      = _("Flash screen to reduce ghosting"),
            help_text = _("Flashes the screen to black before showing the sleep screen, clearing residual text/image ghosting. Off by default, since not every device shows this ghosting."),
            keep_menu_open = true,
            checked_func = function()
                return PluginStore:isTrue(SETTINGS.ANTI_GHOSTING_FLASH)
            end,
            callback = function()
                PluginStore:saveSetting(SETTINGS.ANTI_GHOSTING_FLASH, not PluginStore:isTrue(SETTINGS.ANTI_GHOSTING_FLASH))
            end,
        },
        {
            text      = _("Sleep screen in file manager"),
            help_text = _("Control what the sleep screen looks like when triggered from the file manager, outside of a book."),
            sub_item_table = buildOutsideOfBookMenu(),
        },
        {
            text      = _("Export sleep screen to file"),
            help_text = _("Saves a screenshot of the sleep screen to a file each time a book is closed. Useful for devices that use an exported image as their own native sleep screen."),
            sub_item_table = {
                {
                    text      = _("Enable export"),
                    help_text = _("When enabled, a screenshot of the sleep screen will be saved in the selected export folder each time you close a book or put the device to sleep, using the format set below."),
                    keep_menu_open = true,
                    checked_func = function()
                        return PluginStore:isTrue(SETTINGS.EXPORT_ENABLED)
                    end,
                    callback = function(touchmenu_instance)
                        if PluginStore:isTrue(SETTINGS.EXPORT_ENABLED) then
                            PluginStore:saveSetting(SETTINGS.EXPORT_ENABLED, false)
                            UIManager:show(require("ui/widget/infomessage"):new {
                                text    = _("Sleep screen export disabled."),
                                timeout = 2,
                            })
                        else
                            local path = PluginStore:readSetting(SETTINGS.EXPORT_PATH)
                            if not path or path == "" then
                                UIManager:show(require("ui/widget/infomessage"):new {
                                    text    = _("No export folder set. Please set an export folder first."),
                                    timeout = 3,
                                })
                            else
                                PluginStore:saveSetting(SETTINGS.EXPORT_ENABLED, true)
                                local filename = PluginStore:readSetting(SETTINGS.EXPORT_FILENAME) or USER_CONFIG.EXPORT_FILENAME
                                local format   = PluginStore:readSetting(SETTINGS.EXPORT_FORMAT) or "jpg"
                                UIManager:show(require("ui/widget/infomessage"):new {
                                    text    = string.format(
                                        _("Sleep screen will be exported to:\n%s/%s.%s"),
                                        path, filename, format),
                                    timeout = 3,
                                })
                            end
                        end
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
                {
                    text      = _("Set export filename"),
                    help_text = _("Choose the filename used for the exported image (without extension)."),
                    enabled_func   = function() return PluginStore:isTrue(SETTINGS.EXPORT_ENABLED) end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local InputDialog = require("ui/widget/inputdialog")
                        local current_filename = PluginStore:readSetting(SETTINGS.EXPORT_FILENAME) or USER_CONFIG.EXPORT_FILENAME
                        local dialog
                        dialog = InputDialog:new {
                            title      = _("Export filename"),
                            input      = current_filename,
                            input_hint = USER_CONFIG.EXPORT_FILENAME,
                            buttons    = {{
                                {
                                    text     = _("Cancel"),
                                    callback = function() UIManager:close(dialog) end,
                                },
                                {
                                    text             = _("Save"),
                                    is_enter_default = true,
                                    callback         = function()
                                        local val = dialog:getInputText()
                                        if val and val ~= "" then
                                            PluginStore:saveSetting(SETTINGS.EXPORT_FILENAME, val)
                                        end
                                        UIManager:close(dialog)
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                },
                            }},
                        }
                        UIManager:show(dialog)
                    end,
                },
                {
                    text_func = function()
                        local val = PluginStore:readSetting(SETTINGS.EXPORT_FORMAT)
                        local labels = { png = "PNG", jpg = "JPG", bmp = "BMP" }
                        return string.format(_("Export format: %s"), labels[val] or "JPG")
                    end,
                    help_text = _("Choose the image format and colour profile for the exported file."),
                    enabled_func   = function() return PluginStore:isTrue(SETTINGS.EXPORT_ENABLED) end,
                    sub_item_table = {
                        {
                            text      = _("Export in greyscale"),
                            help_text = _("Saves the exported image without colour, reducing file size for any format."),
                            keep_menu_open = true,
                            checked_func = function()
                                return PluginStore:isTrue(SETTINGS.EXPORT_GRAYSCALE)
                            end,
                            callback = function()
                                PluginStore:saveSetting(SETTINGS.EXPORT_GRAYSCALE,
                                    not PluginStore:isTrue(SETTINGS.EXPORT_GRAYSCALE))
                            end,
                        },
                        {
                            text      = _("JPG"),
                            help_text = _("Lossy. Smallest file size, quick save."),
                            checked_func = function()
                                local val = PluginStore:readSetting(SETTINGS.EXPORT_FORMAT)
                                return val == nil or val == "jpg"
                            end,
                            callback = function()
                                PluginStore:saveSetting(SETTINGS.EXPORT_FORMAT, "jpg")
                            end,
                            radio = true,
                        },
                        createRadioItem(_("PNG"), _("Lossless. Medium file size, slower save."), SETTINGS.EXPORT_FORMAT, "png"),
                        createRadioItem(_("BMP"), _("Uncompressed. Largest file size, quick save."), SETTINGS.EXPORT_FORMAT, "bmp"),
                    },
                },
                {
                    text      = _("Set export folder"),
                    help_text = _("Choose the folder where the exported image will be saved. Must be set before export can be enabled."),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local PathChooser = require("ui/widget/pathchooser")
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
                        local function restoreOnce()
                            if restored then return end
                            restored = true
                            FileChooser.show_hidden         = was_hidden
                            FileChooser.updateItems         = was_updateItems
                            FileChooser._recalculateDimen   = was_recalculateDimen
                            FileChooser._updateItemsBuildUI = was_updateItemsBuildUI
                            FileChooser.onCloseWidget       = was_onCloseWidget
                            G_reader_settings:saveSetting("lock_home_folder", was_lock_home)
                        end

                        UIManager:show(PathChooser:new {
                            select_directory = true,
                            select_file      = false,
                            show_files       = false,
                            path             = PluginStore:readSetting(SETTINGS.EXPORT_PATH) or "/",
                            onConfirm = function(dir_path)
                                restoreOnce()
                                PluginStore:saveSetting(SETTINGS.EXPORT_PATH, dir_path)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                UIManager:show(require("ui/widget/infomessage"):new {
                                    text    = string.format(
                                        _("Export folder set to:\n%s"),
                                        dir_path),
                                    timeout = 3,
                                })
                            end,
                            onCancel = function()
                                restoreOnce()
                            end,
                        })
                    end,
                },
            },
        },
        {
            text      = _("Battery time calculation"),
            help_text = _("Method used to estimate remaining battery life."),
            sub_item_table = {
                createRadioItem(
                    _("Since last charge"),
                    _("Uses combined awake and sleeping battery drain since last charge"),
                    SETTINGS.BATT_STAT_TYPE, "discharging"
                ),
                createRadioItem(
                    _("Awake since last charge"),
                    _("Uses only active reading battery drain (more conservative estimate)"),
                    SETTINGS.BATT_STAT_TYPE, "awake"
                ),
                createRadioItem(
                    _("Sleeping since last charge"),
                    _("Uses only sleep mode battery drain"),
                    SETTINGS.BATT_STAT_TYPE, "sleeping"
                ),
                createRadioItem(
                    _("Manual calculation"),
                    _("Use a custom battery drain rate (1-10% per hour)"),
                    SETTINGS.BATT_STAT_TYPE, "manual"
                ),
                {
                    text = _("Set manual drain rate"),
                    enabled_func = function()
                        return (getSetting("BATT_STAT_TYPE") or USER_CONFIG.BATT_STAT_TYPE) == "manual"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        createSpinDialog(
                            _("Battery drain rate (% per hour)"),
                            getSetting("BATT_MANUAL_RATE") or USER_CONFIG.BATT_MANUAL_RATE,
                            1, 10, 0.5,
                            function(val) PluginStore:saveSetting(SETTINGS.BATT_MANUAL_RATE, val) end,
                            _("Typical devices drain 1-5% per hour while reading."),
                            "%.1f"
                        )
                    end,
                },
            },
        },
        {
            text      = _("Daily statistics scope"),
            help_text = _("Controls whether today's reading time and page count applies to the current book only, or all books read today. Note: reading streak and weekly goal achievement always reflect all books regardless of this setting."),
            sub_item_table = {
                createRadioItem(
                    _("All books"),
                    _("Today's reading time and page count across all books read today"),
                    SETTINGS.GOAL_STAT_SCOPE, "all"
                ),
                createRadioItem(
                    _("Current book only"),
                    _("Today's reading time and page count for the current book only"),
                    SETTINGS.GOAL_STAT_SCOPE, "book"
                ),
            },
        },
    }
end

-- Root menu assembly

local function getCustomisableSleepScreenSettingsMenu(hide_presets, ui)
    warnIfSymbolsFontMissing()

    local menu_table = {}

    if not hide_presets then
        menu_table[#menu_table + 1] = {
            text      = iconLabel(icons.PRESETS, _("Presets")),
            help_text = _("Save, load, and manage presets."),
            sub_item_table_func = function()
                return buildPresetManagementMenu(nil, ui)
            end,
        }
    end

    menu_table[#menu_table + 1] = buildPreviewMenuItem(ui)

    menu_table[#menu_table + 1] = { text = iconLabel(icons.CONTENTS,   _("Contents")),              help_text = _("Control which sections appear and what information they display."),      sub_item_table = buildContentsMenu(ui)         }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.LAYOUT,     _("Layout, Spacing & Frame")), help_text = _("Position and size of the box, the gaps between sections, and its border, corner radius, and opacity."), sub_item_table = buildLayoutAndSpacingMenu(ui) }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.COLOURS,    _("Colours, Icons & Bars")), help_text = _("Customise section colours, icon appearance, and progress bar styling."), sub_item_table = buildColorsIconsBarsMenu(ui)  }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.FONTS,      _("Fonts & Text")),          help_text = _("Configure text appearance."),                                            sub_item_table = buildFontsAndTextMenu(ui)     }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.BACKGROUND, _("Background")),            help_text = _("Choose what appears behind the information box."),                       sub_item_table = buildBackgroundMenu(ui)       }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.GLOBAL, _("Global settings")),        help_text = _("File manager display, ghosting, export, battery estimation, and stats scope. Unlike the menus above, these settings don't change when you switch presets."), sub_item_table = buildGlobalSettingsMenu(),    separator = true }

    menu_table[#menu_table + 1] = {
        text = iconLabel(icons.ABOUT, _("About")),
        sub_item_table = {
            {
                text           = string.format(_("Version: %s"), PATCH_VERSION),
                keep_menu_open = true,
                callback       = function() end,
                separator      = true,
            },
            {
                text           = string.format(_("Author: %s"), GITHUB_REPO:match("^([^/]+)") or GITHUB_REPO),
                help_text      = string.format(_("https://github.com/%s"), GITHUB_REPO),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(require("ui/widget/infomessage"):new {
                        text    = string.format(_("GitHub:\nhttps://github.com/%s"), GITHUB_REPO),
                        timeout = 4,
                    })
                end,
            },
            {
                text           = _("Check for updates"),
                help_text      = _("Check GitHub for a newer release, and install it if one is available."),
                keep_menu_open = true,
                callback = function()
                    local ok, updater = pcall(require, "css_updater")
                    if ok and updater then
                        updater.check(PATCH_VERSION)
                    end
                end,
            },
        },
    }

    return menu_table
end

return {
    getCustomisableSleepScreenSettingsMenu = getCustomisableSleepScreenSettingsMenu,
    buildPresetManagementMenu              = buildPresetManagementMenu,
}
