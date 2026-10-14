-- Optional PIN lock shown after the sleep screen is dismissed. A UI lock only.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local sha2           = require("ffi/sha2")

local _            = require("gettext")
local ngettext     = function(singular, plural, n) return _.ngettext(singular, plural, n) end
local config       = require("css_config")
local SETTINGS     = config.SETTINGS
local css_settings = require("css_settings")

local Screen = Device.screen

-- Constants

local PIN_LENGTH           = 4
local MAX_ATTEMPTS         = 5
local BASE_LOCKOUT_SECONDS = 30
local MAX_LOCKOUT_SECONDS  = 600

local GLYPH_LOCK      = "\xEF\x80\xA3"
local GLYPH_UNLOCKED  = "\xEF\x82\x9C"
local GLYPH_BACKSPACE = "\u{e76d}"
local GLYPH_BACK      = "\u{e74c}"

local SLEEP_FONT = "noto/NotoSans-Bold.ttf"

local SLEEP_CLUSTER = {
    gap  = 5,
    rise = 15,
    { "z", 33 },
    { "z", 44 },
    { "Z", 48 },
}

local function store() return css_settings.plugin() end

-- PIN storage (salted hash)

local function hashPin(salt, pin)
    return sha2.sha256(salt .. ":" .. pin)
end

local function hasPin()
    local s = store()
    return s:readSetting(SETTINGS.LOCK_PIN_HASH) ~= nil and s:readSetting(SETTINGS.LOCK_PIN_SALT) ~= nil
end

local function savePin(pin)
    local salt = require("random").uuid()
    local s = store()
    s:saveSetting(SETTINGS.LOCK_PIN_SALT, salt)
    s:saveSetting(SETTINGS.LOCK_PIN_HASH, hashPin(salt, pin))
    pcall(function() css_settings.flush() end)
end

local function verifyPin(pin)
    local s = store()
    local salt = s:readSetting(SETTINGS.LOCK_PIN_SALT)
    local hash = s:readSetting(SETTINGS.LOCK_PIN_HASH)
    if not salt or not hash then return false end
    return hashPin(salt, pin) == hash
end

-- Lock-out state

local LOCK_STATE_KEYS = { "LOCK_FAILED_ATTEMPTS", "LOCK_LOCKOUT_ROUNDS", "LOCK_LOCKED_UNTIL", "LOCK_LOCKOUT_SECS" }

local function saveLockState(values)
    local s = store()
    for name, v in pairs(values) do s:saveSetting(SETTINGS[name], v) end
    pcall(function() css_settings.flush() end)
end

local function clearLockState()
    local s, any = store(), false
    for _i, name in ipairs(LOCK_STATE_KEYS) do
        if s:readSetting(SETTINGS[name]) ~= nil then any = true; s:delSetting(SETTINGS[name]) end
    end
    if any then pcall(function() css_settings.flush() end) end
end

local function resetPin()
    clearLockState()
    local s = store()
    s:delSetting(SETTINGS.LOCK_PIN_SALT)
    s:delSetting(SETTINGS.LOCK_PIN_HASH)
    s:saveSetting(SETTINGS.LOCK_ENABLED, false)
    s:saveSetting(SETTINGS.LOCK_ON_LAUNCH, false)
    pcall(function() css_settings.flush() end)
end

local function isEnabled()
    return Device:isTouchDevice() and store():isTrue(SETTINGS.LOCK_ENABLED) and hasPin()
end

-- Appearance

local setting = config.getSetting

local function applySleepOverlay(bb)
    local alpha = tonumber(setting("BG_DIMMING")) or 0
    if alpha <= 0 then return end
    local c = Blitbuffer.colorFromString(setting("BG_DIMMING_COLOR")) or Blitbuffer.colorFromString("#000000")
    bb:blendRectRGB32(0, 0, bb:getWidth(), bb:getHeight(),
                      Blitbuffer.ColorRGB32(c.r, c.g, c.b, math.min(255, math.floor(alpha))))
end

