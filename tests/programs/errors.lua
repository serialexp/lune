-- Errors (doc 86 P1 corpus): error values of every kind, levels, xpcall
-- handlers, nested protection and rethrow.
local function fails(kind)
    if kind == 1 then
        error("plain")
    elseif kind == 2 then
        error({ code = 42 })
    elseif kind == 3 then
        error("leveled", 2)
    elseif kind == 4 then
        local t = nil
        return t.field
    end
    return "fine"
end

for kind = 0, 4 do
    local ok, e = pcall(fails, kind)
    if type(e) == "table" then
        e = "code=" .. e.code
    end
    print("pcall", kind, ok, e)
end

print(
    "xpcall",
    xpcall(
        fails,
        function(e)
            return "handled: " .. tostring(e)
        end,
        1
    )
)

local ok, e = pcall(function()
    local ok2, e2 = pcall(error, "inner")
    error("outer after " .. tostring(e2))
end)
print("nested", ok, e)

local depth = 0

local function deep(n)
    depth = depth + 1
    if n == 0 then
        error("bottom")
    end
    return deep(n - 1)
end

print("deep", pcall(deep, 20))
print("depth", depth)
