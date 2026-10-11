-- Shared rendering utilities

local Blitbuffer         = require("ffi/blitbuffer")
local FrameContainer     = require("ui/widget/container/framecontainer")
local Geom               = require("ui/geometry")
local OverlapGroup       = require("ui/widget/overlapgroup")
local Widget             = require("ui/widget/widget")
local logger             = require("logger")
local util               = require("util")
local Device             = require("device")
local Font               = require("ui/font")
local UIManager          = require("ui/uimanager")
local ProgressWidget     = require("ui/widget/progresswidget")
local TextWidget         = require("ui/widget/textwidget")
local TextWidget_paintTo = TextWidget.paintTo

local config      = require("css_config")
local USER_CONFIG = config.USER_CONFIG
local SETTINGS    = config.SETTINGS
local getSetting  = config.getSetting

local PluginStore = require("css_settings").plugin()

local Screen = Device.screen

local function clamp(val, mn, mx)
    return math.max(mn, math.min(mx, val))
end

local font_cache  = {}
local color_cache = {}

-- Widget paintTo patches

local function patchedTextWidgetPaintTo(self, bb, x, y)
    self:updateSize()
    if self._is_empty then return end

    if not self.use_xtext or not self._fgcolor_rgb then
        return TextWidget_paintTo(self, bb, x, y)
    end

    if not self._xshaping then
        self._xshaping = self._xtext:shapeLine(self._shape_start, self._shape_end,
                                               self._shape_idx_to_substitute_with_ellipsis)
    end

    local text_width = bb:getWidth() - x
    if self.max_width and self.max_width < text_width then
        text_width = self.max_width
    end

    local RenderText = require("ui/rendertext")
    local pen_x   = 0
    local baseline = self.forced_baseline or self._baseline_h
    for _, xglyph in ipairs(self._xshaping) do
        if pen_x >= text_width then break end
        local face  = self.face.getFallbackFont(xglyph.font_num)
        local glyph = RenderText:getGlyphByIndex(face, xglyph.glyph, self.bold)
        local gw = glyph.bb:getWidth()
        local gh = glyph.bb:getHeight()
        local gx = x + pen_x + glyph.l + xglyph.x_offset
        local gy = y + baseline - glyph.t - xglyph.y_offset
        bb:colorblitFromRGB32(glyph.bb, gx, gy, 0, 0, gw, gh, self._fgcolor_rgb)
        pen_x = pen_x + xglyph.x_advance
    end
end

local function applyTextWidgetPatch()
    TextWidget.paintTo = patchedTextWidgetPaintTo
end

local function restoreTextWidgetPatch()
    TextWidget.paintTo = TextWidget_paintTo
end

local ProgressWidget_paintTo = ProgressWidget.paintTo

local function patchedProgressWidgetPaintTo(self, bb, x, y)
    local my_size = self:getSize()
    if not self.dimen then
        self.dimen = require("ui/geometry"):new({ x = x, y = y, w = my_size.w, h = my_size.h })
    else
        self.dimen.x = x
        self.dimen.y = y
    end
    if self.dimen.w == 0 or self.dimen.h == 0 then return end

    local BD          = require("ui/bidi")
    local _mirrored_ui = BD.mirroredUILayout()
    local fill_width  = my_size.w - 2 * (self.margin_h + self.bordersize)
    local fill_y      = y + self.margin_v + self.bordersize
    local fill_height = my_size.h - 2 * (self.margin_v + self.bordersize)

    if self.radius == 0 then
        bb:paintRect(x, y, my_size.w, my_size.h, self.bordercolor)
        bb:paintRectRGB32(x + self.margin_h + self.bordersize, fill_y,
            math.ceil(fill_width), math.ceil(fill_height), self.bgcolor)
    else
        bb:paintRectRGB32(x, y, my_size.w, my_size.h, self.bgcolor)
        bb:paintBorder(math.floor(x), math.floor(y), my_size.w, my_size.h,
            self.bordersize, self.bordercolor, self.radius)
    end

    if self.percentage >= 0 and self.percentage <= 1 then
        local fill_x = x + self.margin_h + self.bordersize
        if self.fill_from_right or (_mirrored_ui and not self.fill_from_right) then
            fill_x = fill_x + (fill_width * (1 - self.percentage))
            fill_x = math.floor(fill_x)
        end
        bb:paintRectRGB32(fill_x, fill_y,
            math.ceil(fill_width * self.percentage), math.ceil(fill_height), self.fillcolor)
    end

    if self.ticks and self.last and self.last > 0 then
        for _, tick in ipairs(self.ticks) do
            local tick_x = fill_width * (tick / self.last)
            if _mirrored_ui then tick_x = fill_width - tick_x end
            tick_x = math.floor(tick_x)
            bb:paintRect(x + self.margin_h + self.bordersize + tick_x,
                fill_y, self.tick_width, math.ceil(fill_height), self.bordercolor)
        end
    end
