#!/usr/bin/lua
-- Splices the Mullvad picker into the compiled GL Tailscale view bundle
-- (/www/views/gl-sdk4-ui-tailscaleview.common.js.gz), or restores the original.
--
-- The bundle is owned by gl-sdk4-ui-tailscaleview, not by this package, so it is
-- patched in place with a backup instead of being shipped: opkg refuses packages
-- whose files clash. If gl-sdk4-ui-tailscaleview is upgraded, its new bundle
-- overwrites the patch; re-run `patch-view.lua apply` (or reinstall this package).
--
-- Anchors are verified to match EXACTLY ONCE before any write; on mismatch the
-- bundle is left untouched and the script exits non-zero. Snippets are syntax-
-- checked with node at package build time (see build.py), not on the device.

-- TSMV_ROOT is only set by the build-machine test harness (test/run-tests.sh);
-- on the device it is unset and paths are the real ones
local ROOT   = os.getenv("TSMV_ROOT") or ""
local VIEW   = ROOT .. "/www/views/gl-sdk4-ui-tailscaleview.common.js.gz"
local BACKUP = VIEW .. ".tsmullvad-orig"
local SHARE  = ROOT .. "/usr/share/tailscale-mullvad"
local MARK   = "/*tsmullvad:v3*/"

-- plain-string anchors in the minified bundle (verified in the feed's view
-- git-2025.244.27716-e9a0fdd AND the stock XE3000 4.8 bundle)
-- v2: the picker <li> goes BEFORE the `config.manual ? [exit-node...] : [wan/lan...]`
-- ternary, i.e. right under the "Custom Exit Node" row and always rendered; the
-- v1 anchor placed it inside the manual-on branch, hiding it behind that toggle.
local A_RENDER = ',t.config.manual?[e("li"'
local A_BLOCK  = "p=d.exports;e.default=p"   -- wrap component options before export

local function die(msg)
    io.stderr:write("tsmullvad patch-view: " .. msg .. "\n")
    os.exit(1)
end

local function run(cmd)
    -- os.execute returns a number on Lua 5.1 (the device) and a boolean on 5.3+
    local rc = os.execute(cmd)
    if not (rc == 0 or rc == true) then
        die("command failed (" .. tostring(rc) .. "): " .. cmd)
    end
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then
        die("cannot write " .. path)
    end
    f:write(data)
    f:close()
end

local function count_plain(s, needle)
    local n, from = 0, 1
    while true do
        local i = string.find(s, needle, from, true)
        if not i then
            return n
        end
        n = n + 1
        from = i + 1
    end
end

local function gunzip(path)
    local tmp = "/tmp/tsmullvad-view.js"
    run("gunzip -c '" .. path .. "' > " .. tmp)
    local data = read_file(tmp)
    os.remove(tmp)
    if not data or #data == 0 then
        die("empty result gunzipping " .. path)
    end
    return data
end

local function gzip_to(data, dest)
    local tmp = "/tmp/tsmullvad-view.out.js"
    write_file(tmp, data)
    run("gzip -c " .. tmp .. " > " .. dest .. ".tsmullvad-new")
    os.remove(tmp)
    run("mv " .. dest .. ".tsmullvad-new '" .. dest .. "'")
end

local function apply()
    if not read_file(VIEW) then
        die(VIEW .. " not found - install the GL Tailscale panel (gl-sdk4-ui-tailscaleview) first")
    end

    local src = gunzip(VIEW)
    local was_patched = src:find("/*tsmullvad:", 1, true) ~= nil

    if src:find(MARK, 1, true) then
        print("tsmullvad patch-view: already applied (" .. MARK .. ")")
        os.exit(0)
    end
    if was_patched then
        -- older patch version present: rebuild from the pristine backup
        local orig = read_file(BACKUP)
        if not orig then
            die("bundle carries an old tsmullvad patch but backup " .. BACKUP .. " is missing")
        end
        src = gunzip(BACKUP)
    end

    local render = read_file(SHARE .. "/render.js")
    local block  = read_file(SHARE .. "/block.js")
    if not render or not block then
        die("snippets missing under " .. SHARE)
    end
    -- snippets are one-line expressions; strip the trailing newline
    render = render:gsub("%s+$", "")
    block  = block:gsub("%s+$", "")

    if count_plain(src, A_RENDER) ~= 1 then
        die("render anchor not found exactly once - unsupported view bundle version, not patching")
    end
    if count_plain(src, A_BLOCK) ~= 1 then
        die("block anchor not found exactly once - unsupported view bundle version, not patching")
    end

    local i = string.find(src, A_RENDER, 1, true)
    src = src:sub(1, i - 1) .. "," .. render .. src:sub(i)

    local j = string.find(src, A_BLOCK, 1, true)
    src = src:sub(1, j - 1) .. "p=d.exports;(" .. block .. ")(p);e.default=p"
          .. src:sub(j + #A_BLOCK)

    src = MARK .. src

    if not was_patched then
        -- an unmarked bundle IS the pristine one for this firmware: always
        -- refresh the backup, or a firmware upgrade would leave a stale backup
        -- from the previous firmware shadowing the new pristine bundle
        run("cp '" .. VIEW .. "' '" .. BACKUP .. "'")
    end
    gzip_to(src, VIEW)
    print("tsmullvad patch-view: applied " .. MARK .. " to " .. VIEW)
end

local function remove()
    local view = read_file(VIEW)
    if not view then
        print("tsmullvad patch-view: " .. VIEW .. " not present, nothing to restore")
        return
    end
    local src = gunzip(VIEW)
    if not src:find("/*tsmullvad:", 1, true) then
        print("tsmullvad patch-view: bundle is not patched, nothing to restore")
        os.remove(BACKUP)
        return
    end
    if not read_file(BACKUP) then
        die("bundle is patched but backup " .. BACKUP .. " is missing - reinstall gl-sdk4-ui-tailscaleview to restore")
    end
    run("mv '" .. BACKUP .. "' '" .. VIEW .. "'")
    print("tsmullvad patch-view: original bundle restored")
end

local mode = arg and arg[1]
if mode == "apply" then
    apply()
elseif mode == "remove" then
    remove()
else
    die("usage: patch-view.lua apply|remove")
end
