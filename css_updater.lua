-- Checks GitHub for a newer release of the plugin and, if found, offers to download and install it.

local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local _           = require("gettext")

local _plugin_dir = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/"

local meta = (loadfile(_plugin_dir .. "_meta.lua") or function() return {} end)()
local GITHUB_REPO     = meta.github
local PLUGIN_DIR_NAME = (meta.name or "customisablesleepscreen") .. ".koplugin"

local Updater = {}

-- Version comparison

local function shellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function versionSortKey(version_string)
    local padded = {}
    for component in tostring(version_string):gsub("^v", ""):gmatch("%d+") do
        padded[#padded + 1] = string.format("%08d", tonumber(component) or 0)
    end
    return table.concat(padded, ".")
end

local function isNewerVersion(candidate, baseline)
    return versionSortKey(candidate) > versionSortKey(baseline)
end

-- GitHub API

local function fetchJSON(url, user_agent, accept_header)
    local json = require("json")

    local function viaLuasocket()
        local ok_req, http, ltn12, socket, socketutil = pcall(function()
            return require("socket.http"), require("ltn12"), require("socket"), require("socketutil")
        end)
        if not ok_req then return nil end

        local chunks = {}
        local headers = { ["User-Agent"] = user_agent }
        if accept_header then headers["Accept"] = accept_header end

        local ok_call, status_code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local code = socket.skip(1, http.request({
                url = url, method = "GET", headers = headers,
                sink = ltn12.sink.table(chunks), redirect = true,
            }))
            socketutil:reset_timeout()
            return code
        end)
        pcall(function() socketutil:reset_timeout() end)

        if ok_call and status_code == 200 then
            local ok_decode, parsed = pcall(json.decode, table.concat(chunks))
            if ok_decode then return parsed end
        end
        return nil
    end

    local function viaCurl()
        local accept_flag = accept_header and (" -H " .. shellQuote("Accept: " .. accept_header)) or ""
        local handle = io.popen(string.format(
            "curl -s -L --connect-timeout 5 --max-time 20 -H %s%s %s",
            shellQuote("User-Agent: " .. user_agent), accept_flag, shellQuote(url)))
        if not handle then return nil end
        local raw = handle:read("*a")
        handle:close()
        if not raw or raw == "" then return nil end
        local ok_decode, parsed = pcall(json.decode, raw)
        return ok_decode and parsed or nil
    end

    return viaLuasocket() or viaCurl()
end

-- Archive extraction & filesystem cleanup

local function walkFiles(root_dir, relative_prefix, sink, excluded_top_level)
    local lfs = require("libs/libkoreader-lfs")
    relative_prefix = relative_prefix or ""
    excluded_top_level = excluded_top_level or {}

    local ok_dir, iterator, dir_state = pcall(lfs.dir, root_dir)
    if not ok_dir then return end

    for name in iterator, dir_state do
        if name ~= "." and name ~= ".." then
            local relative_path = relative_prefix == "" and name or (relative_prefix .. "/" .. name)
            if not excluded_top_level[relative_path] then
                local absolute_path = root_dir .. "/" .. name
                local kind = lfs.attributes(absolute_path, "mode")
                if kind == "directory" then
                    walkFiles(absolute_path, relative_path, sink, excluded_top_level)
                elseif kind == "file" then
                    sink[relative_path] = absolute_path
                end
            end
        end
    end
end

local function isEmptyDir(dir_path)
    local lfs = require("libs/libkoreader-lfs")
    local ok_dir, iterator, dir_state = pcall(lfs.dir, dir_path)
    if not ok_dir then return true end
    for name in iterator, dir_state do
        if name ~= "." and name ~= ".." then return false end
    end
    return true
end

local function removeEmptyDirsUnder(dir_path)
    local lfs = require("libs/libkoreader-lfs")
    local ok_dir, iterator, dir_state = pcall(lfs.dir, dir_path)
    if not ok_dir then return end
    for name in iterator, dir_state do
        if name ~= "." and name ~= ".." then
            local child = dir_path .. "/" .. name
            if lfs.attributes(child, "mode") == "directory" then
                removeEmptyDirsUnder(child)
            end
        end
    end
    if isEmptyDir(dir_path) then
        pcall(lfs.rmdir, dir_path)
    end
end

