-- SPDX-License-Identifier: MIT
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local Android = InputContainer:extend{name="kobo_android",is_doc_only=false}
function Android:init() self.ui.menu:registerToMainMenu(self) end
local function base_dir() return os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android" end
local function read_file(path)
    local f = io.open(path, "rb"); if not f then return "(no file: " .. path .. ")" end
    local s = f:read("*a") or ""; f:close(); return s
end

-- ---------------------------------------------------------------------------------------------------------
-- Download of the Android packages (GitHub releases) with a progress display, then install
--   1. release androidv1.0.0     -> ZIP, extracted into .adds (creates .adds/android)
--   2. release androidapkv1.0.0  -> APKs, copied to <android>/apps (installed by android.sh on the next start)
-- ---------------------------------------------------------------------------------------------------------
local DL_REPO = "arduinodude456/DApps"
local PACKAGES = {
    {tag = "androidv1.0.0", kind = "system", label = "Android system"},
    {tag = "androidapkv1.0.0", kind = "apps", label = "Apps"},
}
local JOB_SH, JOB_PID, JOB_RC = "/tmp/kobo_android_job.sh", "/tmp/kobo_android_job.pid", "/tmp/kobo_android_job.rc"
local JOB_ERR = "/tmp/kobo_android_job.err"
local download_running = false

local function q(s) return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'" end
local function parent_dir(p) return (p:gsub("/+$", ""):match("^(.*)/[^/]*$")) or "/" end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end
local function fsize(p)
    local f = io.open(p, "rb"); if not f then return 0 end
    local n = f:seek("end"); f:close(); return n or 0
end
local function read_small(p, max)
    local f = io.open(p, "rb"); if not f then return "" end
    local s = f:read("*a") or ""; f:close()
    if max and #s > max then s = "..." .. s:sub(-max) end
    return s
end
local function ran_ok(cmd) local r = os.execute(cmd); return r == 0 or r == true end
local function have_cmd(name) return ran_ok("command -v " .. name .. " >/dev/null 2>&1") end
local function fmt_mb(n) return string.format("%.1f", (n or 0) / 1048576) end
local function fmt_eta(sec)
    if not sec or sec < 0 or sec > 86400 then return "?" end
    if sec < 90 then return math.ceil(sec) .. " s" end
    return math.ceil(sec / 60) .. " min"
end
local function progress_text(title, done, total, speed)
    if total and total > 0 then
        local pct = math.min(100, math.floor(done * 100 / total))
        local w = 20
        local f = math.floor(pct * w / 100)
        local t = string.format("%s\n\n[%s%s] %d %%\n%s / %s MB", title, string.rep("#", f), string.rep("-", w - f),
            pct, fmt_mb(done), fmt_mb(total))
        if speed and speed > 1024 then
            t = t .. string.format("\n%.1f MB/s, about %s left", speed / 1048576, fmt_eta((total - done) / speed))
        end
        return t, pct
    end
    return string.format("%s\n\n%s MB", title, fmt_mb(done)), 0
end

