-- Garbage (doc 86 P1 corpus): enough short-lived tables, strings and
-- closures for several collections, so a resume has to collect exactly when
-- the uninterrupted run did.
local keep = {}
local total = 0
for i = 1, 3000 do
    local t = { i, i * 2, name = "item" .. i }
    local f = function()
        return t[1] + t[2]
    end
    total = total + f() + #t.name
    if i % 500 == 0 then
        keep[#keep + 1] = t
    end
end
print("total", total, #keep)

local parts = {}
for i = 1, 400 do
    parts[i] = string.rep("x", i % 7) .. i
end
print("joined", #table.concat(parts))
print("kept", keep[1].name, keep[#keep].name)
