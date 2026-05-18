-- ================================================================
--  halle.lua — Platorelay Bypass Listener (Opus rebuild)
--  Repo: https://github.com/lucivaantarez/bp
--  Author: Saturnity (lucivaantarez)
--
--  SETUP (run once in Termux):
--    pkg install termux-api lua54 curl -y
--    termux-setup-storage
--    curl -L https://raw.githubusercontent.com/lucivaantarez/bp/refs/heads/main/halle.lua -o /storage/emulated/0/Download/halle.lua
--    lua /storage/emulated/0/Download/halle.lua
--
--  USE:        bypass
--  EXIT:       Ctrl+C  (or type 0 + Enter)
--  LOG:        ~/.halle/halle.log
-- ================================================================

-- ─── CONFIG ─────────────────────────────────────────────────────
local VERSION = "2.2.0"

local CONFIG = {
    api_key       = "b71c5cd5-874c-49da-874a-15f31fb829ca",
    api_url       = "https://api.izen.lol/v1/bypass?url=",
    refresh_url   = "https://api.izen.lol/v1/refresh?url=",
    target_host   = "auth.platorelay.com",

    script_path   = "/storage/emulated/0/Download/halle.lua",
    remote_url    = "https://raw.githubusercontent.com/lucivaantarez/bp/refs/heads/main/halle.lua",
    license_path  = "/storage/emulated/0/Delta/Internals/Cache/license",

    poll_interval = 1,      -- seconds between clipboard checks
    api_timeout   = 20,     -- curl timeout in seconds
    max_retries   = 3,      -- API retry attempts before giving up
    retry_base    = 2,      -- exponential backoff base (seconds)
}

local TMP_DIR     = "/data/data/com.termux/files/usr/tmp"
local STATE_DIR   = (os.getenv("HOME") or TMP_DIR) .. "/.halle"
local LOG_FILE    = STATE_DIR .. "/halle.log"
local TMP_RESP    = TMP_DIR .. "/halle_resp.json"
local TMP_UPDATE  = TMP_DIR .. "/halle_update.lua"
local DEDUP_FILE  = STATE_DIR .. "/last_link"

-- ─── ANSI COLORS ────────────────────────────────────────────────
local C = {
    reset = "\27[0m",  dim    = "\27[2m",  bold = "\27[1m",
    red   = "\27[31m", green  = "\27[32m", yellow = "\27[33m",
    blue  = "\27[34m", purple = "\27[35m", cyan   = "\27[36m",
}

-- ─── LOGGING ────────────────────────────────────────────────────
os.execute("mkdir -p " .. STATE_DIR .. " 2>/dev/null")

