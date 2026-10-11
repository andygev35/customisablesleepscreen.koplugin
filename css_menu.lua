-- Assembles the top-level settings menu and its submenus.

local Device          = require("device")
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
local createToggleItem      = h.createToggleItem
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

    sub_menu[#sub_menu + 1] = createToggleItem(_("Stretch image to fill"),
        _("When disabled, the image will be scaled to fit within the screen while preserving aspect ratio. Independent of your presets - stays the same no matter which preset is active."),
        SETTINGS.FM_BG_STRETCH, USER_CONFIG.FM_BG_STRETCH, nil, isFmBgImageBased)

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
            text           = iconLabel(icons.PREVIEW, _("Preview file manager sleep screen")),
            help_text      = _("Shows what the sleep screen looks like when the device goes to sleep from the file manager, without actually suspending it. Tap anywhere to close it."),
            keep_menu_open = true,
            separator      = true,
            callback       = function() h.showFileManagerSleepScreenPreview() end,
        },
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

-- Lock screen submenus

local function isLockSleepBg()
    return getSetting("LOCK_BG_TYPE") == "sleep"
end

local function buildLockBackgroundMenu()

    local switching_on = require("css_auto_preset_switch").isEnabled()

    local white = createRadioItem(_("Plain white"), nil, SETTINGS.LOCK_BG_TYPE, "white")

    white.checked_func = function()
        local t = getSetting("LOCK_BG_TYPE")
        return t == "white" or (t == "auto" and not switching_on)
    end
    local items = {
        createRadioItem(_("Sleep screen background"),
            _("Use the same background as your sleep screen (cover, image or colour), including its Background overlay. Images are shown around a solid panel behind the PIN pad, which keeps it readable and avoids ghosting. If your sleep screen has no background, plain white is used."),
            SETTINGS.LOCK_BG_TYPE, "sleep"),
        white,
        createRadioItem(_("Plain black"), nil, SETTINGS.LOCK_BG_TYPE, "black"),
    }
    if switching_on then
        items[#items + 1] = createRadioItem(_("Follow automatic preset switching"),
            _("White while your day preset is in effect and black while your night preset is. Only offered while automatic preset switching is turned on."),
            SETTINGS.LOCK_BG_TYPE, "auto")
    end
    items[#items].separator = true

    items[#items + 1] = {
        text      = _("Text colour"),
        help_text = _("Colour of the lock screen text and digits over the sleep screen background. Auto picks black or white to suit the image as shown, after the overlay. Plain white and black backgrounds always use the opposite colour."),
        enabled_func = isLockSleepBg,
        sub_item_table = buildNumericMenu("LOCK_TEXT_COLOR", {
            { text = _("Auto"),  val = "auto"  },
            { text = _("Black"), val = "black" },
            { text = _("White"), val = "white" },
        }),
    }
    return items
end

local function lockIsOn()
    return PluginStore:isTrue(SETTINGS.LOCK_ENABLED) and require("css_lockscreen").hasPin()
end

local function buildLockScreenMenu()
    local function lock() return require("css_lockscreen") end
    local lockOn = lockIsOn
    local function refresh(touchmenu_instance)
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end

    return {
        {
            text      = iconLabel(icons.PREVIEW, _("Preview lock screen")),
            help_text = _("Shows the PIN screen so you can see how it looks, without locking anything. Tap anywhere to close it."),
            keep_menu_open = true,
            separator = true,
            callback = function() lock().preview() end,
        },
        {
            text      = _("Enable lock screen"),
            help_text = _("After the sleep screen, tap or swipe to clear it, then enter your PIN to continue. This is a convenience lock to keep casual access out, not strong security: it doesn't protect the files on your device. It only applies after sleep unless you also turn on 'Lock when KOReader starts'. Turning it off needs your current PIN. If you forget the PIN, create an empty file named reset-lock inside the customisablesleepscreen.koplugin folder and restart KOReader to clear it."),
            keep_menu_open = true,
            checked_func = function()
                return PluginStore:isTrue(SETTINGS.LOCK_ENABLED) and lock().hasPin()
            end,
            callback = function(touchmenu_instance)
                if PluginStore:isTrue(SETTINGS.LOCK_ENABLED) then
                    lock().verifyThen(function()
                        PluginStore:saveSetting(SETTINGS.LOCK_ENABLED, false)
                        refresh(touchmenu_instance)
                    end)
                    return
                end
                if not Device:isTouchDevice() then
                    UIManager:show(require("ui/widget/infomessage"):new {
                        text    = _("The lock screen needs a touch screen."),
                        timeout = 3,
                    })
                    return
                end
                local function enable()
                    PluginStore:saveSetting(SETTINGS.LOCK_ENABLED, true)
                    refresh(touchmenu_instance)
                end
                if lock().hasPin() then
                    enable()
                else
                    lock().setPinFlow(enable)
                end
            end,
        },
        {
            text      = _("Lock when KOReader starts"),
            help_text = _("Also ask for the PIN when KOReader starts, so restarting the app or forcing the device to shut down and reboot can't be used to get around the lock. Turning it off needs your current PIN."),
            keep_menu_open = true,
            enabled_func = lockOn,
            checked_func = function() return PluginStore:isTrue(SETTINGS.LOCK_ON_LAUNCH) end,
            callback = function(touchmenu_instance)
                if PluginStore:isTrue(SETTINGS.LOCK_ON_LAUNCH) then
                    lock().verifyThen(function()
                        PluginStore:saveSetting(SETTINGS.LOCK_ON_LAUNCH, false)
                        refresh(touchmenu_instance)
                    end)
                else
                    PluginStore:saveSetting(SETTINGS.LOCK_ON_LAUNCH, true)
                    refresh(touchmenu_instance)
                end
            end,
        },
        {
            text      = _("Deferred locking"),
            help_text = _("Skip the lock screen when the device has only been asleep for a short time. Longer sleeps still ask for the PIN, and a device that went to sleep while locked always does."),
            enabled_func = lockOn,
            sub_item_table = buildNumericMenu("LOCK_DELAY_SECONDS", {
                { text = _("Off (always lock)"), val = 0    },
                { text = lock().durationText(30),   val = 30   },
                { text = lock().durationText(60),   val = 60   },
                { text = lock().durationText(120),  val = 120  },
                { text = lock().durationText(300),  val = 300  },
                { text = lock().durationText(600),  val = 600  },
                { text = lock().durationText(900),  val = 900  },
                { text = lock().durationText(1800), val = 1800 },
                { text = lock().durationText(3600), val = 3600 },
            }),
        },
        {
            text      = _("Change PIN"),
            help_text = _("Set a new 4-digit PIN. You'll be asked for the current one first."),
            keep_menu_open = true,
            enabled_func = lockOn,
            callback = function(touchmenu_instance)
                lock().verifyThen(function()
                    lock().setPinFlow(function() refresh(touchmenu_instance) end)
                end)
            end,
        },
        {
            text      = _("Button style"),
            help_text = _("How the number keys look: Plain (just the numbers), Ruled (thin lines between the rows), Outlined (circle outlines) or Filled (filled circles)."),
            enabled_func = lockOn,
            sub_item_table = buildNumericMenu("LOCK_BUTTON_STYLE", {
                { text = _("Plain"),        val = "plain"    },
                { text = _("Ruled"),        val = "ruled"    },
                { text = _("Outlined"),     val = "outlined" },
                { text = _("Filled"),       val = "filled"   },
            }),
        },
        {
            text      = _("Button shape"),
            help_text = _("The shape of the Outlined and Filled buttons: a circle, or a square with rounded corners."),
            enabled_func = function()
                local style = getSetting("LOCK_BUTTON_STYLE")
                return lockOn() and (style == "filled" or style == "outlined")
            end,
            sub_item_table = buildNumericMenu("LOCK_BUTTON_SHAPE", {
                { text = _("Circle"),         val = "circle" },
                { text = _("Rounded square"), val = "square" },
            }),
        },
        {
            text      = _("Background"),
            help_text = _("Choose what appears behind the PIN pad: your sleep screen background, or plain white or black."),
            enabled_func = lockOn,
            sub_item_table      = buildLockBackgroundMenu(),
            sub_item_table_func = buildLockBackgroundMenu,
        },
        {
            text      = _("Owner message"),
            help_text = _("A short message shown under the keypad, such as \"If found, call 0123456789\". Up to three lines. Anyone who wakes the device can read it. Leave it empty to show nothing."),
            keep_menu_open = true,
            enabled_func = lockOn,
            mandatory_func = function()
                local m = getSetting("LOCK_OWNER_MESSAGE")
                return (m and m:match("%S")) and _("On") or _("Off")
            end,
            callback = function(touchmenu_instance)
                h.createTextInputDialog(_("Owner message"), getSetting("LOCK_OWNER_MESSAGE") or "", function(text)
                    text = require("util").trim(text or "")
                    PluginStore:saveSetting(SETTINGS.LOCK_OWNER_MESSAGE, text)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end, true)
            end,
        },
    }
end

-- Global settings submenu

local function buildGlobalSettingsMenu()
    local flash_pin = createToggleItem(_("Flash screen before lock screen"),
        _("Flashes the screen (black or white, see below) before showing the lock screen, clearing leftovers of the sleep screen. Useful if you can see ghosting on the lock screen, for example with a black background. Needs the lock screen to be enabled."),
        SETTINGS.LOCK_ANTI_GHOSTING_FLASH, false, true)
    flash_pin.enabled_func = lockIsOn
    local flash_black = createRadioItem(_("Black flash"), _("Flash the screen to black. Clears light leftovers best."),
        SETTINGS.ANTI_GHOSTING_FLASH_COLOR, "black")
    flash_black.checked_func = function() return getSetting("ANTI_GHOSTING_FLASH_COLOR") ~= "white" end

    return {
        {
            text      = _("Flash screen to reduce ghosting"),
            help_text = _("Flashes the whole screen before showing a screen, clearing leftovers of the previous one. Off by default, since not every device shows this ghosting. The sleep screen and the lock screen each have their own switch, and the flash can be black or white."),
            sub_item_table = {
                createToggleItem(_("Flash screen before sleep screen"),
                    _("Flashes the screen (black or white, see below) before showing the sleep screen, clearing residual text/image ghosting."),
                    SETTINGS.ANTI_GHOSTING_FLASH, false),
                flash_pin,
                flash_black,
                createRadioItem(_("White flash"), _("Flash the screen to white. Clears dark leftovers best."),
                    SETTINGS.ANTI_GHOSTING_FLASH_COLOR, "white"),
            },
        },
        {
            text      = _("Sleep screen in file manager"),
            help_text = _("Control what the sleep screen looks like when triggered from the file manager, outside of a book."),
            sub_item_table = buildOutsideOfBookMenu(),
        },
        {
            text      = _("Export sleep screen to file"),
            help_text = _("Saves a screenshot of the sleep screen to a file. Useful for devices that use an exported image as their own native sleep screen."),
            sub_item_table = {
                {
                    text      = _("Enable export"),
                    help_text = _("When enabled, a screenshot of the sleep screen will be saved in the selected export folder using the format set below, on the triggers selected under 'Export triggers'."),
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
                    text      = _("Export triggers"),
                    help_text = _("Choose when the sleep screen is exported. You can select any combination of these."),
                    enabled_func = function() return PluginStore:isTrue(SETTINGS.EXPORT_ENABLED) end,
                    sub_item_table = {
                        createToggleItem(_("On book close"),
                            _("Export whenever you close a book."),
                            SETTINGS.EXPORT_TRIGGER_CLOSE, USER_CONFIG.EXPORT_TRIGGER_CLOSE),
                        createToggleItem(_("On book open"),
                            _("Export whenever you open a book."),
                            SETTINGS.EXPORT_TRIGGER_OPEN, USER_CONFIG.EXPORT_TRIGGER_OPEN),
                        createToggleItem(_("On suspend"),
                            _("Export whenever you put the device to sleep."),
                            SETTINGS.EXPORT_TRIGGER_SUSPEND, USER_CONFIG.EXPORT_TRIGGER_SUSPEND),
                        createToggleItem(_("Periodically while reading"),
                            _("Export automatically at a set interval while a book is open. Paused while the device is suspended, and resumes when you wake it or open another book."),
                            SETTINGS.EXPORT_TRIGGER_PERIODIC, USER_CONFIG.EXPORT_TRIGGER_PERIODIC, true),
                        {
                            text_func = function()
                                local minutes = PluginStore:readSetting(SETTINGS.EXPORT_TRIGGER_PERIODIC_MINUTES)
                                    or USER_CONFIG.EXPORT_TRIGGER_PERIODIC_MINUTES
                                return string.format(_("Periodic export interval: %d min"), minutes)
                            end,
                            help_text = _("How often to export while 'Periodically while reading' is enabled."),
                            enabled_func = function() return PluginStore:isTrue(SETTINGS.EXPORT_TRIGGER_PERIODIC) end,
                            keep_menu_open = true,
                            callback = function()
                                local current_value = PluginStore:readSetting(SETTINGS.EXPORT_TRIGGER_PERIODIC_MINUTES)
                                    or USER_CONFIG.EXPORT_TRIGGER_PERIODIC_MINUTES
                                createSpinDialog(
                                    _("Periodic export interval (minutes)"),
                                    current_value,
                                    5, 60, 5,
                                    function(val) PluginStore:saveSetting(SETTINGS.EXPORT_TRIGGER_PERIODIC_MINUTES, val) end,
                                    _("How often, in minutes, to export the sleep screen while a book is open."),
                                    nil, 5
                                )
                            end,
                        },
                    },
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
                        createToggleItem(_("Export in greyscale"),
                            _("Saves the exported image without colour, reducing file size for any format."),
                            SETTINGS.EXPORT_GRAYSCALE, false),
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


    menu_table[#menu_table + 1] = { text = iconLabel(icons.CONTENTS,   _("Contents")),              help_text = _("Control which sections appear and what information they display."),      sub_item_table = buildContentsMenu(ui)         }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.LAYOUT,     _("Layout, Spacing & Frame")), help_text = _("Position and size of the box, the gaps between sections, and its border, corner radius, and opacity."), sub_item_table = buildLayoutAndSpacingMenu(ui) }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.COLOURS,    _("Colours, Icons & Bars")), help_text = _("Customise section colours, icon appearance, and progress bar styling."), sub_item_table = buildColorsIconsBarsMenu(ui)  }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.FONTS,      _("Fonts & Text")),          help_text = _("Configure text appearance."),                                            sub_item_table = buildFontsAndTextMenu(ui)     }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.BACKGROUND, _("Background")),            help_text = _("Choose what appears behind the information box."),                       sub_item_table = buildBackgroundMenu(ui)       }
    menu_table[#menu_table + 1] = { text = iconLabel(icons.LOCK,       _("Lock screen")),           help_text = _("Add some security to your device and ask for a PIN after the sleep screen is cleared. Like Global settings, the lock screen settings don't change when you switch presets."), sub_item_table = buildLockScreenMenu() }
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
