-- Minimal strict JSON decoder, TEST HARNESS ONLY (the device uses lua-cjson,
-- which is not packaged for the build machine). Decodes objects, arrays,
-- strings (incl. \uXXXX), numbers, true/false; null decodes to nil, which is
-- stricter than cjson's lightuserdata sentinel and fine for these tests.
local M = {}

local function err(s, i, msg)
    error(("json: %s at byte %d (near %q)"):format(msg, i, s:sub(i, i + 20)), 0)
end

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local decode_value

local function decode_string(s, i)
    -- i points at opening quote
    local buf, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then err(s, j, "unterminated string") end
        if c == '"' then
            return table.concat(buf), j + 1
        elseif c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "u" then
                local hex = s:sub(j + 2, j + 5)
                if not hex:match("^%x%x%x%x$") then err(s, j, "bad \\u escape") end
                local cp = tonumber(hex, 16)
                -- surrogate pairs
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j + 6, j + 7) == "\\u" then
                    local lo = tonumber(s:sub(j + 8, j + 11), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        j = j + 6
                    end
                end
                buf[#buf + 1] = utf8.char(cp)
                j = j + 6
            else
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                              b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                local m = map[e]
                if not m then err(s, j, "bad escape") end
                buf[#buf + 1] = m
                j = j + 2
            end
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
end

local function decode_number(s, i)
    local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    local v = tonumber(num)
    if not v then err(s, i, "bad number") end
    return v, i + #num
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then err(s, i, "expected object key") end
            local k; k, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then err(s, i, "expected ':'") end
            local v; v, i = decode_value(s, i + 1)
            obj[k] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "}" then return obj, i + 1
            else err(s, i, "expected ',' or '}'") end
        end
    elseif c == "[" then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v; v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "]" then return arr, i + 1
            else err(s, i, "expected ',' or ']'") end
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        return decode_number(s, i)
    end
end

function M.decode(s)
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then err(s, i, "trailing garbage") end
    return v
end

return M