end

local function applyProgressWidgetPatch()
    applyTextWidgetPatch()
    font_cache  = {}
    color_cache = {}
    ProgressWidget.paintTo = patchedProgressWidgetPaintTo
    local ok, RenderText = pcall(require, "ui/rendertext")
    if ok and RenderText and RenderText.clearGlyphCache then
        RenderText:clearGlyphCache()
    end
end

local function restoreProgressWidgetPatch()
    restoreTextWidgetPatch()
    ProgressWidget.paintTo = ProgressWidget_paintTo
end

-- Colour helpers

local function getCachedColor(hex)
    if not hex then return Blitbuffer.COLOR_BLACK end
    if not color_cache[hex] then
        local r = tonumber(hex:sub(2, 3), 16) or 0
        local g = tonumber(hex:sub(4, 5), 16) or 0
        local b = tonumber(hex:sub(6, 7), 16) or 0
        color_cache[hex] = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
    end
    return color_cache[hex]
end

local function getBBColor(setting_key, default_hex)
    local hex = PluginStore:readSetting(setting_key) or default_hex
    return getCachedColor(hex)
end

local function getColors(is_mono, mono_hex, mono_color)
    if is_mono then
        return {
            book_hex    = mono_hex, chapter_hex = mono_hex,
            goal_hex    = mono_hex, message_hex = mono_hex,
            book        = mono_color, chapter = mono_color,
            goal        = mono_color, message = mono_color,
        }
    end
    return {
        book_hex    = getSetting("COLOR_BOOK_FILL"),
        chapter_hex = getSetting("COLOR_CHAPTER_FILL"),
        goal_hex    = getSetting("COLOR_GOAL_FILL"),
        message_hex = getSetting("COLOR_MESSAGE_FILL"),
        book    = getBBColor(SETTINGS.COLOR_BOOK_FILL,    USER_CONFIG.COLOR_BOOK_FILL),
        chapter = getBBColor(SETTINGS.COLOR_CHAPTER_FILL, USER_CONFIG.COLOR_CHAPTER_FILL),
        goal    = getBBColor(SETTINGS.COLOR_GOAL_FILL,    USER_CONFIG.COLOR_GOAL_FILL),
        message = getBBColor(SETTINGS.COLOR_MESSAGE_FILL, USER_CONFIG.COLOR_MESSAGE_FILL),
    }
end

-- Font & rendering-context setup

local function resolveFontPath(font_name)
    if not font_name or font_name == "cfont" then return nil end
    if font_name:match("^%.?/") then return font_name end
    local ok_cre, cre_mod = pcall(require, "document/credocument")
    if not ok_cre then return font_name end
    local ok_eng, engine = pcall(function() return cre_mod:engineInit() end)
    if not (ok_eng and engine and engine.getFontFaceFilenameAndFaceIndex) then return font_name end
    local path = engine.getFontFaceFilenameAndFaceIndex(font_name)
    return path or font_name
end

local function getCachedFont(font_name, size)
    local key = (font_name or "cfont") .. ":" .. size
    if not font_cache[key] then
        local resolved = resolveFontPath(font_name)
        local ok, face = pcall(Font.getFace, Font, resolved, size)
        if ok and face then
            font_cache[key] = face
        else
            logger.warn("[Customisable Sleep Screen] Font '" .. tostring(font_name) .. "' failed, falling back to cfont")
            font_cache[key] = Font:getFace("cfont", size) or Font:getFace("cfont", 20)
        end
    end
    return font_cache[key]
end

local function blendHex(hex, r2, g2, b2, t)
    local r1 = tonumber(hex:sub(2, 3), 16) or 0
    local g1 = tonumber(hex:sub(4, 5), 16) or 0
    local b1 = tonumber(hex:sub(6, 7), 16) or 0
    local r = math.floor(r1 * (1 - t) + r2 * t + 0.5)
    local g = math.floor(g1 * (1 - t) + g2 * t + 0.5)
    local b = math.floor(b1 * (1 - t) + b2 * t + 0.5)
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

