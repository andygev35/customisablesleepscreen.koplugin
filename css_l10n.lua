-- Translation loader

local logger = require("logger")
local _dir   = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/"

-- Plural-rule expression parser

local function tokenisePluralExpr(expr)
    local tokens = {}
    local i, len = 1, #expr
    while i <= len do
        local c = expr:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c:match("%d") then
            local j = i
            while j <= len and expr:sub(j, j):match("%d") do j = j + 1 end
            tokens[#tokens + 1] = { kind = "num", value = tonumber(expr:sub(i, j - 1)) }
            i = j
        elseif c == "n" then
            tokens[#tokens + 1] = { kind = "n" }
            i = i + 1
        elseif expr:sub(i, i + 1) == "&&" then
            tokens[#tokens + 1] = { kind = "&&" }; i = i + 2
        elseif expr:sub(i, i + 1) == "||" then
            tokens[#tokens + 1] = { kind = "||" }; i = i + 2
        elseif expr:sub(i, i + 1) == "==" then
            tokens[#tokens + 1] = { kind = "==" }; i = i + 2
        elseif expr:sub(i, i + 1) == "!=" then
            tokens[#tokens + 1] = { kind = "!=" }; i = i + 2
        elseif expr:sub(i, i + 1) == "<=" then
            tokens[#tokens + 1] = { kind = "<=" }; i = i + 2
        elseif expr:sub(i, i + 1) == ">=" then
            tokens[#tokens + 1] = { kind = ">=" }; i = i + 2
        elseif c == "<" or c == ">" or c == "%" or c == "!"
            or c == "(" or c == ")" or c == "?" or c == ":" then
            tokens[#tokens + 1] = { kind = c }
            i = i + 1
        else
            i = i + 1
        end
    end
    return tokens
end

local function buildPluralEvaluator(tokens)
    local pos = { 1 }

    local function peek()
        return tokens[pos[1]]
    end
    local function advance()
        pos[1] = pos[1] + 1
    end

    local parseTernary

    local function parsePrimary()
        local t = peek()
        if not t then return function() return 0 end end
        if t.kind == "num" then
            advance()
            local v = t.value
            return function() return v end
        elseif t.kind == "n" then
            advance()
            return function(n) return n end
        elseif t.kind == "(" then
            advance()
            local inner = parseTernary()
            if peek() and peek().kind == ")" then advance() end
            return inner
        end
        advance()
        return function() return 0 end
    end

    local function parseUnary()
        if peek() and peek().kind == "!" then
            advance()
            local operand = parseUnary()
            return function(n)
                local v = operand(n)
                if v == 0 or v == false then return 1 else return 0 end
            end
        end
        return parsePrimary()
    end

    local function parseModulo()
        local left = parseUnary()
        while peek() and peek().kind == "%" do
            advance()
            local right = parseUnary()
            local prev = left
            left = function(n) return prev(n) % right(n) end
        end
        return left
    end

    local function boolToNum(v)
        if v == 0 or v == false or v == nil then return 0 end
        return 1
    end

    local function parseRelational()
        local left = parseModulo()
        while peek() and (peek().kind == "<" or peek().kind == "<=" or peek().kind == ">" or peek().kind == ">=") do
            local op = peek().kind
            advance()
            local right = parseModulo()
            local prev = left
            if op == "<" then
                left = function(n) return boolToNum(prev(n) < right(n)) end
            elseif op == "<=" then
                left = function(n) return boolToNum(prev(n) <= right(n)) end
            elseif op == ">" then
                left = function(n) return boolToNum(prev(n) > right(n)) end
            else
                left = function(n) return boolToNum(prev(n) >= right(n)) end
            end
        end
        return left
    end

    local function parseEquality()
        local left = parseRelational()
        while peek() and (peek().kind == "==" or peek().kind == "!=") do
            local op = peek().kind
            advance()
            local right = parseRelational()
            local prev = left
            if op == "==" then
                left = function(n) return boolToNum(prev(n) == right(n)) end
            else
                left = function(n) return boolToNum(prev(n) ~= right(n)) end
            end
        end
        return left
    end

    local function parseAnd()
        local left = parseEquality()
        while peek() and peek().kind == "&&" do
            advance()
            local right = parseEquality()
            local prev = left
            left = function(n)
                if boolToNum(prev(n)) == 0 then return 0 end
                return boolToNum(right(n))
            end
        end
        return left
    end

    local function parseOr()
        local left = parseAnd()
        while peek() and peek().kind == "||" do
            advance()
            local right = parseAnd()
            local prev = left
            left = function(n)
                if boolToNum(prev(n)) ~= 0 then return 1 end
                return boolToNum(right(n))
            end
        end
        return left
    end

    parseTernary = function()
        local cond = parseOr()
        if peek() and peek().kind == "?" then
            advance()
            local whenTrue = parseTernary()
            if peek() and peek().kind == ":" then advance() end
            local whenFalse = parseTernary()
            return function(n)
                if boolToNum(cond(n)) ~= 0 then return whenTrue(n) end
                return whenFalse(n)
            end
        end
        return cond
    end

    local ok, evaluator = pcall(function() return parseTernary() end)
    if not ok then return nil end
    return evaluator
end

local function compilePluralRule(expr)
    if not expr or expr == "" then return nil end
    local tokens = tokenisePluralExpr(expr)
    if #tokens == 0 then return nil end
    local evaluator = buildPluralEvaluator(tokens)
    if not evaluator then return nil end
    return function(n)
        local ok, result = pcall(evaluator, n)
        if not ok then return 0 end
        local idx = math.floor(tonumber(result) or 0)
        return idx
    end
end

-- .po file parsing

local function decodeQuoted(body)
    local out, i, len = {}, 1, #body
    while i <= len do
        local c = body:sub(i, i)
        if c == "\\" and i < len then
            local nxt = body:sub(i + 1, i + 1)
            if nxt == "n" then out[#out + 1] = "\n"
            elseif nxt == "t" then out[#out + 1] = "\t"
            elseif nxt == "r" then out[#out + 1] = "\r"
            elseif nxt == '"' then out[#out + 1] = '"'
            elseif nxt == "\\" then out[#out + 1] = "\\"
            else out[#out + 1] = nxt end
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function extractQuoted(line)
    return line:match('^%s*"(.*)"%s*$')
end

local function readCatalogue(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local catalogue = {}
    local pluralRule = nil

    local msgid, msgid_plural, msgstrs
    local active = nil

    local function commitEntry()
        if msgid == nil then return end
        if msgid == "" then
            local header = (msgstrs and msgstrs[0]) or ""
            local pf_expr = header:match("Plural%-Forms:[^\n]*plural%s*=%s*([^;]+);")
            if pf_expr then
                pluralRule = compilePluralRule(pf_expr)
            end
        elseif msgid_plural then
            local variants = {}
            local has_any = false
            for idx, str in pairs(msgstrs or {}) do
                if str ~= "" then variants[idx] = str; has_any = true end
            end
            if has_any then catalogue[msgid] = variants end
        else
            local str = msgstrs and msgstrs[0]
            if str and str ~= "" then catalogue[msgid] = str end
        end
        msgid, msgid_plural, msgstrs, active = nil, nil, nil, nil
    end

    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line == "" then
            commitEntry()
        elseif line:sub(1, 1) == "#" then
        else
            local id = line:match('^msgid%s+"')
            local id_plural = line:match('^msgid_plural%s+"')
            local str_idx = line:match('^msgstr%[(%d+)%]%s+"')
            local str_plain = line:match('^msgstr%s+"')
            local continuation = extractQuoted(line)

            if id then
                commitEntry()
                local body = line:match('^msgid%s+"(.*)"%s*$') or ""
                msgid = decodeQuoted(body)
                msgstrs = {}
                active = "id"
            elseif id_plural then
                local body = line:match('^msgid_plural%s+"(.*)"%s*$') or ""
                msgid_plural = decodeQuoted(body)
                active = "id_plural"
            elseif str_idx then
                local idx = tonumber(str_idx)
                local body = line:match('^msgstr%[%d+%]%s+"(.*)"%s*$') or ""
                msgstrs[idx] = decodeQuoted(body)
                active = "str" .. idx
            elseif str_plain then
                local body = line:match('^msgstr%s+"(.*)"%s*$') or ""
                msgstrs[0] = decodeQuoted(body)
                active = "str0"
            elseif continuation and active then
                local piece = decodeQuoted(continuation)
                if active == "id" then
                    msgid = msgid .. piece
                elseif active == "id_plural" then
                    msgid_plural = msgid_plural .. piece
                elseif active:sub(1, 3) == "str" then
                    local idx = tonumber(active:sub(4)) or 0
                    msgstrs[idx] = (msgstrs[idx] or "") .. piece
                end
            end
        end
    end
    commitEntry()
    f:close()

    return catalogue, pluralRule
end

-- Catalogue loading

local function currentLanguageTag()
    local configured = G_reader_settings and G_reader_settings:readSetting("language")
    if type(configured) == "string" and configured ~= "" then
        return configured
    end
    local env = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    return env:match("^([a-zA-Z_]+)") or "en"
end

local loadedCatalogue = nil
local installedWrapper = false

local function tryLoadCatalogueFor(tag)
    local path = _dir .. "l10n/" .. tag .. ".po"
    local entries, pluralRule = readCatalogue(path)
    if not entries or not next(entries) then return nil end
    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    logger.info("[Customisable Sleep Screen] i18n: loaded " .. path .. " (" .. count .. " strings)")
    return { entries = entries, pluralRule = pluralRule }
end

local function ensureCatalogueLoaded()
    if loadedCatalogue ~= nil then
        return loadedCatalogue or nil
    end

    local tag = currentLanguageTag()
    if tag == "en" or tag:match("^en_") then
        loadedCatalogue = false
        return nil
    end

    local found = tryLoadCatalogueFor(tag)
    if not found then
        local base = tag:match("^([a-zA-Z]+)")
        if base and base ~= tag then
            found = tryLoadCatalogueFor(base)
        end
    end

    loadedCatalogue = found or false
    return found
end

-- Lookup

local function lookupSingular(msgid)
    local catalogue = ensureCatalogueLoaded()
    if not catalogue then return nil end
    local entry = catalogue.entries[msgid]
    if type(entry) == "string" then return entry end
    if type(entry) == "table" then return entry[0] or entry[1] end
    return nil
end

local function lookupPlural(msgid, count)
    local catalogue = ensureCatalogueLoaded()
    if not catalogue then return nil end
    local entry = catalogue.entries[msgid]
    if type(entry) == "table" then
        local idx = 0
        if catalogue.pluralRule then
            idx = catalogue.pluralRule(count) or 0
        else
            idx = (count == 1) and 0 or 1
        end
        return entry[idx]
    elseif type(entry) == "string" and count == 1 then
        return entry
    end
    return nil
end

-- gettext hook install/uninstall

local function install()
    if installedWrapper then return end

    if not ensureCatalogueLoaded() then
        return
    end

    local baseGettext = package.loaded["gettext"]
    if not baseGettext then
        local ok, mod = pcall(require, "gettext")
        if not ok or not mod then
            logger.warn("[Customisable Sleep Screen] i18n: gettext module unavailable, translations disabled")
            return
        end
        baseGettext = mod
    end

    local function pluralised(msgid, msgid_plural, n)
        local hit = lookupPlural(msgid, n)
        if hit then return hit end
        if type(baseGettext) == "table" and type(baseGettext.ngettext) == "function" then
            return baseGettext.ngettext(msgid, msgid_plural, n)
        end
        return baseGettext((n == 1) and msgid or msgid_plural)
    end

    local proxy
    local baseMeta = getmetatable(baseGettext)
    if baseMeta and baseMeta.__call then
        proxy = setmetatable({ ngettext = pluralised }, {
            __call = function(_, msgid)
                return lookupSingular(msgid) or baseGettext(msgid)
            end,
            __index = baseGettext,
        })
    elseif type(baseGettext) == "function" then
        proxy = setmetatable({ ngettext = pluralised }, {
            __call = function(_, msgid)
                return lookupSingular(msgid) or baseGettext(msgid)
            end,
        })
        for k, v in pairs(baseGettext) do
            proxy[k] = v
        end
    else
        logger.warn("[Customisable Sleep Screen] i18n: unrecognised gettext shape (" .. type(baseGettext) .. ")")
        return
    end

    package.loaded["gettext"] = proxy
    installedWrapper = true
    logger.info("[Customisable Sleep Screen] i18n: active for language '" .. currentLanguageTag() .. "'")
end

local function uninstall()
    if not installedWrapper then return end
    package.loaded["gettext"] = nil
    pcall(require, "gettext")
    installedWrapper = false
    loadedCatalogue = nil
    logger.info("[Customisable Sleep Screen] i18n: deactivated")
end

return {
    install   = install,
    uninstall = uninstall,
    getLang   = currentLanguageTag,
}
