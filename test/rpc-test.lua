-- Exercises the real rpc/mullvad handler against a captured `tailscale status
-- --json` payload, with the openresty/GL runtime stubbed out.
--
--   lua test/rpc-test.lua <status.json> [expected-grouping.txt]
--
-- Prints "CC|country|city|n|best_ip|online" lines for a diff against the
-- Python-computed expectation, then runs set_exit_node scenario asserts.

local HERE = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = HERE .. "/?.lua;" .. package.path
local json = require "json"

local status_path = assert(arg[1], "usage: rpc-test.lua <status.json> [expected.txt]")
local status_json
do
    local f = assert(io.open(status_path, "rb"))
    status_json = f:read("*a")
    f:close()
end

-- ---- stubs -----------------------------------------------------------------
local spawned = {}          -- every command line the handler spawns
local uci_store = {         -- tailscale.settings.*
    ["tailscale.settings.enabled"] = "1",
}
local stub_status_body = status_json

local function stub_spawn(cmd)
    spawned[#spawned + 1] = table.concat(cmd, " ")
    local is_status = false
    for _, w in ipairs(cmd) do
        if w == "status" then is_status = true end
    end
    return {
        stdout_read_all = function() return is_status and stub_status_body or "" end,
        stderr_read_all = function() return "" end,
        wait = function() return true, "exit", 0 end,
    }
end

package.preload["cjson"] = function()
    return { decode = json.decode }
end
package.preload["uci"] = function()
    return { cursor = function()
        return {
            get = function(_, a, b, c) return uci_store[a .. "." .. b .. "." .. c] end,
            set = function(_, a, b, c, v) uci_store[a .. "." .. b .. "." .. c] = tostring(v) end,
            commit = function() end,
        }
    end }
end
package.preload["oui.fs"] = function() return { sync = function() end } end
package.preload["oui.rpc"] = function() return { ERROR_CODE_INVALID_PARAMS = -32602 } end
ngx = { pipe = { spawn = stub_spawn } }

local M = assert(loadfile(HERE .. "/../gl-sdk4-tailscale-mullvad/data/usr/lib/oui-httpd/rpc/mullvad"))()

-- ---- helpers ---------------------------------------------------------------
local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- ---- get_nodes: dump grouping for differential comparison -------------------
local r = M.get_nodes({})
check(r.supported == true, "get_nodes: supported")
check(r.active == false, "get_nodes: no exit node active in capture")

local lines = {}
for _, country in ipairs(r.countries or {}) do
    for _, city in ipairs(country.cities) do
        lines[#lines + 1] = table.concat(
            { country.code, country.name, city.name, tostring(city.n),
              city.ip, tostring(city.online) }, "|")
    end
end
table.sort(lines)

if arg[2] then
    local exp = {}
    for l in io.lines(arg[2]) do exp[#exp + 1] = l end
    table.sort(exp)
    check(#lines == #exp, ("grouping: line count %d == expected %d"):format(#lines, #exp))
    local mism = 0
    for i = 1, math.min(#lines, #exp) do
        if lines[i] ~= exp[i] then
            mism = mism + 1
            if mism <= 5 then print("  mismatch:\n   lua: " .. lines[i] .. "\n   py:  " .. exp[i]) end
        end
    end
    check(mism == 0, "grouping: all city rows identical to python computation")
else
    for _, l in ipairs(lines) do print(l) end
end

-- ---- set_exit_node scenarios -------------------------------------------------
-- (a) invalid ip -> INVALID_PARAMS
local code, msg = M.set_exit_node({ ip = "100.64.0.1" })
check(code == -32602 and tostring(msg):find("not a Mullvad"), "set: unknown ip rejected: " .. tostring(msg))

-- (b) non-string -> INVALID_PARAMS
code = M.set_exit_node({ ip = 42 })
check(code == -32602, "set: non-string ip rejected")

-- (c) clear while inactive -> live no-op, no process spawned beyond status
spawned = {}
local res = M.set_exit_node({ ip = "" })
check(res.live == true, "set: clear-inactive is a live no-op")
check(#spawned == 1 and spawned[1]:find("status"), "set: clear-inactive spawns only a status query")
check(uci_store["tailscale.settings.exit_node_ip"] == "", "set: clear-inactive persists empty uci ip")

-- pick a real mullvad ip from the grouping dump for the remaining cases
local mull_ip = lines[1]:match("|(100%.[%d%.]+)|")
check(mull_ip ~= nil, "harness: extracted a mullvad ip from grouping (" .. tostring(mull_ip) .. ")")

-- (d) first enable (inactive) -> uci + gl_tailscale restart, live=false
spawned = {}
res = M.set_exit_node({ ip = mull_ip })
check(res.live == false, "set: first enable returns live=false")
check(spawned[#spawned] == "/usr/bin/gl_tailscale restart", "set: first enable spawns gl_tailscale restart")
check(uci_store["tailscale.settings.exit_node_ip"] == mull_ip, "set: uci exit_node_ip persisted")
check(uci_store["tailscale.settings.advertise_exit_node"] == "0", "set: advertise_exit_node forced off")

-- (e) switch while active -> live tailscale set, no restart
-- inject an ExitNodeStatus into the capture to simulate an active exit node
stub_status_body = status_json:gsub('"Version":', '"ExitNodeStatus":{"ID":"x","Online":true,"TailscaleIPs":["' .. mull_ip .. '/32"]},"Version":', 1)
spawned = {}
res = M.set_exit_node({ ip = mull_ip })
check(res.live == true, "set: switch-while-active returns live=true")
check(spawned[#spawned] == "/usr/sbin/tailscale set --exit-node=" .. mull_ip .. " --exit-node-allow-lan-access",
      "set: switch uses tailscale set with allow-lan-access")

-- (f) clear while active -> live tailscale set without the lan-access flag
spawned = {}
res = M.set_exit_node({ ip = "" })
check(res.live == true, "set: clear-while-active returns live=true")
check(spawned[#spawned] == "/usr/sbin/tailscale set --exit-node=", "set: clear uses bare --exit-node=")

-- (g) get_nodes with active exit node reports current + its country/city
r = M.get_nodes({})
check(r.active == true and r.current == mull_ip and r.current_cc ~= nil,
      ("get_nodes: current exit node resolved (%s %s/%s)"):format(
          tostring(r.current), tostring(r.current_cc), tostring(r.current_city)))

-- (h) tailscale disabled in uci -> unsupported
uci_store["tailscale.settings.enabled"] = "0"
r = M.get_nodes({})
check(r.supported == false, "get_nodes: unsupported when tailscale disabled")

if failures > 0 then
    print(failures .. " FAILURES")
    os.exit(1)
end
print("all rpc tests passed")