local function setupRenderingContext()
    local title_face    = getCachedFont(getSetting("FONT_FACE_TITLE"),    Screen:scaleBySize(getSetting("FONT_SIZE_TITLE")))
    local subtitle_face = getCachedFont(getSetting("FONT_FACE_SUBTITLE"), Screen:scaleBySize(getSetting("FONT_SIZE_SUBTITLE")))

    local dark    = PluginStore:isTrue(SETTINGS.DARK_MODE)
    local is_mono = PluginStore:isTrue(SETTINGS.MONOCHROME)

    local color_dark_hex  = getSetting("COLOR_DARK")
    local color_light_hex = getSetting("COLOR_LIGHT")
    local mono_hex   = dark and color_dark_hex or color_light_hex
    local mono_color = getCachedColor(mono_hex)

    local color_config          = getColors(is_mono, mono_hex, mono_color)
    color_config.is_mono    = is_mono
    color_config.mono_color = mono_color
    color_config.mono_hex   = mono_hex

    local bg_hex = dark and getSetting("COLOR_BOX_BG_DARK") or getSetting("COLOR_BOX_BG")
    local colors = {
        bg       = getCachedColor(dark and getSetting("COLOR_BOX_BG_DARK")  or getSetting("COLOR_BOX_BG")),
        text     = getCachedColor(dark and getSetting("COLOR_TEXT_DARK")    or getSetting("COLOR_TEXT")),
        subtext  = getCachedColor(dark and getSetting("COLOR_TEXT_DARK")    or getSetting("COLOR_TEXT")),
        bar_bg   = dark and blendHex(bg_hex, 255, 255, 255, 0.18)           or blendHex(bg_hex, 0, 0, 0, 0.18),
        shadow   = dark and blendHex(bg_hex, 255, 255, 255, 0.5)           or blendHex(bg_hex, 0, 0, 0, 0.5),
        border   = getCachedColor(dark and getSetting("COLOR_TEXT_DARK")    or getSetting("COLOR_TEXT")),
        border_2 = getCachedColor(dark and getSetting("COLOR_BOX_BG_DARK")  or getSetting("COLOR_BOX_BG")),
    }

    return title_face, subtitle_face, colors, color_config
end

-- Text layout & wrapping

local function getTextWidth(text, face)
    if not face or not text or text == "" then return 0 end
    if face.getAdvance then return face:getAdvance(text) end
    local tw = TextWidget:new { text = text, face = face }
    local w  = tw:getSize().w
    tw:free()
    return w
end

