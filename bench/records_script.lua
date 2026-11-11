-- Script-style code: an inventory report written the way scripts usually
-- are. The stdlib is reached by its qualified name at every call
-- (`math.floor`, `string.sub`), records carry strings that are read,
-- measured and sliced, per-kind rules (a rate, a label, a function) are
-- found by a string key, a pipeline of functions sits in an array, and a
-- settings list mixes numbers, strings, booleans and tables behind
-- `type()`. The catalogue is written by hand, so a weight is an integer in
-- one record and a fraction in the next. The collections are small and
-- walked many times. Integer checksum, byte-identical to LuaJIT (the
-- fractions are dyadic and everything stays below 2^53).
--
--   mahina              bench/records_script.lua 20000   # tier-0
--   mahina --jit-native bench/records_script.lua 20000   # tier-1b
--   luajit              bench/records_script.lua 20000   # reference
--
-- @bench args="20000" luajit=compatible

local ROUNDS = tonumber(arg and arg[1]) or 20000

local seed = 42

local function rand(n)
    seed = (seed * 16807) % 2147483647
    return seed % n
end

local catalogue = {
    { name = "sword", kind = "weapon", weight = 3, price = 120 },
    { name = "longbow", kind = "weapon", weight = 1.5, price = 95 },
    { name = "shield", kind = "armor", weight = 4.5, price = 80 },
    { name = "helm", kind = "armor", weight = 2, price = 60 },
    { name = "elixir", kind = "potion", weight = 0.5, price = 30 },
    { name = "tonic", kind = "potion", weight = 0.25, price = 12 },
    { name = "map", kind = "scroll", weight = 0.125, price = 45 },
    { name = "rune", kind = "scroll", weight = 1, price = 200 },
}

local rules = {
    weapon = {
        rate = 0.25,
        label = "W",
        bonus = function(item)
            return item.qty * 3
        end,
    },
    armor = {
        rate = 0.125,
        label = "A",
        bonus = function(item)
            return item.qty + 10
        end,
    },
    potion = {
        rate = 0.0625,
        label = "P",
        bonus = function(item)
            return #item.name
        end,
    },
    scroll = {
        rate = 0.5,
        label = "S",
        bonus = function(item)
            return item.price % 7
        end,
    },
}

local settings = {
    3,
    "verbose",
    true,
    0.75,
    { 1, 2, 3 },
    "fast",
    false,
    12,
}

local steps = {
    function(v)
        return v + 3
    end,
    function(v)
        return v * 2
    end,
    function(v)
        return v % 1009
    end,
}

local inventory = {}
for i = 1, 64 do
    local c = catalogue[rand(#catalogue) + 1]
    inventory[i] = {
        name = c.name,
        kind = c.kind,
        weight = c.weight,
        price = c.price,
        qty = 1 + rand(9),
        magic = rand(4) == 0,
    }
end

-- Weight carried, in eighths.
local function carried(inv)
    local w = 0
    for i = 1, #inv do
        local item = inv[i]
        w = w + item.weight * item.qty
    end
    return math.floor(w * 8)
end

-- Tax owed, plus each kind's bonus.
local function owed(inv)
    local sum = 0
    for i = 1, #inv do
        local item = inv[i]
        local rule = rules[item.kind]
        sum = sum + math.floor(item.price * item.qty * rule.rate) + rule.bonus(item)
    end
    return sum
end

-- Width of the report's tag column: a kind letter and a short name.
local function tags(inv)
    local n = 0
    for i = 1, #inv do
        local item = inv[i]
        local short = string.upper(string.sub(item.name, 1, 3))
        n = n + #item.name + #short + #rules[item.kind].label
    end
    return n
end

-- How many of one kind, with a point for anything magic among the rest.
local function count(inv, kind)
    local n = 0
    for i = 1, #inv do
        local item = inv[i]
        if item.kind == kind then
            n = n + item.qty
        elseif item.magic then
            n = n + 1
        end
    end
    return n
end

local function weigh(v)
    local t = type(v)
    if t == "number" then
        return math.floor(v * 4)
    elseif t == "string" then
        return #v
    elseif t == "boolean" then
        return v and 1 or 0
    elseif t == "table" then
        return #v
    end
    return 0
end

local function configured(list)
    local n = 0
    for i = 1, #list do
        n = n + weigh(list[i])
    end
    return n
end

local function refine(v)
    for s = 1, #steps do
        v = steps[s](v)
    end
    return v
end

local check = 0
for round = 1, ROUNDS do
    local sum = carried(inventory) + owed(inventory) + tags(inventory)
    sum = sum + count(inventory, "potion") + configured(settings)
    check = (check * 31 + sum + refine(sum)) % 1000000007
    -- Restock one item, so the data is not frozen.
    local item = inventory[round % #inventory + 1]
    item.qty = item.qty % 9 + 1
end
print(check)