local function sampleLuminance(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local sum, n, lo, hi = 0, 0, 255, 0
    for iy = 0, 15 do
        for ix = 0, 15 do
            local x = math.floor((ix + 0.5) * w / 16)
            local y = math.floor((iy + 0.5) * h / 16)
            local v = bb:getPixel(x, y):getColor8().a
            sum = sum + v
            n = n + 1
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
    end
    return sum / n, hi - lo
end

local function wantsLightInk(luminance)
    local pref = setting("LOCK_TEXT_COLOR")
    if pref == "white" then return true end
    if pref == "black" then return false end
    return luminance < 128
end

local function prepareBackground(use_kept)
    local bg = { color = Blitbuffer.COLOR_WHITE, ink_light = false }
    local bg_type = setting("LOCK_BG_TYPE")

    if bg_type == "auto" then
        local ok, night = pcall(function()
            local switch = require("css_auto_preset_switch")
            return switch.isEnabled() and switch.isNightPresetActive()
        end)
        bg_type = (ok and night) and "black" or "white"
    end

    if bg_type == "black" then
        bg.color = Blitbuffer.COLOR_BLACK
        bg.ink_light = true
    elseif bg_type == "sleep" then
        local ok, bb = pcall(function()
            local ReaderUI = package.loaded["apps/reader/readerui"]
            local ui = ReaderUI and ReaderUI.instance
            local book_data = require("css_infobox").loadLastBookData()
            return require("css_infobox_background").getLockBackground(ui, book_data, use_kept)
        end)
        if ok and bb then
            bg.bb = bb

            applySleepOverlay(bb)
            local mean, spread = sampleLuminance(bb)
            bg.ink_light = wantsLightInk(mean)

            bg.needs_panel = spread >= 12
        end
    end

    bg.ink = bg.ink_light and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    return bg
end

-- Prompts and layout

local PROMPT_ENTER   = function() return _("Please enter your 4-digit PIN.") end
local PROMPT_CURRENT = function() return _("Please enter your current 4-digit PIN.") end
local PROMPT_CHOOSE  = function() return _("Please choose a 4-digit PIN.") end
local PROMPT_CONFIRM = function() return _("Please confirm your 4-digit PIN.") end
local MSG_INCORRECT  = function() return _("Sorry, incorrect PIN. Please try again.") end
local MSG_MISMATCH   = function() return _("Sorry, the PINs didn't match. Please try again.") end

local REF_W, REF_H = 1264, 1680

local COMPLETE_DELAY = 0.3

local MESSAGE_RAISE = { ruled = 27, filled = 17, outlined = 17, plain = -8 }

local BUTTON_STYLES = { plain = true, ruled = true, outlined = true, filled = true }

local PROMPT_PX = 44
local OWNER_PX  = 36

local MAX_OWNER_LINES = 3

local UNLOCKED_DELAY = 0.5

-- PIN pad

local PinPad = InputContainer:extend{
    name              = "CssLockPinPad",
    modal             = true,
    use_kept_background = false,
    prompt            = nil,
    width_prompts     = nil,  
    allow_cancel      = false,
    static            = false,
    on_complete       = nil,
    cancel_glyph      = nil,
    cancel_cluster    = nil,
    cancel_font       = nil,
    cancel_glyph_size = nil,
    on_cancel         = nil,
}

local function pxFace(font_name, target_px)
    local k = Screen:scaleBySize(1000) / 1000
    local size = target_px / k
    local ok, face = pcall(Font.getFace, Font, font_name, size)
    return (ok and face) or Font:getFace("cfont", size)
end

local ZCluster = {}
ZCluster.__index = ZCluster

local function inkBounds(tw)
    local sz = tw:getSize()
    local bb = Blitbuffer.new(sz.w, sz.h, Blitbuffer.TYPE_BBRGB32)
    bb:fill(Blitbuffer.COLOR_WHITE)
    tw:paintTo(bb, 0, 0)
    local x0, y0, x1, y1 = sz.w, sz.h, -1, -1
    for yy = 0, sz.h - 1 do
        for xx = 0, sz.w - 1 do
            if bb:getPixel(xx, yy):getColorRGB32().r < 160 then
                if xx < x0 then x0 = xx end
                if xx > x1 then x1 = xx end
                if yy < y0 then y0 = yy end
                if yy > y1 then y1 = yy end
            end
        end
    end
    bb:free()
    if x1 < 0 then return 0, 0, sz.w, sz.h end
    return x0, y0, x1 + 1, y1 + 1
end

local function newZCluster(spec, px, font, ink)
    local self = setmetatable({ parts = {} }, ZCluster)
    local gap, rise = px(spec.gap), px(spec.rise)
    local gx0, gy0, gx1, gy1
    local prev_right
    for i, part in ipairs(spec) do
        local tw = TextWidget:new{ text = part[1], face = pxFace(font, px(part[2])), fgcolor = ink }
        local x0, y0, x1, y1 = inkBounds(tw)
        local bx = prev_right and (prev_right + gap - x0) or 0
        local by = -(i - 1) * rise - tw:getBaseline()
        self.parts[#self.parts + 1] = { tw = tw, x = bx, y = by }
        prev_right = bx + x1
        gx0 = math.min(gx0 or bx + x0, bx + x0); gy0 = math.min(gy0 or by + y0, by + y0)
        gx1 = math.max(gx1 or bx + x1, bx + x1); gy1 = math.max(gy1 or by + y1, by + y1)
    end
    self.cx, self.cy = (gx0 + gx1) / 2, (gy0 + gy1) / 2
    self.w, self.h = gx1 - gx0, gy1 - gy0
    return self
end

function ZCluster:getSize() return { w = self.w, h = self.h } end

function ZCluster:drawCentered(bb, cx, cy)
    for _i, part in ipairs(self.parts) do
        part.tw:paintTo(bb, math.floor(cx - self.cx + part.x), math.floor(cy - self.cy + part.y))
    end
end

function ZCluster:free()
    for _i, part in ipairs(self.parts) do part.tw:free() end
end

local function ownerLines(text, face, width)
    local render = require("css_infobox_render")
    local util = require("util")
    local lines = {}
    for raw in ((text or "") .. "\n"):gmatch("(.-)\n") do
        local para = util.trim(raw)
        if para ~= "" then
            for _i, l in ipairs(render.wrapText(para, face, width)) do lines[#lines + 1] = l end
        end
    end
    if #lines > MAX_OWNER_LINES then
        for i = #lines, MAX_OWNER_LINES + 1, -1 do lines[i] = nil end
        lines[MAX_OWNER_LINES] = lines[MAX_OWNER_LINES] .. "\u{2026}"
    end
    for i, l in ipairs(lines) do
        if render.getTextWidth(l, face) > width then
            local chars = util.splitToChars(l)
            while #chars > 1 and render.getTextWidth(table.concat(chars) .. "\u{2026}", face) > width do chars[#chars] = nil end
            lines[i] = table.concat(chars) .. "\u{2026}"
        end
    end
    return lines
end

function PinPad:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.pin = ""
    self.message = self.prompt or ""

    local bg = self.background or prepareBackground(self.use_kept_background)
    self.bg_bb     = bg.bb
    self.bg_color  = bg.color
    self.ink       = bg.ink
    self.ink_light = bg.ink_light
    local saved_style = setting("LOCK_BUTTON_STYLE")
    self.button_style = self.button_style or (BUTTON_STYLES[saved_style] and saved_style or "plain")
    self.button_shape = self.button_shape or setting("LOCK_BUTTON_SHAPE")
    self.dithered = self.bg_bb ~= nil
    self.panel_color = (bg.needs_panel and (self.ink_light and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)) or nil

    if not self.static then
        local full = Geom:new{ x = 0, y = 0, w = w, h = h }
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = full } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = full } }
        self.ges_events.Hold  = { GestureRange:new{ ges = "hold",  range = full } }
        self.ges_events.Pan   = { GestureRange:new{ ges = "pan",   range = full } }
    end

    local s = math.min(w / REF_W, h / REF_H)
    local function px(v) return math.max(1, math.floor(v * s + 0.5)) end
    self.px = px

    local style    = self.button_style
    local shaped   = style == "filled" or style == "outlined"
    local shape_d  = px(150)
    local lock_px  = px(88)
    local lock_cy, last_row_cy = px(238), px(588) + 3 * px(171)
    local content_top    = lock_cy - math.floor(lock_px * 0.45)
    local owner_face = pxFace("cfont", px(OWNER_PX))
    self._owner_lines = (self.owner_text and self.owner_text:match("%S"))
        and ownerLines(self.owner_text, owner_face, 3 * px(187) + 2 * px(20)) or {}
    self._owner_line_h = math.floor(px(OWNER_PX) * 1.5)
    local owner_gap = px(83)
    local owner_extra = #self._owner_lines > 0 and (owner_gap + #self._owner_lines * self._owner_line_h) or 0
    local keypad_edge = shaped and math.floor(shape_d / 2) or math.floor(px(80) * 0.36)
    local content_bottom = last_row_cy + keypad_edge + owner_extra
    local off_y = math.floor((h - (content_bottom - content_top)) / 2) - content_top
    local max_bottom = last_row_cy + math.floor(shape_d / 2) + owner_extra
    local off_y_max  = math.floor((h - (max_bottom - content_top)) / 2) - content_top
    self.lock_px = lock_px
    self.cell_w  = px(187)
    self.pitch   = self.cell_w + px(20)
    self.block_w = 3 * self.cell_w + 2 * (self.pitch - self.cell_w)
    self.block_x = math.floor((w - self.block_w) / 2)
    self.row_h   = px(171)
    self.line_w  = math.max(1, px(2))

    self.lock_cy    = off_y + lock_cy
    self.header_top = off_y + px(335)
    local raise = MESSAGE_RAISE[style] or 27
    self.message_raise = raise < 0 and -px(-raise) or px(raise)
    self.dots_cy    = off_y + px(399)
    self.rule_y     = off_y + px(493)
    local first_row = off_y + px(588)
    self.owner_y    = off_y + last_row_cy + keypad_edge + owner_gap

    local function col_cx(c) return self.block_x + math.floor(self.cell_w / 2) + (c - 1) * self.pitch end
    self.col_cx = col_cx

    local rows = {
        { "1", "2", "3" },
        { "4", "5", "6" },
        { "7", "8", "9" },
        { self.allow_cancel and "cancel" or "", "0", "" },
    }
    self.keys = {}
    for r, row in ipairs(rows) do
        for c, id in ipairs(row) do
            if id ~= "" then
                self.keys[#self.keys + 1] = {
                    id  = id,
                    cx  = col_cx(c),
                    cy  = first_row + (r - 1) * self.row_h,
                    sep = r <= 3,
                }
            end
        end
    end
    self.back = { id = "back", cx = col_cx(3), cy = first_row + 3 * self.row_h }

    local half_visual = math.max(math.floor(self.cell_w / 2), math.floor(shape_d / 2), px(25))
    local left  = col_cx(1) - half_visual
    local right = col_cx(3) + half_visual
    local cx = math.floor(w / 2)
    local prompt_face = pxFace("cfont", px(PROMPT_PX))
    local prompt_w = 0
    for _i, text in ipairs(self.width_prompts or { self.prompt or "" }) do
        prompt_w = math.max(prompt_w, require("css_infobox_render").getTextWidth(text, prompt_face))
    end
    prompt_w = math.min(prompt_w, self.block_w)
    local half_w = math.max(cx - left, right - cx, math.ceil(prompt_w / 2))
    local pad = px(64)
    self.msg_w = 2 * half_w + px(10)
    self.panel = {
        x = cx - half_w - pad,
        y = off_y_max + content_top - pad,
        w = 2 * (half_w + pad),
        h = (max_bottom - content_top) + 2 * pad,
        r = px(36),
    }

    self._text = {}
    self:_buildText()