local function ts()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function log_write(level, msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(string.format("[%s] [%s] %s\n", ts(), level, msg))
        f:close()
    end
end

local function info(msg)
    print(C.cyan .. "[*] " .. C.reset .. msg)
    log_write("INFO", msg)
end
local function ok(msg)
    print(C.green .. "[+] " .. C.reset .. msg)
    log_write("OK", msg)
end
local function warn(msg)
    print(C.yellow .. "[!] " .. C.reset .. msg)
    log_write("WARN", msg)
end
local function err(msg)
    print(C.red .. "[-] " .. C.reset .. msg)
    log_write("ERR", msg)
end
local function dim(msg)
    print(C.dim .. "    " .. msg .. C.reset)
end

-- ─── FILE HELPERS ───────────────────────────────────────────────
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function write_file(path, content)
    local f, e = io.open(path, "w")
    if not f then
        log_write("ERR", "write_file open failed: " .. tostring(e))
        return false
    end
    local ok_write = f:write(content)
    f:close()
    return ok_write ~= nil
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function ensure_parent_dir(path)
    local dir = path:match("(.*)/[^/]+$")
    if dir then
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
end

-- ─── URL ENCODING ───────────────────────────────────────────────
local function url_encode(s)
    return (s:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- ─── JSON PARSER (handles escapes + nested) ─────────────────────
-- Pulls a string value for `field`, properly handling \" \\ \n etc.
local function json_string(str, field)
    -- find: "field" : "
    local pattern = '"' .. field:gsub('([%.%+%-%*%?%[%]%^%$%(%)%%])', '%%%1') .. '"%s*:%s*"'
    local start_idx = str:find(pattern)
    if not start_idx then return nil end
    local value_start = str:find('"', start_idx + #field + 2, true)
    if not value_start then return nil end
    value_start = value_start + 1

    local buf = {}
    local i = value_start
    while i <= #str do
        local c = str:sub(i, i)
        if c == "\\" then
            local nxt = str:sub(i + 1, i + 1)
            if nxt == "n" then buf[#buf+1] = "\n"
            elseif nxt == "t" then buf[#buf+1] = "\t"
            elseif nxt == "r" then buf[#buf+1] = "\r"
            elseif nxt == '"' then buf[#buf+1] = '"'
            elseif nxt == "\\" then buf[#buf+1] = "\\"
            elseif nxt == "/" then buf[#buf+1] = "/"
            else buf[#buf+1] = nxt end
            i = i + 2
        elseif c == '"' then
            return table.concat(buf)
        else
            buf[#buf+1] = c
            i = i + 1
        end
    end
    return nil
end

-- ─── URL VALIDATION ─────────────────────────────────────────────
-- Strict: must be a real http(s) URL, must contain target host as a
-- proper hostname component (not just substring inside random text).
local function extract_target_url(text)
    if not text or #text == 0 or #text > 4096 then return nil end

    -- Find http(s) URL boundaries. URLs end at whitespace, quotes, or end-of-string.
    for url in text:gmatch("https?://[^%s\"'<>`]+") do
        -- Parse host portion: between :// and the next / ? # or end
        local host = url:match("^https?://([^/%?#]+)")
        if host then
            -- Strip port if present
            local hostname = host:match("^([^:]+)") or host
            -- Case-insensitive exact match OR subdomain match
            local lower = hostname:lower()
            if lower == CONFIG.target_host
               or lower:sub(-(#CONFIG.target_host + 1)) == "." .. CONFIG.target_host then
                return url
            end
        end
    end
    return nil
end

-- ─── CURL WRAPPER ───────────────────────────────────────────────
-- HTTP code written to separate file to avoid io.popen stdout
-- corruption on large bodies (loadstring payloads are very long).
local TMP_CODE = TMP_DIR .. "/halle_code.txt"

local function curl_get(url, out_file, headers)
    local header_str = ""
    if headers then
        for k, v in pairs(headers) do
            header_str = header_str ..
                string.format(' -H %q', k .. ": " .. v)
        end
    end
    local cmd = string.format(
        'curl -sL -m %d -o %q -w "%%{http_code}" %s %q > %q 2>/dev/null',
        CONFIG.api_timeout, out_file, header_str, url, TMP_CODE
    )
    os.execute(cmd)
    local body = read_file(out_file) or ""
    local code_str = read_file(TMP_CODE) or "0"
    return body, tonumber(code_str:match("(%d+)") or "0") or 0
end

-- ─── CLIPBOARD ──────────────────────────────────────────────────
local function get_clipboard()
    local handle = io.popen("termux-clipboard-get 2>/dev/null")
    if not handle then return nil end
    local result = handle:read("*all")
    handle:close()
    if not result then return nil end
    -- Trim trailing whitespace/newlines
    return result:gsub("%s+$", "")
end

-- ─── NOTIFICATIONS ──────────────────────────────────────────────
local function notify(title, msg, is_error)
    local priority = is_error and "high" or "default"
    local cmd = string.format(
        'termux-notification --priority %s -t %q -c %q 2>/dev/null',
        priority, title, msg
    )
    os.execute(cmd)
end

-- ─── DEDUP (don't re-bypass identical link) ─────────────────────
local function was_recent(link)
    local last = read_file(DEDUP_FILE)
    if not last then return false end
    -- last line is the previous link
    return last:gsub("%s+$", "") == link
end

local function mark_recent(link)
    write_file(DEDUP_FILE, link)
end

-- ─── ALIAS SETUP ────────────────────────────────────────────────
local function ensure_alias()
    local home = os.getenv("HOME")
    if not home then return end
    local bashrc = home .. "/.bashrc"
    local content = read_file(bashrc) or ""
    if not content:find("alias bypass=", 1, true) then
        local f = io.open(bashrc, "a")
        if f then
            f:write("\n# halle.lua bypass alias\n")
            f:write("alias bypass='lua " .. CONFIG.script_path .. "'\n")
            f:close()
            dim("Alias 'bypass' added to .bashrc (restart shell to use)")
        end
    end
end

-- ─── SELF-UPDATE ────────────────────────────────────────────────
local function check_update()
    info("Checking for updates...")
    local _, code = curl_get(CONFIG.remote_url, TMP_UPDATE, nil)

    if code ~= 200 then
        warn("Update check failed (HTTP " .. tostring(code) .. ") — continuing")
        return
    end

    local remote = read_file(TMP_UPDATE) or ""
    local current = read_file(CONFIG.script_path) or ""

    if #remote < 100 then
        warn("Remote response looks invalid (too small) — skipping update")
        return
    end

    if remote == current then
        dim("Already up to date. (v" .. VERSION .. ")")
        return
    end

    -- Try to extract version from remote for the log message
    local remote_ver = remote:match('local VERSION = "([^"]+)"') or "unknown"
    info("Update found: v" .. VERSION .. " → v" .. remote_ver .. " — replacing script...")
    if write_file(CONFIG.script_path, remote) then
        ok("Updated. Restarting...")
        os.execute("lua " .. CONFIG.script_path .. " &")
        os.exit(0)
    else
        err("Failed to write update — continuing with current version.")
    end
end

-- ─── API CALL with retry/backoff ────────────────────────────────
local function call_api(endpoint, link, label)
    local full_url = endpoint .. url_encode(link)

    for attempt = 1, CONFIG.max_retries do
        if attempt > 1 then
            local delay = CONFIG.retry_base ^ (attempt - 1)
            dim(string.format("Retry %d/%d in %ds...", attempt, CONFIG.max_retries, delay))
            os.execute("sleep " .. delay)
        end

        local body, code = curl_get(full_url, TMP_RESP,
            { ["x-api-key"] = CONFIG.api_key })

        if code == 200 and body and #body > 0 then
            local status = json_string(body, "status")
            local result = json_string(body, "result")
            if status == "success" and result and #result > 0 then
                return result
            end
            local msg = json_string(body, "message") or "unknown"
            dim(label .. " API said: " .. msg)
        elseif code == 429 then
            dim(label .. " rate-limited (HTTP 429)")
        elseif code >= 500 then
            dim(label .. " server error (HTTP " .. code .. ")")
        else
            dim(label .. " HTTP " .. tostring(code))
            return nil  -- non-retryable client error
        end
    end
    return nil
end

-- ─── LICENSE WRITE with verification ────────────────────────────
local function write_license(key)
    ensure_parent_dir(CONFIG.license_path)

    if not write_file(CONFIG.license_path, key) then
        err("Failed to write license file at " .. CONFIG.license_path)
        return false
    end

    -- VERIFY: read it back and compare
    local readback = read_file(CONFIG.license_path)
    if readback == nil then
        err("License file written but cannot be read back!")
        return false
    end
    -- Strip trailing newline for compare (some editors add one)
    if readback:gsub("%s+$", "") ~= key:gsub("%s+$", "") then
        err("License file content mismatch after write!")
        log_write("ERR", "Expected len=" .. #key .. " got len=" .. #readback)
        return false
    end

    ok("Key written and verified (" .. #key .. " chars)")
    return true
end

-- ─── BYPASS FLOW ────────────────────────────────────────────────
local function run_bypass(link)
    info("Running bypass...")
    dim("Link: " .. link:sub(1, 80) .. (#link > 80 and "..." or ""))

    local key = call_api(CONFIG.api_url, link, "bypass")

    if not key then
        warn("Bypass failed — trying refresh endpoint...")
        key = call_api(CONFIG.refresh_url, link, "refresh")
    end

    if key then
        ok("Success! Key: " .. C.bold .. key .. C.reset)
        if write_license(key) then
            notify("Bypass Success", "Key written to Delta license", false)
        else
            notify("Bypass Partial", "Got key but write FAILED — check log", true)
        end
        info("Listening for next link...")
    else
        warn("All attempts failed — retrying in 10 seconds...")
        os.execute("sleep 10")
        key = call_api(CONFIG.api_url, link, "bypass-retry")
        if not key then
            key = call_api(CONFIG.refresh_url, link, "refresh-retry")
        end
        if key then
            ok("Retry succeeded! Key: " .. C.bold .. key .. C.reset)
            if write_license(key) then
                notify("Bypass Success (retry)", "Key written to Delta license", false)
            else
                notify("Bypass Partial", "Got key but write FAILED — check log", true)
            end
            info("Listening for next link...")
        else
            err("Bypass failed after all retries — giving up on this link")
            notify("Bypass Failed", "All retries exhausted. Check log.", true)
        end
    end
end

-- ─── SIGNAL HANDLING (graceful Ctrl+C) ──────────────────────────
-- Lua doesn't have native signal handling. We trap via shell wrapper
-- if available, but also support the legacy "0 + Enter" exit.
local EXIT_FLAG = TMP_DIR .. "/halle_exit"

local function start_stdin_exit_watcher()
    os.execute("rm -f " .. EXIT_FLAG .. " 2>/dev/null")
    -- Background process that watches stdin for "0"
    os.execute(string.format([[
        ( while IFS= read -r line; do
            case "$line" in
                0|q|quit|exit) touch %q; exit 0 ;;
            esac
          done ) </dev/tty >/dev/null 2>&1 &
    ]], EXIT_FLAG))
end

local function exit_requested()
    return file_exists(EXIT_FLAG)
end

local function cleanup_and_exit(code)
    os.execute("rm -f " .. EXIT_FLAG .. " 2>/dev/null")
    print()
    info("Goodbye, Saturnity. ✦")
    os.exit(code or 0)
end

-- ─── DEPENDENCY SETUP ───────────────────────────────────────────
-- Each entry: { binary_to_check, termux_package_name, friendly_name }
-- Checks if the binary exists. If not, installs the package via pkg.
-- Skips silently if everything's already in place.
local DEPS = {
    { bin = "curl",                 pkg = "curl",        name = "curl" },
    { bin = "termux-clipboard-get", pkg = "termux-api",  name = "Termux:API" },
    { bin = "termux-notification",  pkg = "termux-api",  name = "Termux:API" },
}

local function which(binary)
    local h = io.popen("command -v " .. binary .. " 2>/dev/null")
    if not h then return nil end
    local path = h:read("*all")
    h:close()
    if path and #path > 0 then
        return path:gsub("%s+$", "")
    end
    return nil
end

local function pkg_install(package)
    -- -y auto-confirms. Output goes to terminal so user sees progress.
    local cmd = "pkg install -y " .. package
    info("Installing " .. package .. "...")
    local code = os.execute(cmd)
    return code == 0 or code == true
end

local function check_setup()
    local missing = {}
    local seen_pkg = {}  -- dedup pkg names (termux-api covers 2 bins)

    for _, dep in ipairs(DEPS) do
        if not which(dep.bin) then
            if not seen_pkg[dep.pkg] then
                seen_pkg[dep.pkg] = true
                table.insert(missing, dep)
            end
        end
    end

    if #missing == 0 then
        dim("All dependencies present.")
        return true
    end

    warn("Missing dependencies detected:")
    for _, dep in ipairs(missing) do
        dim("  • " .. dep.name .. " (pkg: " .. dep.pkg .. ")")
    end

    -- Update repo index once before installing anything
    info("Refreshing package lists...")
    os.execute("pkg update -y 2>&1 | tail -3")

    local failed = {}
    for _, dep in ipairs(missing) do
        if not pkg_install(dep.pkg) then
            table.insert(failed, dep.pkg)
        end
    end

    if #failed > 0 then
        err("Failed to install: " .. table.concat(failed, ", "))
        dim("Try manually: pkg update && pkg install " .. table.concat(failed, " "))
        return false
    end

    -- Verify everything is now actually available
    for _, dep in ipairs(DEPS) do
        if not which(dep.bin) then
            err("Still missing after install: " .. dep.bin)
            if dep.pkg == "termux-api" then
                dim("The 'termux-api' package is installed, but you also")
                dim("need the Termux:API Android app from F-Droid:")
                dim("  https://f-droid.org/packages/com.termux.api/")
            end
            return false
        end
    end

    -- Check storage access (needed to write license to /storage/emulated/0)
    local storage_test = io.open("/storage/emulated/0/", "r")
    if not storage_test then
        warn("Storage access not granted.")
        dim("Run: termux-setup-storage")
        dim("Then approve the permission popup and re-run halle.")
        return false
    end
    storage_test:close()

    ok("Setup complete!")
    return true
end

-- ─── MAIN ───────────────────────────────────────────────────────
local function banner()
    print(C.purple .. "╔══════════════════════════════════════════╗")
    print("║       halle.lua — bypass listener        ║")
    print("║         saturnity / lucivaantarez        ║")
    print(string.format("║              version %-20s║", VERSION))
    print("╚══════════════════════════════════════════╝" .. C.reset)
    dim("Press 0 + Enter (or Ctrl+C) to exit")
    dim("Log: " .. LOG_FILE)
    print()
end

local function main()
    banner()
    log_write("INFO", "===== halle.lua starting =====")

    info("Checking dependencies...")
    if not check_setup() then
        err("Setup incomplete. Fix the issues above and restart.")
        os.exit(1)
    end

    ensure_alias()
    check_update()
    start_stdin_exit_watcher()

    info("Listening for " .. CONFIG.target_host .. " links on clipboard...")

    local last_seen = ""

    while true do
        if exit_requested() then
            cleanup_and_exit(0)
        end

        local clip = get_clipboard()

        if clip and clip ~= last_seen then
            last_seen = clip
            local url = extract_target_url(clip)
            if url then
                -- Re-bypass even if duplicate when license is missing/empty/short
                local cur_key = read_file(CONFIG.license_path) or ""
                local key_ok = #(cur_key:gsub("%s+", "")) > 10

                if was_recent(url) and key_ok then
                    dim("Skipping duplicate link (key already valid in license).")
                else
                    if was_recent(url) and not key_ok then
                        warn("License missing or invalid — re-bypassing duplicate link.")
                    end
                    mark_recent(url)
                    print()
                    info("Platorelay link detected!")
                    run_bypass(url)
                    print()
                end
            end
        end

        os.execute("sleep " .. CONFIG.poll_interval)
    end
end

-- Wrap main in pcall so unexpected errors get logged, not silently crashed
local ok_run, error_msg = pcall(main)
if not ok_run then
    err("Fatal error: " .. tostring(error_msg))
    log_write("FATAL", tostring(error_msg))
    cleanup_and_exit(1)
end