local function keepsExistingCopy(dest_root, relative_path, protected)
    if not protected[relative_path] then return false end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(dest_root .. "/" .. relative_path, "mode") == "file"
end

local function unpackStripRoot(zip_path, dest_root, protected)
    protected = protected or {}

    local ok_lib, Archiver = pcall(require, "ffi/archiver")
    if not (ok_lib and Archiver and Archiver.Reader) then
        return false, _("archive extractor unavailable")
    end

    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        local open_err = archive.err
        archive:close()
        return false, open_err or _("could not open archive")
    end

    local placed = {}
    local failure

    for entry in archive:iterate() do
        local relative_path = entry.path and entry.path:match("^[^/]+/(.+)$")
        if relative_path and relative_path ~= "" then
            if keepsExistingCopy(dest_root, relative_path, protected) then
                placed[relative_path] = true
            elseif archive:extractToPath(entry.path, dest_root .. "/" .. relative_path) then
                placed[relative_path] = true
            else
                failure = archive.err or _("extract failed")
                break
            end
        end
    end
    archive:close()
    if failure then return false, failure end

    local files_on_disk = {}
    walkFiles(dest_root, "", files_on_disk, { icons = true, wallpapers = true })
    for relative_path, absolute_path in pairs(files_on_disk) do
        if not placed[relative_path] and not protected[relative_path] then
            pcall(os.remove, absolute_path)
        end
    end
    pcall(removeEmptyDirsUnder, dest_root)

    return true
end

-- Connectivity

local function showUpdateError(message)
    UIManager:show(InfoMessage:new { text = message, timeout = 3 })
end

local function whenOnline(action)
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() then
        action()
        return
    end
    NetworkMgr:runWhenConnected(function()
        if NetworkMgr:isConnected() then action() end
    end)
end

-- Download

local function downloadWithLuasocket(url, out_path, user_agent)
    local ok_req, http, ltn12, socket, socketutil = pcall(function()
        return require("socket.http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if not ok_req then return false, nil end

    local tmp_path = out_path .. ".tmp"
    pcall(os.remove, tmp_path)
    local file = io.open(tmp_path, "wb")
    if not file then
        return false, _("the file could not be saved")
    end

    local ok_call, status_code, response_headers = pcall(function()
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, 300)
        local sink = socketutil.file_sink and socketutil.file_sink(file) or ltn12.sink.file(file)
        local code, hdrs = socket.skip(1, http.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = user_agent,
                ["Accept"]     = "application/zip, application/octet-stream, */*",
            },
            sink = sink,
            redirect = true,
        }))
        socketutil:reset_timeout()
        return code, hdrs
    end)
    pcall(function() file:close() end)

    local failure_reason
    if not ok_call then
        pcall(function() socketutil:reset_timeout() end)
        failure_reason = _("the connection failed")
    elseif status_code == socketutil.TIMEOUT_CODE or status_code == socketutil.SINK_TIMEOUT_CODE then
        failure_reason = _("the connection timed out")
    elseif status_code == socketutil.SSL_HANDSHAKE_CODE then
        failure_reason = _("the secure connection failed")
    elseif not response_headers then
        failure_reason = _("there was no response")
    elseif tonumber(status_code) ~= 200 then
        failure_reason = "HTTP " .. tostring(status_code)
    end

    if failure_reason then
        pcall(os.remove, tmp_path)
        return false, failure_reason
    end

    pcall(os.remove, out_path)
    if os.rename(tmp_path, out_path) then
        return true, nil
    end

    local ok_copy = pcall(function()
        local src, dst = io.open(tmp_path, "rb"), io.open(out_path, "wb")
        if not (src and dst) then error("copy failed") end
        dst:write(src:read("*all"))
        src:close(); dst:close()
    end)
    pcall(os.remove, tmp_path)
    if ok_copy then return true, nil end
    return false, _("the file could not be saved")
end

local function downloadWithCurl(url, out_path)
    pcall(os.remove, out_path)
    local exit_status = os.execute(string.format(
        "curl -sfL --connect-timeout 10 --max-time 300 -o %s %s",
        shellQuote(out_path), shellQuote(url)))
    return exit_status == 0 or exit_status == true
end

local function downloadZip(url, out_path, user_agent)
    local ok, reason = downloadWithLuasocket(url, out_path, user_agent)
    if ok then return true end
    if downloadWithCurl(url, out_path) then return true end
    return false, reason