end

function PinPad:_freeMessage()
    for _i, tw in ipairs(self._text.message or {}) do
        if tw.free then tw:free() end
    end
    self._text.message = nil
end

function PinPad:_freeText()
    local t = self._text or {}
    self:_freeMessage()
    for k, tw in pairs(t) do
        if k ~= "keys" and k ~= "message" and k ~= "owner" and tw.free then tw:free() end
    end
    for _i, tw in ipairs(t.owner or {}) do
        if tw.free then tw:free() end
    end
    for _k, tw in pairs(t.keys or {}) do
        if tw.free then tw:free() end
    end
    self._text = {}
end

function PinPad:_buildMessage()
    self:_freeMessage()
    local face = pxFace("cfont", self.px(PROMPT_PX))
    local render = require("css_infobox_render")
    local lines = render.wrapText(self.message or "", face, self.msg_w or self.block_w)
    self._text.message = {}
    for i, line in ipairs(lines) do
        self._text.message[i] = TextWidget:new{ text = line, face = face, fgcolor = self.ink }
    end
    self._message_line_h = math.floor(self.px(PROMPT_PX) * 1.55)
end

function PinPad:_buildText()
    self:_freeText()
    local px = self.px
    local black = self.ink
    local digit_face = pxFace("cfont", px(80))

    self._text.lock = TextWidget:new{ text = GLYPH_LOCK, face = pxFace("cfont", self.lock_px), fgcolor = black }
    self._text.unlocked = TextWidget:new{ text = GLYPH_UNLOCKED, face = pxFace("cfont", self.lock_px), fgcolor = black }
    self._text.back = TextWidget:new{ text = GLYPH_BACKSPACE, face = pxFace("cfont", px(58)), fgcolor = black }
    self._text.keys = {}
    for _i, key in ipairs(self.keys) do
        if key.id == "cancel" then
            if self.cancel_cluster then
                self._text.keys[key.id] = newZCluster(self.cancel_cluster, px, self.cancel_font or "cfont", black)
            else
                self._text.keys[key.id] = TextWidget:new{ text = self.cancel_glyph or GLYPH_BACK, face = pxFace(self.cancel_font or "cfont", px(self.cancel_glyph_size or 70)), fgcolor = black }
            end
        else
            self._text.keys[key.id] = TextWidget:new{ text = key.id, face = digit_face, fgcolor = black }
        end
    end
    self:_buildMessage()
    self._text.owner = {}
    local owner_face = pxFace("cfont", px(OWNER_PX))
    for i, line in ipairs(self._owner_lines or {}) do
        self._text.owner[i] = TextWidget:new{ text = line, face = owner_face, fgcolor = black }
    end
