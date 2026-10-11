-- Menu items for the Contents section: controls which data each section displays.

local UIManager = require("ui/uimanager")

local _           = require("gettext")
local config      = require("css_config")
local USER_CONFIG = config.USER_CONFIG
local SETTINGS    = config.SETTINGS

local PluginStore = require("css_settings").plugin()

local h                       = require("css_menu_helpers")
local getSetting              = h.getSetting
local createToggleItem         = h.createToggleItem
local createFlipNilOrTrueItem  = h.createFlipNilOrTrueItem
local createFlipNilOrFalseItem = h.createFlipNilOrFalseItem
local createRadioItem         = h.createRadioItem
local createSpinDialog        = h.createSpinDialog
local createTextInputDialog   = h.createTextInputDialog
local createResetMenuItem     = h.createResetMenuItem

local DAILY_GOAL_DEFAULT = USER_CONFIG.DAILY_GOAL

local function buildSectionOrderMenu()
    local section_labels = {
        book    = _("Book info"),
        chapter = _("Chapter info"),
        goal    = _("Daily info"),
        battery = _("Battery info"),
        message = _("Message info"),
    }

    local visibility_keys = {
        book    = SETTINGS.SHOW_BOOK,
        chapter = SETTINGS.SHOW_CHAP,
        goal    = SETTINGS.SHOW_GOAL,
        battery = SETTINGS.SHOW_BATT,
        message = SETTINGS.SHOW_MSG,
    }

    return {
        {
            text           = _("Section order & visibility"),
            help_text      = _("Select a section and tap the bottom arrows to reorder. Tap the checkmark to show or hide the section. Hide every section to show only the background."),
            keep_menu_open = true,
            callback = function()
                local SortWidget = require("ui/widget/sortwidget")

                local saved      = getSetting("SECTION_ORDER")
                local defaults   = USER_CONFIG.SECTION_ORDER
                if type(saved) ~= "table" then saved = {} end

                local order, seen = {}, {}
                for _, key in ipairs(saved) do
                    if visibility_keys[key] and not seen[key] then
                        seen[key] = true
                        order[#order + 1] = key
                    end
                end
                for _, key in ipairs(defaults) do
                    if visibility_keys[key] and not seen[key] then
                        seen[key] = true
                        order[#order + 1] = key
                    end
                end

                local item_table = {}
                for i, key in ipairs(order) do
                    local vis_key = visibility_keys[key]
                    item_table[i] = {
                        text = section_labels[key] or key,
                        key  = key,
                        checked_func = function()
                            return PluginStore:readSetting(vis_key) ~= false
                        end,
                        callback = function()
                            PluginStore:saveSetting(vis_key, PluginStore:readSetting(vis_key) == false)
                        end,
                    }
                end

                UIManager:show(SortWidget:new {
                    title      = _("Section order & visibility"),
                    item_table = item_table,
                    callback   = function(self)
                        local new_order = {}
                        for i, item in ipairs(self.item_table) do
                            new_order[i] = item.key
                        end
                        PluginStore:saveSetting(SETTINGS.SECTION_ORDER, new_order)
                    end,
                })
            end,
        },
    }
end

-- Per-section content menus

local function buildBookSectionContentMenu()
    local function coverEnabled()
        return PluginStore:readSetting(SETTINGS.COVER_IN_BOOK) == true
    end

    local cover_submenu = {
        createToggleItem(_("Show cover image above book info"),
            _("Display the book's cover image above the title and progress in the book section."),
            SETTINGS.COVER_IN_BOOK, false),
        {
            text         = _("Align cover to text alignment"),
            help_text    = _("When enabled, the cover image follows the text alignment setting instead of always being centered."),
            enabled_func = coverEnabled,
            checked_func = function()
                local val = PluginStore:readSetting(SETTINGS.COVER_ALIGN_TO_TEXT)
                return val == nil and false or val
            end,
            callback = function()
                local current = PluginStore:readSetting(SETTINGS.COVER_ALIGN_TO_TEXT)
                if current == nil then current = false end
                PluginStore:saveSetting(SETTINGS.COVER_ALIGN_TO_TEXT, not current)
            end,
        },
        {
            text         = _("Add drop shadow to cover"),
            help_text    = _("Gives the cover image rounded corners and a drop shadow, like a card. Replaces the regular cover border option while enabled."),
            enabled_func = coverEnabled,
            checked_func = function()
                local val = PluginStore:readSetting(SETTINGS.COVER_DROP_SHADOW)
                return val == nil and false or val
            end,
            callback = function()
                local current = PluginStore:readSetting(SETTINGS.COVER_DROP_SHADOW)
                if current == nil then current = false end
                PluginStore:saveSetting(SETTINGS.COVER_DROP_SHADOW, not current)
            end,
        },
        {
            text           = _("Cover image size"),
            help_text      = _("Height limit for the cover image in pixels."),
            enabled_func   = coverEnabled,
            keep_menu_open = true,
            callback = function()
                createSpinDialog(
                    _("Cover image size (pixels)"),
                    getSetting("COVER_SIZE") or 120,
                    40, 400, 10,
                    function(val) PluginStore:saveSetting(SETTINGS.COVER_SIZE, val) end,
                    _("100–150px fits neatly in most layouts. Go up to 250px+ for a prominent cover.")
                )
            end,
        },
        {
            text           = _("Cover border size"),
            help_text      = _("Width of the border drawn around the cover image. Set to 0 for no border. Ignored while 'Add drop shadow to cover' is enabled."),
            enabled_func   = function() return coverEnabled() and not getSetting("COVER_DROP_SHADOW") end,
            keep_menu_open = true,
            callback = function()
                createSpinDialog(
                    _("Cover border size (pixels)"),
                    getSetting("COVER_BORDER_SIZE") or 0,
                    0, 20, 1,
                    function(val) PluginStore:saveSetting(SETTINGS.COVER_BORDER_SIZE, val) end,
                    _("1–3px for a subtle outline. 0 to disable.")
                )
            end,
        },
    }

    return {
        {
            text           = _("Cover image"),
            help_text      = _("Configure the book cover image shown above the book section."),
            sub_item_table = cover_submenu,
        },
        createToggleItem(_("Show book author"),
            _("Display the author name below the book title."),
            SETTINGS.SHOW_BOOK_AUTHOR, false),
        createToggleItem(_("Show series name"),
            _("Display the book's series name and index below the title."),
            SETTINGS.SHOW_BOOK_SERIES, false),
        createToggleItem(_("Show book pages (pg x of x)"),
            _("Display total page count for the entire book."),
            SETTINGS.SHOW_BOOK_PAGES, false),
        createFlipNilOrTrueItem(_("Show book time remaining"),
            _("Display estimated reading time left to finish the book, based on your average reading speed."),
            SETTINGS.SHOW_BOOK_TIME_REMAINING),
        createFlipNilOrTrueItem(_("Show book percentage"),
            _("Display the percentage of the book completed."),
            SETTINGS.SHOW_BOOK_PERCENTAGE),
    }
end

local function buildChapterSectionContentMenu()
    return {
        createToggleItem(_("Show chapter count (ch x of x)"),
            _("Display current chapter number and total chapters (e.g., 'Chapter 5 of 12')."),
            SETTINGS.SHOW_CHAP_COUNT, false),
        createToggleItem(_("Show chapter pages (pg x of x)"),
            _("Display the number of pages in the current chapter."),
            SETTINGS.SHOW_CHAP_PAGES, false),
        createFlipNilOrTrueItem(_("Show chapter time remaining"),
            _("Display estimated time to finish the current chapter, based on your reading speed."),
            SETTINGS.SHOW_CHAP_TIME_REMAINING),
        createFlipNilOrTrueItem(_("Show chapter percentage"),
            _("Display the percentage of the current chapter completed."),
            SETTINGS.SHOW_CHAP_PERCENTAGE),
    }
end

local function buildGoalSectionContentMenu()
    local function isTimeGoal()
        return (getSetting("GOAL_TYPE") or USER_CONFIG.GOAL_TYPE or "pages") == "time"
    end

    return {
        {
            text_func = function()
                local labels = {
                    pages = _("Pages read today"),
                    time  = _("Time read today"),
                    both  = _("Time and pages read today"),
                }
                local current = getSetting("GOAL_TITLE_TYPE") or "time"
                return string.format(_("Title Line: %s"), labels[current] or current)
            end,
            help_text = _("Choose what the top line of the daily info section displays."),
            sub_item_table = {
                createRadioItem(
                    _("Pages read today"),
                    _("e.g. '35 pages read today'"),
                    SETTINGS.GOAL_TITLE_TYPE, "pages"
                ),
                createRadioItem(
                    _("Time read today"),
                    _("e.g. '42 mins read today'"),
                    SETTINGS.GOAL_TITLE_TYPE, "time"
                ),
                createRadioItem(
                    _("Time and pages read today"),
                    _("e.g. '42 mins & 35 pgs read today'"),
                    SETTINGS.GOAL_TITLE_TYPE, "both"
                ),
            },
        },
        {
            text_func = function()
                local label = isTimeGoal() and _("Time goal") or _("Page goal")
                return string.format(_("Goal type: %s"), label)
            end,
            help_text = _("Choose whether your daily goal tracks pages read or time spent reading."),
            sub_item_table = {
                {
                    text         = _("Page goal"),
                    help_text    = _("Track daily progress by number of pages read."),
                    checked_func = function()
                        local val = PluginStore:readSetting(SETTINGS.GOAL_TYPE)
                        return (val == nil and USER_CONFIG.GOAL_TYPE or val) == "pages"
                    end,
                    callback = function()
                        PluginStore:saveSetting(SETTINGS.GOAL_TYPE, "pages")
                    end,
                    radio = true,
                },
                {
                    text         = _("Time goal"),
                    help_text    = _("Track daily progress by minutes spent reading."),
                    checked_func = function()
                        return PluginStore:readSetting(SETTINGS.GOAL_TYPE) == "time"
                    end,
                    callback = function()
                        PluginStore:saveSetting(SETTINGS.GOAL_TYPE, "time")
                    end,
                    radio = true,
                },
            },
        },
        {
            text           = _("Daily page goal"),
            help_text      = _("Set how many pages you aim to read each day."),
            enabled_func   = function() return not isTimeGoal() end,
            keep_menu_open = true,
            callback = function()
                createSpinDialog(
                    _("Daily page goal (pages)"),
                    getSetting("DAILY_GOAL") or DAILY_GOAL_DEFAULT,
                    1, 500, 5,
                    function(val) PluginStore:saveSetting(SETTINGS.DAILY_GOAL, val) end,
                    _("20–50 pages for a daily habit. 50–100 for dedicated reading sessions."), nil, 25
                )
            end,
        },
        {
            text           = _("Daily time goal"),
            help_text      = _("Set how many minutes you aim to read each day."),
            enabled_func   = function() return isTimeGoal() end,
            keep_menu_open = true,
            callback = function()
                createSpinDialog(
                    _("Daily time goal (minutes)"),
                    getSetting("DAILY_GOAL_MINUTES") or USER_CONFIG.DAILY_GOAL_MINUTES,
                    5, 480, 5,
                    function(val) PluginStore:saveSetting(SETTINGS.DAILY_GOAL_MINUTES, val) end,
                    _("20–30 mins for a daily habit. 60+ mins for dedicated reading sessions."), nil, 15
                )
            end,
        },
        createToggleItem(_("Show current reading streak"),
            _("Display consecutive days you've met your reading goal."),
            SETTINGS.SHOW_GOAL_STREAK, false),
        createToggleItem(_("Show weekly reading streak"),
            _("Display consecutive weeks with any reading activity."),
            SETTINGS.SHOW_GOAL_WEEKLY_STREAK, false),
        createToggleItem(_("Show weekly progress"),
            _("Days this week you have met your reading goal, shown as completed days out of the current weekday (Monday = 1... Sunday = 7). For example: Thursday with goals met on Monday and Tuesday will show 2/4."),
            SETTINGS.SHOW_GOAL_ACHIEVEMENT, false),
        createFlipNilOrFalseItem(_("Show daily goal"),
            _("Target page mode: e.g. 50 page goal. Target time mode: e.g. 1hr 15min time goal."),
            SETTINGS.SHOW_GOAL_PAGES),
        createFlipNilOrTrueItem(_("Show goal percentage"),
            _("Display the percentage of your daily goal completed."),
            SETTINGS.SHOW_GOAL_PERCENTAGE),
    }
end

local function buildBatterySectionContentMenu()
    return {
        createToggleItem(_("Show remaining & charging text"),
            _("Show the words \"remaining\" and \"charging\" next to the battery percentage, e.g. \"82% remaining\" instead of just \"82%\"."),
            SETTINGS.SHOW_BATT_STATUS_TEXT, USER_CONFIG.SHOW_BATT_STATUS_TEXT),
        createToggleItem(_("Show time"),
            _("Display the current time. Note this is a snapshot taken when the sleep screen is shown, it does not update live while the screen is asleep."),
            SETTINGS.SHOW_BATT_CLOCK, USER_CONFIG.SHOW_BATT_CLOCK),
        createToggleItem(_("Show date"),
            _("Display the current date. Note this is a snapshot taken when the sleep screen is shown, it does not update live while the screen is asleep."),
            SETTINGS.SHOW_BATT_DATE, false),
        createToggleItem(_("Show battery consumption rate"),
            _("Display battery drain percentage per hour based on recent usage or manual input (see Global settings menu)"),
            SETTINGS.SHOW_BATT_RATE, false),
        createFlipNilOrTrueItem(_("Show battery time remaining"),
            _("Display estimated hours and minutes until battery is depleted, based on current drain rate."),
            SETTINGS.SHOW_BATT_TIME, true),
    }
end

local function buildMessageSectionContentMenu()
    return {
        createToggleItem(
            _("Show message header"),
            _("Show or hide the header label above the message text."),
            SETTINGS.SHOW_MSG_HEADER, USER_CONFIG.SHOW_MSG_HEADER
        ),
        {
            text           = _("Edit message header"),
            help_text      = _("Custom header text displayed above the message. Supports variables: %d, %y, %t, %b, %r."),
            enabled_func   = function()
                local val = PluginStore:readSetting(SETTINGS.SHOW_MSG_HEADER)
                return val == nil and USER_CONFIG.SHOW_MSG_HEADER or val
            end,
            keep_menu_open = true,
            callback = function()
                createTextInputDialog(_("Change custom message header"), getSetting("MSG_HEADER"),
                    function(value) PluginStore:saveSetting(SETTINGS.MSG_HEADER, value) end)
            end,
            separator = true,
        },
        createRadioItem(_("Custom message"),
            _("Use a separate custom message just for Customisable Sleep Screen"),
            SETTINGS.MESSAGE_SOURCE, "custom"),
        {
            text           = _("Edit custom message"),
            help_text      = _("Write your custom message text. Only active when 'Custom message' is selected. Supports variables: %d, %y, %t, %b, %r."),
            enabled_func   = function() return getSetting("MESSAGE_SOURCE") == "custom" end,
            keep_menu_open = true,
            callback = function()
                createTextInputDialog(_("Custom Customisable Sleep Screen message"),
                    getSetting("CUSTOM_MESSAGE") or "",
                    function(value) PluginStore:saveSetting(SETTINGS.CUSTOM_MESSAGE, value) end)
            end,
            separator = true,
        },
        createRadioItem(_("Book highlights"),
            _("Show a random highlight from the current book"),
            SETTINGS.MESSAGE_SOURCE, "highlight"),
        {
            text_func = function()
                local source = getSetting("HIGHLIGHT_SOURCE")
                local labels = { current = _("Current book"), all = _("All books") }
                return string.format(_("Highlight source: %s"), labels[source] or _("Current book"))
            end,
            help_text = _("Choose whether the highlight is picked from the current book only, or from all of your highlights."),
            enabled_func = function() return getSetting("MESSAGE_SOURCE") == "highlight" end,
            sub_item_table = {
                {
                    text      = _("Current book"),
                    help_text = _("Only show highlights from the book you're currently reading."),
                    checked_func = function()
                        local source = getSetting("HIGHLIGHT_SOURCE")
                        return source == nil or source == "current"
                    end,
                    callback = function()
                        PluginStore:saveSetting(SETTINGS.HIGHLIGHT_SOURCE, "current")
                    end,
                    radio = true,
                },
                {
                    text      = _("All books"),
                    help_text = _("Show highlights from a random sample of your reading history."),
                    checked_func = function() return getSetting("HIGHLIGHT_SOURCE") == "all" end,
                    callback = function()
                        PluginStore:saveSetting(SETTINGS.HIGHLIGHT_SOURCE, "all")
                    end,
                    radio = true,
                },
            },
        },
        createToggleItem(_("Show highlight book title and author"),
            _("Display which book and author the highlight is from. Only applies when highlight source is set to 'All books'."),
            SETTINGS.SHOW_HIGHLIGHT_BOOK, USER_CONFIG.SHOW_HIGHLIGHT_BOOK, nil,
            function()
                return getSetting("MESSAGE_SOURCE") == "highlight" and getSetting("HIGHLIGHT_SOURCE") == "all"
            end),
        createToggleItem(_("Show highlight location (chapter & page no.)"),
            _("Display the chapter title and page number where the highlight is found."),
            SETTINGS.SHOW_HIGHLIGHT_LOCATION, USER_CONFIG.SHOW_HIGHLIGHT_LOCATION, nil, function() return getSetting("MESSAGE_SOURCE") == "highlight" end),
        createToggleItem(_("Add quotation marks to highlights"),
            _("Wraps all highlights in curly double quotes, removing any pre-existing quotation marks."),
            SETTINGS.HIGHLIGHT_ADD_QUOTES, USER_CONFIG.HIGHLIGHT_ADD_QUOTES, nil, function() return getSetting("MESSAGE_SOURCE") == "highlight" end),
        {
            text           = _("Book highlight maximum length"),
            help_text      = _("Maximum characters to display for highlights (0 = no limit)."),
            enabled_func   = function() return getSetting("MESSAGE_SOURCE") == "highlight" end,
            keep_menu_open = true,
            callback = function()
                local current_value = getSetting("MAX_HIGHLIGHT_LENGTH") or 0
                createSpinDialog(
                    _("Maximum highlight length (characters)"),
                    current_value > 0 and current_value or USER_CONFIG.MAX_HIGHLIGHT_LENGTH,
                    0, 1000, 25,
                    function(val) PluginStore:saveSetting(SETTINGS.MAX_HIGHLIGHT_LENGTH, val) end,
                    _("100–150 chars keeps highlights readable. Set to 0 to show the full highlight."),
                    nil, 100
                )
            end,
            separator = true,
        },
        createRadioItem(_("Custom quotes"),
            _("Show a random quote from the css_custom_quotes.lua file in the plugin folder."),
            SETTINGS.MESSAGE_SOURCE, "custom_quotes"),
        createToggleItem(_("Show quote attribution"),
            _("Display the author and book name below the quote, if provided in css_custom_quotes.lua."),
            SETTINGS.SHOW_QUOTE_ATTRIBUTION, USER_CONFIG.SHOW_QUOTE_ATTRIBUTION, true, function() return getSetting("MESSAGE_SOURCE") == "custom_quotes" end),
        createRadioItem(_("KOReader sleep message"),
            _("Uses KOReaders own sleep screen message function. Enable 'Add custom message to sleep screen' to use this (Settings → Screen → Sleep screen → Sleep screen message)."),
            SETTINGS.MESSAGE_SOURCE, "koreader",
            function() return G_reader_settings:isTrue(SETTINGS.SHOW_MSG_GLOBAL) end),
    }
end

-- Top-level Contents menu (combines all of the above)

local function buildContentsMenu(ui)
    local menu = {
        h.buildPreviewMenuItem(ui, false),
        createResetMenuItem("contents", {
            SETTINGS.SHOW_BOOK,                SETTINGS.SHOW_CHAP,
            SETTINGS.SHOW_GOAL,                SETTINGS.SHOW_BATT,
            SETTINGS.SHOW_MSG,                 SETTINGS.SECTION_ORDER,
            SETTINGS.SHOW_BOOK_AUTHOR,         SETTINGS.SHOW_BOOK_PAGES,
            SETTINGS.SHOW_BOOK_TIME_REMAINING, SETTINGS.SHOW_BOOK_PERCENTAGE,
            SETTINGS.SHOW_CHAP_COUNT,          SETTINGS.SHOW_CHAP_PAGES,
            SETTINGS.SHOW_CHAP_TIME_REMAINING, SETTINGS.SHOW_CHAP_PERCENTAGE,
            SETTINGS.DAILY_GOAL,               SETTINGS.GOAL_TYPE,
            SETTINGS.DAILY_GOAL_MINUTES,       SETTINGS.SHOW_GOAL_STREAK,
            SETTINGS.SHOW_GOAL_WEEKLY_STREAK,
            SETTINGS.SHOW_GOAL_ACHIEVEMENT,    SETTINGS.SHOW_GOAL_PAGES,
            SETTINGS.SHOW_GOAL_PERCENTAGE,     SETTINGS.GOAL_TITLE_TYPE,
            SETTINGS.SHOW_MSG_HEADER,
            SETTINGS.SHOW_BATT_DATE,
            SETTINGS.SHOW_BATT_RATE,           SETTINGS.SHOW_BATT_TIME,
            SETTINGS.SHOW_BATT_CLOCK,          SETTINGS.SHOW_BATT_STATUS_TEXT,
            SETTINGS.MESSAGE_SOURCE,           SETTINGS.MSG_HEADER,
            SETTINGS.CUSTOM_MESSAGE,           SETTINGS.MAX_HIGHLIGHT_LENGTH,
            SETTINGS.HIGHLIGHT_ADD_QUOTES,     SETTINGS.SHOW_HIGHLIGHT_LOCATION,
            SETTINGS.HIGHLIGHT_SOURCE,         SETTINGS.SHOW_HIGHLIGHT_BOOK,
            SETTINGS.COVER_IN_BOOK,            SETTINGS.COVER_SIZE,
            SETTINGS.COVER_BORDER_SIZE,        SETTINGS.COVER_ALIGN_TO_TEXT,
            SETTINGS.COVER_DROP_SHADOW,
            SETTINGS.SHOW_QUOTE_ATTRIBUTION,
            SETTINGS.SHOW_BOOK_SERIES,
        }),
        buildSectionOrderMenu()[1],
        { text = _("Book section"),       help_text = _("Configure book-specific details."),        sub_item_table = buildBookSectionContentMenu()    },
        { text = _("Chapter section"),    help_text = _("Configure chapter-specific details"),      sub_item_table = buildChapterSectionContentMenu() },
        { text = _("Daily goal section"), help_text = _("Configure reading goal details"),          sub_item_table = buildGoalSectionContentMenu()    },
        { text = _("Battery section"),    help_text = _("Configure battery & time/date details"),   sub_item_table = buildBatterySectionContentMenu() },
        { text = _("Message section"),    help_text = _("Configure message-specific details"),      sub_item_table = buildMessageSectionContentMenu() },
    }
    return menu
end

return {
    buildContentsMenu              = buildContentsMenu,
    buildSectionOrderMenu          = buildSectionOrderMenu,
    buildBookSectionContentMenu    = buildBookSectionContentMenu,
    buildChapterSectionContentMenu = buildChapterSectionContentMenu,
    buildGoalSectionContentMenu    = buildGoalSectionContentMenu,
    buildBatterySectionContentMenu = buildBatterySectionContentMenu,
    buildMessageSectionContentMenu = buildMessageSectionContentMenu,
}
