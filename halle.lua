-- ================================================================
--  halle.lua — Platorelay Bypass Listener
--  Repo: https://github.com/lucivaantarez/bp
--
--  SETUP (run once in Termux):
--    pkg install termux-api lua54 lua54-luasocket lua54-dkjson curl
--    curl -L https://github.com/lucivaantarez/bp/raw/main/halle.lua \
--         -o /storage/emulated/0/Download/halle.lua
--
--  RUN:
--    lua /storage/emulated/0/Download/halle.lua
--
--  EXIT:
--    Type 0 and press Enter in the terminal
-- ================================================================

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("dkjson")

-- ─── CONSTANTS ──────────────────────────────────────────────────
local API_KEY      = "b71c5cd5-874c-49da-874a-15f31fb829ca"
local API_URL      = "https://api.izen.lol/v1/bypass?url="
local REFRESH_URL  = "https://api.izen.lol/v1/refresh?url="
local TARGET_DOMAIN = "auth.platorelay.com"

local SCRIPT_PATH  = "/storage/emulated/0/Download/halle.lua"
local REMOTE_URL   = "https://raw.githubusercontent.com/lucivaantarez/bp/refs/heads/main/halle.lua"
local EXIT_FLAG    = "/data/data/com.termux/files/usr/tmp/halle_exit"

local LICENSE_DIRS = {
    "com.roblox.clienr",
    "com.roblox.cliens",
    "com.roblox.client",
    "com.roblox.clienv",
    "com.roblox.clienw",
    "com.roblox.clienx",
    "com.roblox.clieny",
    "com.roblox.clienz",
}

local LICENSE_PATH = "/storage/emulated/0/Android/data/%s/files/gloop/external/internals/Cache/license"

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

-- ─── UPDATE ─────────────────────────────────────────────────────
local function check_update()
    print("[*] Checking for updates...")
    local body = {}
    local _, code = http.request{
        url  = REMOTE_URL,
        sink = ltn12.sink.table(body)
    }

    if code ~= 200 then
        print("[-] Update check failed (HTTP " .. tostring(code) .. "), continuing...")
        return
    end

    local remote = table.concat(body)
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

-- ─── POPUP ──────────────────────────────────────────────────────
local function confirm_popup(url)
    local preview = url:sub(1, 40) .. "..."
    local handle = io.popen(
        'termux-dialog confirm -t "Bypass Detected" -i "Run bypass for:\\n' .. preview .. '?" 2>/dev/null'
    )
    if not handle then return false end
    local raw = handle:read("*all")
    handle:close()
    local data = json.decode(raw)
    return data and data.text == "yes"
end

-- ─── API ────────────────────────────────────────────────────────
local function call_api(endpoint, link)
    local body = {}
    local _, code = http.request{
        url     = endpoint .. url_encode(link),
        headers = { ["x-api-key"] = API_KEY },
        sink    = ltn12.sink.table(body)
    }

    if code == 200 then
        local data = json.decode(table.concat(body))
        if data and data.status == "success" and data.result then
            return data.result
        end
        print("[-] API error: " .. (data and data.message or "Unknown error"))
    else
        print("[-] HTTP error: " .. tostring(code))
    end
    return nil
end

-- ─── WRITE LICENSE ───────────────────────────────────────────────
local function write_license(key)
    local ok_count = 0
    for _, dir in ipairs(LICENSE_DIRS) do
        local path = string.format(LICENSE_PATH, dir)
        local parent = path:match("(.+)/[^/]+$")
        os.execute('su -c "mkdir -p \'' .. parent .. '\'"')
        local wrote = os.execute(
            string.format('su -c "echo -n \'%s\' > \'%s\'"', key, path)
        )
        if wrote then
            print("[+] Written to " .. dir)
            ok_count = ok_count + 1
        else
            print("[-] Failed:    " .. dir)
        end
    end
    print("[*] Done: " .. ok_count .. "/" .. #LICENSE_DIRS .. " folders updated.")
end

-- ─── BYPASS FLOW ────────────────────────────────────────────────
local function run_bypass(link)
    print("[*] Running bypass...")
    local key = call_api(API_URL, link)

    if key then
        print("[+] Success! Key: " .. key)
        write_license(key)
        notify("Bypass Success", "Key written to all folders!")
        print("[*] Listening for next link...")
        return
    end

    print("[*] Bypass failed, trying refresh...")
    key = call_api(REFRESH_URL, link)

    if key then
        print("[+] Refresh success! Key: " .. key)
        write_license(key)
        notify("Refresh Success", "Key written to all folders!")
        print("[*] Listening for next link...")
    else
        print("[-] Both bypass and refresh failed.")
        notify("Bypass Failed", "Both bypass and refresh failed.")
    end
end

-- ─── MAIN ───────────────────────────────────────────────────────
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
            print("[*] Platorelay link detected! Showing popup...")
            if confirm_popup(clip) then
                run_bypass(clip)
            else
                print("[*] Cancelled. Still listening...")
            end
        end
    end

    os.execute("sleep 2")
end