end

function PinPad:_headerRegion()
    local pad = self.px(10)
    return Geom:new{
        x = self.block_x,
        y = self.header_top - pad - math.max(0, self.message_raise),
        w = self.block_w,
        h = self.rule_y - self.header_top + pad + math.max(0, self.message_raise),
    }
end

local function drawCentered(tw, bb, cx, cy)
    if tw.drawCentered then return tw:drawCentered(bb, cx, cy) end
    local sz = tw:getSize()
    tw:paintTo(bb, cx - math.floor(sz.w / 2), cy - math.floor(sz.h / 2))
end

function PinPad:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    local px = self.px
    local ink = self.ink
    local filled   = self.button_style == "filled"
    local outlined = self.button_style == "outlined"
    local ruled    = self.button_style == "ruled"

    if self.bg_bb then
        bb:blitFrom(self.bg_bb, x, y, 0, 0,
                    math.min(w, self.bg_bb:getWidth()), math.min(h, self.bg_bb:getHeight()))
    else
        bb:paintRect(x, y, w, h, self.bg_color)
    end
    if self.panel_color then
        local pn = self.panel
        bb:paintRoundedRect(x + pn.x, y + pn.y, pn.w, pn.h, self.panel_color, pn.r)
    end

    drawCentered(self._unlocked and self._text.unlocked or self._text.lock, bb, x + math.floor(w / 2), y + self.lock_cy)

    if #self.pin == 0 then
        local lines = self._text.message or {}
        local line_h = self._message_line_h
        local area_h = self.rule_y - px(20) - self.header_top
        local top = y + self.header_top - self.message_raise + math.max(0, math.floor((area_h - #lines * line_h) / 2))
        for i, tw in ipairs(lines) do
            drawCentered(tw, bb, x + math.floor(w / 2), top + math.floor((i - 0.5) * line_h))
        end
    else
        local d = px(24)
        local spacing = px(54)
        local ring = math.max(1, px(2))
        local first_cx = self.col_cx(2) - math.floor((PIN_LENGTH - 1) * spacing / 2)
        for i = 1, PIN_LENGTH do
            local cx = first_cx + (i - 1) * spacing
            local left, top = x + cx - math.floor(d / 2), y + self.dots_cy - math.floor(d / 2)
            if i <= #self.pin then
                bb:paintRoundedRect(left, top, d, d, ink, math.floor(d / 2))
            else
                bb:paintBorder(left, top, d, d, ring, ink, math.floor(d / 2), true)
            end
        end
    end
    drawCentered(self._text.back, bb, x + self.back.cx, y + self.back.cy)

    if ruled then
        bb:paintRect(x + self.block_x, y + self.rule_y, self.block_w, self.line_w, ink)
    end

    local circle_d = px(150)
    local shape_r = self.button_shape == "square" and px(34) or math.floor(circle_d / 2)
    local circle_color = self.ink_light and Blitbuffer.Color8(0x44) or Blitbuffer.Color8(0xE0)
    local sep_color = self.ink_light and Blitbuffer.COLOR_GRAY_7 or Blitbuffer.COLOR_GRAY
    for _i, key in ipairs(self.keys) do
        if key.id ~= "cancel" then
            local left, top = x + key.cx - math.floor(circle_d / 2), y + key.cy - math.floor(circle_d / 2)
            if filled then
                bb:paintRoundedRect(left, top, circle_d, circle_d, circle_color, shape_r)
            elseif outlined then
                bb:paintBorder(left, top, circle_d, circle_d, math.max(2, px(3)), ink, shape_r, true)
            end
        end
        drawCentered(self._text.keys[key.id], bb, x + key.cx, y + key.cy)
        if key.sep and ruled then
            bb:paintRect(x + key.cx - math.floor(self.cell_w / 2), y + key.cy + px(76),
                         self.cell_w, math.max(1, px(2)), sep_color)
        end
    end

    for i, tw in ipairs(self._text.owner or {}) do
        drawCentered(tw, bb, x + math.floor(w / 2), y + self.owner_y + math.floor((i - 0.5) * self._owner_line_h))
    end
end

function PinPad:getSize() return self.dimen end

function PinPad:onCloseWidget()
    if self._night_state then
        pcall(function() require("css_infobox_render").restoreNightMode(self._night_state) end)
        self._night_state = nil
    end
    self:_freeText()
    if self.bg_bb then
        pcall(self.bg_bb.free, self.bg_bb)
        self.bg_bb = nil
    end
end

function PinPad:_hit(pos)
    local function inside(k)
        return math.abs(pos.x - k.cx) <= self.pitch / 2 and math.abs(pos.y - k.cy) <= self.row_h / 2
    end
    if inside(self.back) then return self.back end
    for _i, key in ipairs(self.keys) do
        if inside(key) then return key end
    end
    return nil
end

function PinPad:_refreshHeader()
    UIManager:setDirty(self, "ui", self:_headerRegion())
end

function PinPad:showUnlocked(then_fn)
    self._completing = true
    self._unlocked = true
    local r = self.lock_px
    local d = self.dimen
    UIManager:setDirty(self, "ui", Geom:new{
        x = d.x + math.floor(d.w / 2) - r, y = d.y + self.lock_cy - r,
        w = 2 * r, h = 2 * r,
    })
    UIManager:scheduleIn(UNLOCKED_DELAY, function()
        if then_fn then then_fn() end
    end)
end

function PinPad:_setMessage(text)
    self.message = text or ""
    self:_buildMessage()
end

function PinPad:setPrompt(text)
    self.prompt = text
    self.pin = ""
    self:_setMessage(text)
    self:_refreshHeader()
end

function PinPad:reject(text)
    self.pin = ""
    self:_setMessage(text)
    self:_refreshHeader()
end

function PinPad:reset()
    self.pin = ""
    self:_setMessage(self.prompt)
    UIManager:setDirty(self, "ui")
end

function PinPad:setLockout(remaining_fn, text_fn)
    self._lock_remaining = remaining_fn
    self._lock_text = text_fn
    self.pin = ""
    self:_setMessage(text_fn(remaining_fn()))
    self:_refreshHeader()
end

function PinPad:close(refresh)
    UIManager:close(self, refresh or "full")
end

function PinPad:onTap(_arg, ges)
    if self._completing then return true end
    if self._lock_remaining then
        if self._lock_remaining() > 0 then
            local locked_key = ges and ges.pos and self:_hit(ges.pos)
            if locked_key and locked_key.id == "cancel" and self.on_cancel then
                self.on_cancel(self)
            else
                self:setLockout(self._lock_remaining, self._lock_text)
            end
            return true
        end
        self._lock_remaining, self._lock_text = nil, nil
        self:_setMessage(self.prompt)
        self:_refreshHeader()
    end
    local key = ges and ges.pos and self:_hit(ges.pos)
    if not key then return true end

    if key.id == "cancel" then
        if self.on_cancel then self.on_cancel(self) end
    elseif key.id == "back" then
        if #self.pin == 0 then return true end
        self.pin = self.pin:sub(1, -2)
        if #self.pin == 0 then self:_setMessage(self.prompt) end
        self:_refreshHeader()
    elseif #self.pin < PIN_LENGTH then
        if #self.pin == 0 then self:_setMessage(self.prompt) end
        self.pin = self.pin .. key.id
        self:_refreshHeader()
        if #self.pin == PIN_LENGTH then
            local entered = self.pin
            self._completing = true
            UIManager:scheduleIn(COMPLETE_DELAY, function()
                self._completing = false
                if self.on_complete and UIManager:isWidgetShown(self) then
                    self.on_complete(self, entered)
                end
            end)
        end
    end
    return true
end

function PinPad:onSwipe() return true end

function PinPad:onHold(_, ges)
    local locked_out = self._lock_remaining and self._lock_remaining() > 0
    if self.static or self._completing or locked_out or #self.pin == 0 then return true end
    local key = ges and ges.pos and self:_hit(ges.pos)
    if key and key.id == "back" then
        self.pin = ""
        self:_setMessage(self.prompt)
        self:_refreshHeader()
    end
    return true
end
function PinPad:onPan()   return true end

function PinPad:handleEvent(event)
    local handled = InputContainer.handleEvent(self, event)

    if self.static then return handled end
    return true
end

-- Lock-out and unlock flow

local function lockoutRemaining()
    local locked_until, secs = setting("LOCK_LOCKED_UNTIL"), setting("LOCK_LOCKOUT_SECS")
    if locked_until <= 0 then return 0 end
    local now = os.time()
    if locked_until - now > secs then
        locked_until = now + secs
        saveLockState{ LOCK_LOCKED_UNTIL = locked_until }
    end
    return math.max(0, locked_until - now)
end

local function durationText(secs)
    secs = math.floor(secs)
    if secs > 0 and secs % 3600 == 0 then
        return string.format("%d %s", secs / 3600, ngettext("hr", "hrs", secs / 3600))
    elseif secs > 0 and secs % 60 == 0 then
        return string.format("%d %s", secs / 60, ngettext("min", "mins", secs / 60))
    end
    return string.format("%d %s", secs, ngettext("sec", "secs", secs))
end

local function lockoutMessage(secs)
    local mins, rest = math.floor(secs / 60), secs % 60
    local parts = {}
    if mins > 0 then parts[#parts + 1] = durationText(mins * 60) end
    if rest > 0 or mins == 0 then parts[#parts + 1] = durationText(rest) end
    return string.format(_("Too many attempts. Please try again in %s."), table.concat(parts, " "))
end

local active_unlock_pad = nil

local function antiGhostingFlash()
    if not store():isTrue(SETTINGS.LOCK_ANTI_GHOSTING_FLASH) then return false end
    return require("css_antighost").flash(store():readSetting(SETTINGS.ANTI_GHOSTING_FLASH_COLOR))
end

local function showUnlock(night_state)
    if active_unlock_pad and UIManager:isWidgetShown(active_unlock_pad) then
        local flashed = antiGhostingFlash()
        active_unlock_pad:reset()
        if flashed then UIManager:setDirty(active_unlock_pad, "full") end
        if lockoutRemaining() > 0 then
            active_unlock_pad:setLockout(lockoutRemaining, lockoutMessage)
        end
        return active_unlock_pad
    end

    if not night_state then
        local ok, st = pcall(function() return require("css_infobox_render").suppressNightMode() end)
        night_state = ok and st or nil
    end

    local pad = PinPad:new{
        _night_state = night_state,
        owner_text   = setting("LOCK_OWNER_MESSAGE"),
        prompt       = PROMPT_ENTER(),
        allow_cancel = true,
        cancel_cluster = SLEEP_CLUSTER,
        cancel_font  = SLEEP_FONT,
        use_kept_background = true,

        on_cancel    = function(this)
            this:reset()
            UIManager:suspend()
        end,
        on_complete  = function(this, pin)
            if lockoutRemaining() > 0 then
                this:setLockout(lockoutRemaining, lockoutMessage)
                return
            end
            if verifyPin(pin) then
                clearLockState()
                active_unlock_pad = nil
                this:showUnlocked(function() this:close("full") end)
                return
            end
            local failed = setting("LOCK_FAILED_ATTEMPTS") + 1
            if failed >= MAX_ATTEMPTS then
                local rounds = setting("LOCK_LOCKOUT_ROUNDS")
                local secs = math.min(BASE_LOCKOUT_SECONDS * (2 ^ rounds), MAX_LOCKOUT_SECONDS)
                saveLockState{ LOCK_FAILED_ATTEMPTS = 0, LOCK_LOCKOUT_ROUNDS = rounds + 1,
                               LOCK_LOCKED_UNTIL = os.time() + secs, LOCK_LOCKOUT_SECS = secs }
                this:setLockout(lockoutRemaining, lockoutMessage)
            else
                saveLockState{ LOCK_FAILED_ATTEMPTS = failed }
                this:reject(MSG_INCORRECT())
            end
        end,
    }
    active_unlock_pad = pad
    antiGhostingFlash()
    UIManager:show(pad, "full")
    if lockoutRemaining() > 0 then
        pad:setLockout(lockoutRemaining, lockoutMessage)
    end
    return pad
end

local function isUnlockPadShown()
    return active_unlock_pad ~= nil and UIManager:isWidgetShown(active_unlock_pad)
end

-- Deferred locking
local function deferralApplies(slept_at, was_locked)
    local delay = tonumber(setting("LOCK_DELAY_SECONDS")) or 0
    if delay <= 0 or was_locked or not slept_at then return false end
    local elapsed = os.time() - slept_at
    return elapsed >= 0 and elapsed < delay
end

local launch_checked = false

local function lockOnLaunch()
    if launch_checked then return end
    launch_checked = true
    if not (isEnabled() and store():isTrue(SETTINGS.LOCK_ON_LAUNCH)) then return end

    UIManager:nextTick(function()
        local ok, err = pcall(showUnlock)
        if not ok then
            require("logger").warn("[Customisable Sleep Screen] launch lock failed: " .. tostring(err))
        end
    end)
end

-- Forgot-PIN recovery
local RESET_FILE_NAMES = { "reset-lock", "reset-lock.txt" }

local PLUGIN_FOLDER = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".")

local function pluginFolder()
    return PLUGIN_FOLDER
end

local function resetFolders()
    local dirs, seen = {}, {}
    for _i, dir in ipairs{ PLUGIN_FOLDER, Device.home_dir, require("datastorage"):getDataDir() } do
        if dir and dir ~= "" and not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    return dirs
end

local reset_checked = false

local function applyResetFile()
    if reset_checked then return false end
    reset_checked = true

    local lfs = require("libs/libkoreader-lfs")
    local found = {}
    for _i, dir in ipairs(resetFolders()) do
        for _j, name in ipairs(RESET_FILE_NAMES) do
            local path = (dir:gsub("/$", "")) .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then found[#found + 1] = path end
        end
    end
    if #found == 0 then return false end

    for _i, path in ipairs(found) do
        if not os.remove(path) then
            require("logger").warn("[Customisable Sleep Screen] couldn't delete " .. path .. "; lock reset skipped")
            UIManager:nextTick(function()
                UIManager:show(require("ui/widget/infomessage"):new{
                    flush_events_on_show = true,
                    text = _("Couldn't reset the lock screen: the reset-lock file couldn't be deleted. Is the storage read-only?"),
                })
            end)
            return false
        end
    end

    resetPin()

    UIManager:nextTick(function()
        UIManager:show(require("ui/widget/infomessage"):new{
            flush_events_on_show = true,
            text = _("Lock screen reset.\n\nYou can set a new PIN in the Customisable Sleep Screen settings."),
        })
    end)
    return true
end

local function showResetNote()
    UIManager:show(require("ui/widget/infomessage"):new{
        flush_events_on_show = true,
        text = string.format(_("PIN saved.\n\nIf you ever forget it, create an empty file named \"reset-lock\" inside the plugin's folder (%s) and restart KOReader. That clears the PIN."), pluginFolder()),
    })
end

-- Menu flows

local function askPin(prompt, on_pin, width_prompts)
    local pad = PinPad:new{
        prompt        = prompt,
        width_prompts = width_prompts,
        allow_cancel  = true,
        on_complete  = on_pin,
        on_cancel    = function(this) this:close("ui") end,
    }
    UIManager:show(pad, "ui")
    return pad
end

local function setPinFlow(on_done)
    local first
    return askPin(PROMPT_CHOOSE(), function(this, pin)
        if not first then
            first = pin
            this:setPrompt(PROMPT_CONFIRM())
        elseif pin == first then
            savePin(pin)
            this:close("ui")
            if on_done then on_done(true) end
            showResetNote()
        else
            first = nil
            this.prompt = PROMPT_CHOOSE()
            this:reject(MSG_MISMATCH())
        end
    end, { PROMPT_CHOOSE(), PROMPT_CONFIRM() })
end

local function verifyThen(on_ok)
    askPin(PROMPT_CURRENT(), function(this, pin)
        if verifyPin(pin) then
            this:close("ui")
            on_ok()
        else
            this:reject(MSG_INCORRECT())
        end
    end)
end

local function preview()
    local pad = PinPad:new{
        prompt       = PROMPT_ENTER(),
        allow_cancel = true,
        static       = true,
        owner_text   = setting("LOCK_OWNER_MESSAGE"),
    }

    local ok, night_state = pcall(function() return require("css_infobox_render").suppressNightMode() end)
    require("css_menu_helpers").showSleepScreenPreviewWidget(pad, nil, ok and night_state or nil)
end

-- Gate

local Gate = InputContainer:extend{
    name       = "CssLockGate",
    modal      = true,
    invisible  = true,
    on_dismiss = nil,
}

function Gate:init()
    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = range } }
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = range } }
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
end

function Gate:_dismiss()
    if self._dismissed then return true end
    self._dismissed = true
    if self.on_dismiss then self.on_dismiss(self) end
    return true
end
Gate.onTap = Gate._dismiss
Gate.onSwipe = Gate._dismiss
Gate.onAnyKeyPressed = Gate._dismiss

function Gate:onResume()
    Device.screen_saver_lock = true
end
function Gate:onSuspend()
    Device.screen_saver_lock = false
end

function Gate:handleEvent(event)
    InputContainer.handleEvent(self, event)
    return true
end

-- Exports

return {
    PIN_LENGTH = PIN_LENGTH,
    hasPin     = hasPin,
    isEnabled  = isEnabled,
    showUnlock = showUnlock,
    durationText = durationText,
    lockOnLaunch = lockOnLaunch,
    applyResetFile = applyResetFile,
    isUnlockPadShown = isUnlockPadShown,
    deferralApplies  = deferralApplies,
    setPinFlow = setPinFlow,
    verifyThen = verifyThen,
    preview    = preview,
    Gate       = Gate,
    PinPad     = PinPad,
}