end

-- Release parsing helpers

local function plainTextFromMarkdown(text)
    return (text or "")
        :gsub("#+%s*", "")
        :gsub("%*%*(.-)%*%*", "%1")
        :gsub("%*(.-)%*", "%1")
        :gsub("`(.-)`", "%1")
end

local function findZipAssetUrl(release)
    if not release.assets then return nil end
    for _, asset in ipairs(release.assets) do
        if asset.name:match("%.zip$") then
            return asset.browser_download_url
        end
    end
    return nil
end

-- Public entry points

function Updater.install(zip_url, old_version, new_version)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    UIManager:show(InfoMessage:new { text = _("Downloading update..."), timeout = 1 })

    UIManager:scheduleIn(0.1, function()
        local cache_dir = DataStorage:getSettingsDir() .. "/customisablesleepscreen_cache"
        if lfs.attributes(cache_dir, "mode") ~= "directory" then
            lfs.mkdir(cache_dir)
        end
        local zip_path = cache_dir .. "/" .. PLUGIN_DIR_NAME .. ".zip"
        local user_agent = "KOReader-CustomisableSleepScreen/" .. old_version

        local downloaded, reason = downloadZip(zip_url, zip_path, user_agent)
        if not downloaded then
            pcall(os.remove, zip_path)
            pcall(lfs.rmdir, cache_dir)
            local label = _("Download failed.")
            if reason then
                label = label:gsub("%.%s*$", "") .. " (" .. tostring(reason) .. ")"
            end
            showUpdateError(label)
            return
        end

        local plugin_path = DataStorage:getDataDir() .. "/plugins/" .. PLUGIN_DIR_NAME
        local protected_files = { ["css_custom_quotes.lua"] = true }
        local ok, err = unpackStripRoot(zip_path, plugin_path, protected_files)
        pcall(os.remove, zip_path)
        pcall(lfs.rmdir, cache_dir)

        if not ok then
            UIManager:show(InfoMessage:new {
                text    = _("Installation failed: ") .. tostring(err),
                timeout = 5,
            })
            return
        end

        UIManager:show(ConfirmBox:new {
            text = _("Customisable Sleep Screen updated to v") .. new_version .. ".\n\n" ..
                _("Restart KOReader now?"),
            ok_text     = _("Restart"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end)
end

function Updater.check(installed_version)
    whenOnline(function()
        UIManager:show(InfoMessage:new { text = _("Checking for updates..."), timeout = 1 })

        UIManager:scheduleIn(0.1, function()
            local user_agent = "KOReader-CustomisableSleepScreen/" .. installed_version
            local release = fetchJSON(
                "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases/latest",
                user_agent, "application/vnd.github.v3+json")

            if not release or not release.tag_name then
                showUpdateError(_("Could not check for updates."))
                return
            end

            if release.draft or release.prerelease then
                UIManager:show(InfoMessage:new {
                    text    = string.format(_("Customisable Sleep Screen is up to date (v%s)"), installed_version),
                    timeout = 3,
                })
                return
            end

            local latest_version = release.tag_name:gsub("^v", "")
            if not isNewerVersion(latest_version, installed_version) then
                UIManager:show(InfoMessage:new {
                    text    = string.format(_("Customisable Sleep Screen is up to date (v%s)"), installed_version),
                    timeout = 3,
                })
                return
            end

            local zip_url = findZipAssetUrl(release)
            local notes = plainTextFromMarkdown(release.body)

            local TextViewer = require("ui/widget/textviewer")
            local viewer
            viewer = TextViewer:new {
                title = _("Update available"),
                text  = _("Installed: ") .. installed_version .. "\n" ..
                    _("Latest: ") .. latest_version .. "\n\n" .. notes,
                buttons_table = {
                    {
                        {
                            text     = _("Close"),
                            callback = function() UIManager:close(viewer) end,
                        },
                        {
                            text     = _("Update and restart"),
                            callback = function()
                                UIManager:close(viewer)
                                if not zip_url then
                                    UIManager:show(InfoMessage:new {
                                        text    = _("No download available for this release."),
                                        timeout = 3,
                                    })
                                    return
                                end
                                Updater.install(zip_url, installed_version, latest_version)
                            end,
                        },
                    },
                },
                add_default_buttons = false,
            }
            UIManager:show(viewer)
        end)
    end)
end

return Updater