local function wrapText(text, face, max_width)
    if not text or text == "" or not face then return {} end
    local lines, current_line, current_width = {}, {}, 0
    local space_width = getTextWidth(" ", face)

    if util.hasCJKChar(text) then
        local current_line_text = ""
        local current_w = 0
        for _, char in ipairs(util.splitToChars(text)) do
            local cw = getTextWidth(char, face)
            if current_w + cw > max_width and current_line_text ~= "" then
                lines[#lines + 1] = current_line_text
                current_line_text = char
                current_w = cw
            else
                current_line_text = current_line_text .. char
                current_w = current_w + cw
            end
        end
        if current_line_text ~= "" then lines[#lines + 1] = current_line_text end
        return lines
    end

    for word in text:gmatch("%S+") do
        local ww = getTextWidth(word, face)
        if #current_line == 0 then
            current_line[1] = word
            current_width   = ww
        elseif current_width + space_width + ww <= max_width then
            current_line[#current_line + 1] = word
            current_width = current_width + space_width + ww
        else
            lines[#lines + 1] = table.concat(current_line, " ")
            current_line  = { word }
            current_width = ww
        end
    end
    if #current_line > 0 then lines[#lines + 1] = table.concat(current_line, " ") end
    return lines
end

local function createMultiLineText(text, face, color, max_width, allow_multiline, alignment, bold)
    if allow_multiline == nil then allow_multiline = true end
    if not alignment then alignment = "left" end
    if not text or text == "" then
        return TextWidget:new { text = "", face = face, fgcolor = Blitbuffer.COLOR_BLACK, _fgcolor_rgb = color, bold = bold }
    end
    if not allow_multiline then
        local ellipsis = "…"
        if getTextWidth(text, face) <= max_width then
            return TextWidget:new { text = text, face = face, fgcolor = Blitbuffer.COLOR_BLACK, _fgcolor_rgb = color, bold = bold }
        end
        local words, current_text, best_text = {}, "", ""
        for word in text:gmatch("%S+") do words[#words + 1] = word end
        for _, word in ipairs(words) do
            local test = current_text == "" and word or current_text .. " " .. word
            if getTextWidth(test .. ellipsis, face) <= max_width then
                current_text = test
                best_text    = current_text
            else
                break
            end
        end
        return TextWidget:new { text = best_text .. ellipsis, face = face, fgcolor = Blitbuffer.COLOR_BLACK, _fgcolor_rgb = color, bold = bold }
    end
    local lines = wrapText(text, face, max_width)
    if #lines == 1 then
        return TextWidget:new { text = lines[1], face = face, fgcolor = Blitbuffer.COLOR_BLACK, _fgcolor_rgb = color, bold = bold }
    end
    local tg = require("ui/widget/verticalgroup"):new { align = alignment }
    for _, line in ipairs(lines) do
        tg[#tg + 1] = TextWidget:new { text = line, face = face, fgcolor = Blitbuffer.COLOR_BLACK, _fgcolor_rgb = color, bold = bold }
    end
    return tg
end

local function isNightModeActive()
    return (Device.screen.night_mode == true) or G_reader_settings:isTrue("night_mode")
end

local function suppressNightMode()
    if not isNightModeActive() then return nil end

    local saved_setting = G_reader_settings:readSetting("night_mode")
    pcall(function()
        if Device.screen.setHWNightmode then
            Device.screen:setHWNightmode(false)
        elseif Device.screen.toggleNightMode then
            if Device.screen.getHWNightmode and Device.screen:getHWNightmode() then
                Device.screen:toggleNightMode()
            end
        end
        Device.screen.night_mode = false
        G_reader_settings:delSetting("night_mode")
    end)

    return { saved_setting = saved_setting }
end

local function restoreNightMode(state)
    if not state then return end

    pcall(function()
        if Device.screen.setHWNightmode then
            Device.screen:setHWNightmode(true)
        elseif Device.screen.toggleNightMode then
            if Device.screen.getHWNightmode and not Device.screen:getHWNightmode() then
                Device.screen:toggleNightMode()
            end
        end
        Device.screen.night_mode = true
        if state.saved_setting ~= nil then
            G_reader_settings:saveSetting("night_mode", state.saved_setting)
        else
            G_reader_settings:delSetting("night_mode")
        end
    end)

    UIManager:setDirty(nil, "full")
end

-- Cover drop shadow
local SHADOW_OFFSET = Screen:scaleBySize(4)
local CARD_RADIUS   = Screen:scaleBySize(4)
local CARD_BORDER   = Screen:scaleBySize(1)

local function paintColorSafeBorder(bb, x, y, w, h, border_size, color, radius, anti_alias)
    if not color or not border_size or border_size <= 0 then return end
    local ffi = require("ffi")
    local ColorRGB32_t = ffi.typeof("ColorRGB32")
    local is_rgb32 = ffi.istype(ColorRGB32_t, color)
    local suppress_invert = is_rgb32 and Device:isAndroid() and bb:getInverse() == 1
    if suppress_invert then bb:setInverse(0) end
    if is_rgb32 then
        bb:paintBorderRGB32(x, y, w, h, border_size, color, radius, anti_alias)
    else
        bb:paintBorder(x, y, w, h, border_size, color, radius, anti_alias)
    end
    if suppress_invert then bb:setInverse(1) end
end

local ShadowRect = Widget:extend{ width = nil, height = nil, color = nil }
function ShadowRect:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function ShadowRect:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, self.color, CARD_RADIUS)
end

local RoundedCornerCard = Widget:extend{
    inner           = nil,
    width           = nil,
    height          = nil,
    radius          = 0,
    border_size     = 0,
    border_color    = nil,
    bg_color        = nil,
    shadow_color    = nil,
    shadow_offset_x = 0,
    shadow_offset_y = 0,
    shadow_radius   = 0,
}

function RoundedCornerCard:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function RoundedCornerCard:getSize() return self.dimen end
function RoundedCornerCard:free(...)
    if self.inner and self.inner.free then self.inner:free(...) end
end

function RoundedCornerCard:_pixelInShadow(px, py)
    if not self.shadow_color then return false end
    local sox, soy = self.shadow_offset_x, self.shadow_offset_y
    local sw, sh   = self.width, self.height
    if px < sox or py < soy or px >= sox + sw or py >= soy + sh then
        return false
    end
    local sr = self.shadow_radius or 0
    if sr <= 0 then return true end
    local sx, sy = px - sox, py - soy
    local cx, cy
    if sx < sr and sy < sr then
        cx, cy = sr, sr
    elseif sx >= sw - sr and sy < sr then
        cx, cy = sw - sr, sr
    elseif sx < sr and sy >= sh - sr then
        cx, cy = sr, sh - sr
    elseif sx >= sw - sr and sy >= sh - sr then
        cx, cy = sw - sr, sh - sr
    end
    if not cx then return true end
    local ddx, ddy = sx - cx, sy - cy
    return ddx * ddx + ddy * ddy <= sr * sr
end

function RoundedCornerCard:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y

    if self.inner then
        self.inner:paintTo(bb, x, y)
    end

    if self.radius and self.radius > 0 then
        local r     = self.radius
        local w, h  = self.width, self.height
        local bg    = self.bg_color or Blitbuffer.COLOR_WHITE
        local r_sq  = r * r
        local shadow_paint = self.shadow_color

        for dy = 0, r - 1 do
            local cutoff_top = 0
            local dy_top_sq = (dy - r) * (dy - r)
            while cutoff_top < r and (cutoff_top - r) * (cutoff_top - r) + dy_top_sq > r_sq do
                cutoff_top = cutoff_top + 1
            end
            if cutoff_top > 0 then
                bb:paintRect(x, y + dy, cutoff_top, 1, bg)
                bb:paintRect(x + w - cutoff_top, y + dy, cutoff_top, 1, bg)
            end

            local cutoff_bot = 0
            local dy_bot_sq = dy * dy
            while cutoff_bot < r and (cutoff_bot - r) * (cutoff_bot - r) + dy_bot_sq > r_sq do
                cutoff_bot = cutoff_bot + 1
            end
            if cutoff_bot > 0 then
                bb:paintRect(x, y + h - r + dy, cutoff_bot, 1, bg)

                if self.shadow_color then
                    local py = h - r + dy
                    local run_start, run_in_shadow
                    for dx = 0, cutoff_bot - 1 do
                        local px = w - cutoff_bot + dx
                        local in_shadow = self:_pixelInShadow(px, py)
                        if run_start == nil then
                            run_start, run_in_shadow = dx, in_shadow
                        elseif in_shadow ~= run_in_shadow then
                            bb:paintRect(x + w - cutoff_bot + run_start, y + py,
                                         dx - run_start, 1,
                                         run_in_shadow and shadow_paint or bg)
                            run_start, run_in_shadow = dx, in_shadow
                        end
                    end
                    if run_start then
                        bb:paintRect(x + w - cutoff_bot + run_start, y + py,
                                     cutoff_bot - run_start, 1,
                                     run_in_shadow and shadow_paint or bg)
                    end
                else
                    bb:paintRect(x + w - cutoff_bot, y + h - r + dy, cutoff_bot, 1, bg)
                end
            end
        end
    end

    if self.border_size and self.border_size > 0 then
        local border_color = self.border_color or Blitbuffer.COLOR_BLACK
        paintColorSafeBorder(bb, x, y, self.width, self.height,
                              self.border_size, border_color, self.radius, true)
    end
end

local function wrapCoverWithShadow(cover, card_w, card_h, shadow_color, bg_color, border_color)
    local shadow_layer = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = SHADOW_OFFSET,
        padding_left = SHADOW_OFFSET,
        ShadowRect:new{ width = card_w, height = card_h, color = shadow_color },
    }

    local card = RoundedCornerCard:new{
        inner           = cover,
        width           = card_w,
        height          = card_h,
        radius          = CARD_RADIUS,
        border_size     = CARD_BORDER,
        border_color    = border_color,
        bg_color        = bg_color,
        shadow_color    = shadow_color,
        shadow_offset_x = SHADOW_OFFSET,
        shadow_offset_y = SHADOW_OFFSET,
        shadow_radius   = CARD_RADIUS,
    }

    return OverlapGroup:new{
        dimen = Geom:new{ w = card_w + SHADOW_OFFSET, h = card_h + SHADOW_OFFSET },
        shadow_layer,
        card,
    }
end

return {
    applyProgressWidgetPatch   = applyProgressWidgetPatch,
    restoreProgressWidgetPatch = restoreProgressWidgetPatch,
    applyTextWidgetPatch       = applyTextWidgetPatch,
    restoreTextWidgetPatch     = restoreTextWidgetPatch,
    getCachedFont              = getCachedFont,
    getCachedColor             = getCachedColor,
    getColors                  = getColors,
    getBBColor                 = getBBColor,
    setupRenderingContext      = setupRenderingContext,
    getTextWidth               = getTextWidth,
    wrapText                   = wrapText,
    createMultiLineText        = createMultiLineText,
    clamp                      = clamp,
    getSetting                 = getSetting,
    suppressNightMode          = suppressNightMode,
    restoreNightMode           = restoreNightMode,
    SHADOW_OFFSET              = SHADOW_OFFSET,
    wrapCoverWithShadow        = wrapCoverWithShadow,
}
