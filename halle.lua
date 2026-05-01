-- ================================================================
--  halle.lua — Platorelay Bypass Listener
--  Repo: https://github.com/lucivaantarez/bp
--
--  SETUP (run once in Termux):
--    pkg install termux-api lua54 curl -y
--    termux-setup-storage
--    curl -L https://raw.githubusercontent.com/lucivaantarez/bp/refs/heads/main/halle.lua -o /storage/emulated/0/Download/halle.lua
--    lua /storage/emulated/0/Download/halle.lua
--
--  FROM NOW ON:
--    bypass
--
--  EXIT:
--    Type 0 and press Enter
-- ================================================================

-- ─── CONSTANTS ──────────────────────────────────────────────────
local API_KEY       = "b71c5cd5-874c-49da-874a-15f31fb829ca"
local API_URL       = "https://api.izen.lol/v1/bypass?url="
local REFRESH_URL   = "https://api.izen.lol/v1/refresh?url="
local TARGET_DOMAIN = "auth.platorelay.com"

local SCRIPT_PATH   = "/storage/emulated/0/Download/halle.lua"
local REMOTE_URL    = "https://raw.githubusercontent.com/lucivaantarez/bp/refs/heads/main/halle.lua"
local EXIT_FLAG     = "/data/data/com.termux/files/usr/tmp/halle_exit"
local TMP_RESPONSE  = "/data/data/com.termux/files/usr/tmp/halle_resp.json"
local TMP_UPDATE    = "/data/data/com.termux/files/usr/tmp/halle_update.lua"

local LICENSE_FILE  = "/storage/emulated/0/Delta/Internals/Cache/license"

-- ─── HELPERS ────────────────────────────────────────────────────
local function url_encode(url)
    return url:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function notify(title, msg)
    os.execute('termux-notification -t "' .. title .. '" -c "' .. msg .. '" 2>/dev/null')
end

-- ─── JSON PARSE (no deps) ───────────────────────────────────────
local function json_field(str, field)
    return str:match('"' .. field .. '":%s*"([^"]*)"')
end

-- ─── CURL GET ───────────────────────────────────────────────────
local function curl_get(url, out_file, headers)
    local header_str = ""
    if headers then
        for k, v in pairs(headers) do
            header_str = header_str .. string.format(' -H "%s: %s"', k, v)
        end
    end
    local cmd = string.format(
        'curl -s -o "%s" -w "%%{http_code}"%s "%s"',
        out_file, header_str, url
    )
    local handle = io.popen(cmd)
    if not handle then return nil, 0 end
    local code_str = handle:read("*all")
    handle:close()
    local body = read_file(out_file) or ""
    return body, tonumber(code_str) or 0
end

-- ─── ALIAS SETUP ────────────────────────────────────────────────
local function ensure_alias()
    local bashrc = os.getenv("HOME") .. "/.bashrc"
    local content = read_file(bashrc) or ""
    if not content:find("alias bypass=", 1, true) then
        local f = io.open(bashrc, "a")
        if f then
            f:write("\nalias bypass='lua /storage/emulated/0/Download/halle.lua'\n")
            f:close()
        end
    end
end

-- ─── UPDATE ─────────────────────────────────────────────────────
local function check_update()
    print("[*] Checking for updates...")
    local _, code = curl_get(REMOTE_URL, TMP_UPDATE, nil)

    if code ~= 200 then
        print("[-] Update check failed (HTTP " .. tostring(code) .. "), continuing...")
        return
    end

    local remote = read_file(TMP_UPDATE) or ""
    local local_content = read_file(SCRIPT_PATH) or ""

    if remote == local_content then
        print("[*] Already up to date.")
        return
    end

    print("[*] Update found! Replacing script...")
    if write_file(SCRIPT_PATH, remote) then
        print("[+] Updated! Restarting...")
        os.execute("lua " .. SCRIPT_PATH .. " &")
        os.exit(0)
    else
        print("[-] Failed to write update, continuing with current version.")
    end
end

-- ─── EXIT LISTENER ──────────────────────────────────────────────
local function start_exit_listener()
    os.execute("rm -f " .. EXIT_FLAG)
    os.execute([[sh -c 'while true; do
        read -r line
        if [ "$line" = "0" ]; then
            touch ]] .. EXIT_FLAG .. [[
            break
        fi
    done' &]])
end

local function exit_requested()
    local f = io.open(EXIT_FLAG, "r")
    if f then f:close(); return true end
    return false
end

-- ─── CLIPBOARD ──────────────────────────────────────────────────
local function get_clipboard()
    local handle = io.popen("termux-clipboard-get 2>/dev/null")
    if not handle then return nil end
    local result = handle:read("*all")
    handle:close()
    return result and result:gsub("%s+$", "") or nil
end

-- ─── API CALL ───────────────────────────────────────────────────
local function call_api(endpoint, link)
    local full_url = endpoint .. url_encode(link)
    local body, code = curl_get(full_url, TMP_RESPONSE, { ["x-api-key"] = API_KEY })

    if code == 200 and body then
        local status = json_field(body, "status")
        local result = json_field(body, "result")
        if status == "success" and result then
            return result
        end
        local msg = json_field(body, "message")
        print("[-] API error: " .. (msg or "Unknown error"))
    else
        print("[-] HTTP error: " .. tostring(code))
    end
    return nil
end

-- ─── WRITE LICENSE ───────────────────────────────────────────────
local function write_license(key)
    local wrote = write_file(LICENSE_FILE, key)
    if wrote then
        print("[+] Key written to license file.")
    else
        print("[-] Failed to write license file.")
    end
end

-- ─── BYPASS FLOW ────────────────────────────────────────────────
local function run_bypass(link)
    print("[*] Running bypass...")
    local key = call_api(API_URL, link)

    if not key then
        print("[*] Bypass failed, trying refresh...")
        key = call_api(REFRESH_URL, link)
    end

    if key then
        print("[+] Success! Key: " .. key)
        write_license(key)
        notify("Bypass Success", "Key written to license!")
        print("[*] Listening for next link...")
    else
        print("[-] Both bypass and refresh failed.")
        notify("Bypass Failed", "Both bypass and refresh failed.")
    end
end

-- ─── MAIN ───────────────────────────────────────────────────────
ensure_alias()
check_update()
start_exit_listener()

print("==========================================")
print("  halle.lua — Bypass Listener")
print("  Press [0] + Enter to exit anytime")
print("==========================================")
print("[*] Listening for platorelay links...")

local last_clipboard = ""

while true do
    if exit_requested() then
        print("[!] Exit requested. Goodbye!")
        os.execute("rm -f " .. EXIT_FLAG)
        os.exit(0)
    end

    local clip = get_clipboard()

    if clip and clip ~= last_clipboard then
        last_clipboard = clip
        if clip:find(TARGET_DOMAIN, 1, true) then
            print("[*] Platorelay link detected! Running bypass...")
            run_bypass(clip)
        end
    end

    os.execute("sleep 2")
end