-- Lists the assets of a release (GitHub API).  kind "system": the largest ZIP; kind "apps": every APK/ZIP.
-- Returns a list of {name,size,url} or nil,error.
local function find_assets(tag, kind)
    local ok_https, https = pcall(require, "ssl.https")
    local ltn12 = require("ltn12")
    local ok_su, socketutil = pcall(require, "socketutil")
    if not ok_https then return nil, "ssl.https is missing in this KOReader" end
    local body = {}
    if ok_su then socketutil:set_timeout(15, 30) end
    local ok, r1, code = pcall(https.request, {
        url = "https://api.github.com/repos/" .. DL_REPO .. "/releases/tags/" .. tag,
        sink = ltn12.sink.table(body),
        headers = {["User-Agent"] = "kobo-android-plugin", ["Accept"] = "application/vnd.github+json"},
    })
    if ok_su then socketutil:reset_timeout() end
    if not ok then return nil, tostring(r1) end
    if code ~= 200 then return nil, "GitHub answered " .. tostring(code or r1) .. " for " .. tag .. " (Wi-Fi connected?)" end
    local ok_json, JSON = pcall(require, "json")
    if not ok_json then return nil, "json module is missing" end
    local ok_dec, data = pcall(JSON.decode, table.concat(body))
    if not ok_dec or type(data) ~= "table" or type(data.assets) ~= "table" then return nil, "Could not read release data for " .. tag end
    local list, names, best = {}, {}, nil
    for _, a in ipairs(data.assets) do
        names[#names + 1] = tostring(a.name)
        if type(a.name) == "string" and a.browser_download_url then
            local lower = a.name:lower()
            local item = {name = (a.name:gsub("[^%w%._%-]", "_")), size = tonumber(a.size), url = a.browser_download_url}
            if kind == "system" then
                if lower:match("%.zip$") and (not best or (item.size or 0) > (best.size or 0)) then best = item end
            elseif lower:match("%.apk$") or lower:match("%.zip$") then
                list[#list + 1] = item
            end
        end
    end
    if kind == "system" and best then list = {best} end
    if #list == 0 then return nil, "No " .. (kind == "system" and "ZIP" or "APK/ZIP") .. " in release " .. tag .. ". Files: " .. table.concat(names, ", ") end
    return list
end

-- Runs a shell command in the background; its exit code ends up in JOB_RC.
local function spawn(cmd)
    os.remove(JOB_RC)
    local f = io.open(JOB_SH, "w"); if not f then return false end
    f:write("echo $$ > " .. JOB_PID .. "\n" .. cmd .. "\necho $? > " .. JOB_RC .. ".tmp && mv " .. JOB_RC .. ".tmp " .. JOB_RC .. "\n")
    f:close()
    os.execute("sh " .. JOB_SH .. " >/dev/null 2>&1 &")
    return true
end
local function kill_job()
    os.execute("kill $(cat " .. JOB_PID .. " 2>/dev/null) 2>/dev/null; killall curl wget unzip 2>/dev/null")
end
local function job_rc()
    local f = io.open(JOB_RC, "r"); if not f then return nil end
    local s = f:read("*a"); f:close()
    return tonumber(s and s:match("%-?%d+"))
end

local function ca_bundle()
    local cands = {"/mnt/onboard/.adds/koreader/data/ca-bundle.crt", "/etc/ssl/certs/ca-certificates.crt"}
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs.currentdir then table.insert(cands, 1, lfs.currentdir() .. "/data/ca-bundle.crt") end
    for _, c in ipairs(cands) do if exists(c) then return c end end
end

-- Fallback without curl/wget: plain Lua (no resume; the display only updates while data arrives).
local function lua_download(url, dest, on_progress)
    local https = require("ssl.https")
    local http = require("socket.http")
    for _ = 1, 8 do
        local st = {buf = {}, blen = 0, fh = nil, n = 0, last = 0}
        local function sink(chunk)
            if not chunk or chunk == "" then return 1 end
            if st.fh then
                st.fh:write(chunk); st.n = st.n + #chunk
            else
                st.buf[#st.buf + 1] = chunk; st.blen = st.blen + #chunk
                if st.blen > 65536 then -- not a redirect page any more: the real file
                    st.fh = io.open(dest, "wb"); if not st.fh then return nil, "cannot write file" end
                    st.fh:write(table.concat(st.buf)); st.n = st.blen; st.buf = {}
                end
            end
            if st.fh and os.time() ~= st.last then st.last = os.time(); on_progress(st.n) end
            return 1
        end
        local mod = url:match("^https") and https or http
        local ok, r1, code, headers = pcall(mod.request, {url = url, sink = sink, redirect = false,
            headers = {["User-Agent"] = "kobo-android-plugin"}})
        if st.fh then st.fh:close() end
        if not ok then return nil, tostring(r1) end
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local loc = headers and headers.location
            if not loc then return nil, "redirect without target" end
            if loc:sub(1, 1) == "/" then loc = url:match("^(https?://[^/]+)") .. loc end
            url = loc
        elseif code == 200 then
            if not st.fh then
                local f = io.open(dest, "wb"); if not f then return nil, "cannot write file" end
                f:write(table.concat(st.buf)); f:close()
            end
            return true
        else
            os.remove(dest)
            return nil, "HTTP " .. tostring(code or r1)
        end
    end
    return nil, "too many redirects"
end

local function download_and_install()
    if download_running then
        UIManager:show(InfoMessage:new{text = "The download is already running."}); return
    end
    download_running = true
    local state = {cancelled = false}
    local cur, refreshing = nil, false

    local function say(text, on_tap)
        refreshing = true
        if cur then UIManager:close(cur) end
        local cb = function() if not refreshing and on_tap then on_tap() end end
        cur = InfoMessage:new{text = text, tap_close_callback = cb, dismiss_callback = cb}
        UIManager:show(cur)
        refreshing = false
    end
    local function finish(text) download_running = false; say(text) end
    local function cancel()
        state.cancelled = true
        kill_job()
        finish("Download paused. Progress is kept:\nopen this menu again to continue.")
    end
    local function poll(interval, on_tick, on_done)
        local function tick()
            if state.cancelled then return end
            local rc = job_rc()
            if rc then on_done(rc); return end
            on_tick()
            UIManager:scheduleIn(interval, tick)
        end
        UIManager:scheduleIn(interval, tick)
    end

    local todo, step = {}, 0

    local function next_item()
        step = step + 1
        local item = todo[step]
        if not item then
            finish("Done!\n\nThe Android system and the apps are installed in\n" .. parent_dir(base_dir()) .. ".\n\nRestart KOReader and open \"Android KitKat 4.4 (Chroot)\". The APKs in the apps folder are installed when Android starts (Android must be stopped now).")
            return
        end
        local asset, kind = item.asset, item.kind
        local is_apk = asset.name:lower():match("%.apk$") ~= nil
        local apps_dir = base_dir() .. "/apps"
        local dest
        if is_apk then
            os.execute("mkdir -p " .. q(apps_dir))
            dest = apps_dir .. "/" .. asset.name
        else
            dest = "/mnt/onboard/" .. asset.name
        end

        local function unzip_job(args, label, on_ok)
            local t0 = os.time()
            say(label .. " ...\n\nThis can take a few minutes. Please do not switch off.")
            spawn("unzip " .. args .. " >" .. JOB_ERR .. " 2>&1")
            poll(3, function()
                say(string.format("%s ...\n\n%d s elapsed. Please do not switch off.", label, os.time() - t0))
            end, function(rc)
                if rc == 0 then
                    os.remove(dest)
                    on_ok()
                else
                    finish("Extracting failed (code " .. tostring(rc) .. ", storage full?):\n" .. read_small(JOB_ERR, 300)
                        .. "\n\nThe ZIP file is kept:\n" .. dest)
                end
            end)
        end
        local function install()
            if is_apk then
                os.execute("chmod 0644 " .. q(dest))
                next_item()
            elseif kind == "system" then
                local target = parent_dir(base_dir())
                -- This plugin (android.koplugin) stays untouched so the download feature is not overwritten.
                unzip_job("-o -q " .. q(dest) .. " -x '*android.koplugin/*' -d " .. q(target),
                    "Extracting " .. asset.name .. " to " .. target, next_item)
            else -- ZIP with APKs: flat copy of every .apk into the apps folder
                os.execute("mkdir -p " .. q(apps_dir))
                unzip_job("-o -j -q " .. q(dest) .. " '*.apk' -d " .. q(apps_dir),
                    "Extracting apps from " .. asset.name, next_item)
            end
        end

        local have = fsize(dest)
        if asset.size and have == asset.size then install(); return end
        if asset.size and have > asset.size then os.remove(dest); have = 0 end

        local title = string.format("Downloading %s (%d/%d)", asset.name, step, #todo)
        local t_start, s_start, last_pct = os.time(), have, -1
        local function show(done)
            local dt = os.time() - t_start
            local speed = dt > 0 and (done - s_start) / dt or nil
            local text, pct = progress_text(title, done, asset.size, speed)
            if pct ~= last_pct or not asset.size then
                last_pct = pct
                say(text .. "\n\nTap = pause (progress is kept)", cancel)
            end
        end
        local function done_download(rc)
            local size = fsize(dest)
            if rc == 0 or (asset.size and size == asset.size) then
                if asset.size and size ~= asset.size then
                    finish("Download incomplete (" .. fmt_mb(size) .. " of " .. fmt_mb(asset.size) .. " MB). Open this menu again.")
                else
                    install()
                end
            else
                finish("Download failed (code " .. tostring(rc) .. "):\n" .. read_small(JOB_ERR, 300)
                    .. "\n\nOpen this menu again to continue.")
            end
        end

        show(have)
        local ca = ca_bundle()
        local cmd
        if have_cmd("curl") then
            cmd = "curl -L -f --connect-timeout 20 --retry 5 --retry-delay 3 -C - " .. (ca and ("--cacert " .. q(ca) .. " ") or "")
                .. "-o " .. q(dest) .. " " .. q(asset.url) .. " 2>" .. JOB_ERR
        elseif have_cmd("wget") then
            cmd = "wget -c -O " .. q(dest) .. " " .. q(asset.url) .. " 2>" .. JOB_ERR
        end
        if cmd then
            spawn(cmd)
            poll(2, function() show(fsize(dest)) end, done_download)
        else
            -- Blocking Lua download (no curl/wget on this device)
            UIManager:scheduleIn(0.5, function()
                local ok, e = lua_download(asset.url, dest, function(n) show(n); UIManager:forceRePaint() end)
                if ok then done_download(0) else finish("Download failed:\n" .. tostring(e)) end
            end)
        end
    end

    local function start()
        say("Looking up the releases ...")
        UIManager:scheduleIn(0.5, function()
            for _, pkg in ipairs(PACKAGES) do
                local list, err = find_assets(pkg.tag, pkg.kind)
                if not list then finish("Release not found:\n" .. tostring(err)); return end
                for _, a in ipairs(list) do todo[#todo + 1] = {asset = a, kind = pkg.kind} end
            end
            next_item()
        end)
    end

    -- Make sure Wi-Fi is on first (if KOReader offers it), then start.
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(start)
    else
        start()
    end
end

function Android:addToMainMenu(items)
    items.kobo_android_download={text="Download and install Android",sorting_hint="tools",callback=function()
        local ConfirmBox = require("ui/widget/confirmbox")
        local tags = {}
        for _, p in ipairs(PACKAGES) do tags[#tags + 1] = p.tag end
        UIManager:show(ConfirmBox:new{
            text="Download the Android system and the apps over Wi-Fi (releases "..table.concat(tags, ", ")..") and install them into "..parent_dir(base_dir()).."?\n\nNeeds free storage for the ZIP and the extracted files. Existing Android files are overwritten, Android must be stopped. An interrupted download can be resumed.",
            ok_text="Download",
            ok_callback=download_and_install,
        })
    end}
    items.kobo_android_diag={text="Android diagnostics (stage test)",sorting_hint="tools",callback=function()
        UIManager:show(InfoMessage:new{text="Running stage test (about 20-40 s) ...",timeout=2})
        UIManager:nextTick(function()
            os.execute("sh '"..base_dir().."/android.sh' stages >/dev/null 2>&1")
            local text = read_file(base_dir().."/stages.log")
            UIManager:show(TextViewer:new{title="Stage test",text=text,width=require("device").screen:getWidth(),height=require("device").screen:getHeight()})
        end)
    end}
    items.kobo_android_gapps={text="Install Google Apps (core)",sorting_hint="tools",callback=function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text="Install Google Apps (Play Store, Play Services, login, setup wizard) into the Android image?\n\nRequires /mnt/onboard/gapps-kern.zip and about 100 MB of free space in the image. Android must be stopped.",
            ok_text="Install",
            ok_callback=function()
                UIManager:show(InfoMessage:new{text="Installing Google Apps ...\nThis takes a few minutes.",timeout=2})
                UIManager:nextTick(function()
                    local f=io.popen("sh '"..base_dir().."/android.sh' gapps 2>&1")
                    local out=f and f:read("*a") or "(no output)"
                    if f then f:close() end
                    local dev=require("device")
                    UIManager:show(TextViewer:new{title="Google Apps installation",text=out,width=dev.screen:getWidth(),height=dev.screen:getHeight()})
                end)
            end,
        })
    end}
    local function run_android_cmd(arg,title,wait)
        UIManager:show(InfoMessage:new{text=wait,timeout=2})
        UIManager:nextTick(function()
            local f=io.popen("sh '"..base_dir().."/android.sh' "..arg.." 2>&1")
            local out=f and f:read("*a") or "(no output)"
            if f then f:close() end
            local dev=require("device")
            UIManager:show(TextViewer:new{title=title,text=out,width=dev.screen:getWidth(),height=dev.screen:getHeight()})
        end)
    end
    items.kobo_android_gapps_diag={text="Check Google Apps (diagnostics)",sorting_hint="tools",callback=function()
        run_android_cmd("gapps-diag","Google Apps diagnostics","Checking Google Apps ...")
    end}
    items.kobo_android_reset={text="Reset Android (delete all data)",sorting_hint="tools",callback=function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text="Delete ALL Android data (apps, accounts, Google Apps, settings) and install a fresh Android image?\n\nThis cannot be undone. The android-shared folder is kept. Android must be stopped.",
            ok_text="Delete everything",
            ok_callback=function() run_android_cmd("reset","Reset Android","Resetting Android ...\nThis takes a few minutes.") end,
        })
    end}
    items.kobo_android_wipe={text="Remove Android (free up storage)",sorting_hint="tools",callback=function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text="Delete the Android image with ALL data to free up storage? Android will only start again after a reinstall (install.sh).\n\nThis cannot be undone.",
            ok_text="Remove",
            ok_callback=function() run_android_cmd("wipe","Remove Android","Removing Android image ...") end,
        })
    end}
    items.kobo_android={text="Android KitKat 4.4 (Chroot)",sorting_hint="tools",callback=function()
        local base=os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android"
        local ok,module=pcall(dofile,base.."/lua/appdock_android.lua")
        if not ok then UIManager:show(InfoMessage:new{text="Could not load the Android module:\n"..tostring(module)}); return end
        module.open()
    end}
end
return Android
