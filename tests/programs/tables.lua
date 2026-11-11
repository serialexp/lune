-- Tables (doc 86 P1 corpus): sort with a comparator, insert/remove, concat,
-- unpack, pairs over a mixed table and a table that grows and shrinks.
local people = {
    { name = "ana", age = 31 },
    { name = "bo", age = 25 },
    { name = "cy", age = 31 },
    { name = "di", age = 19 },
}
table.sort(people, function(a, b)
    if a.age ~= b.age then
        return a.age > b.age
    end
    return a.name < b.name
end)
local names = {}
for _, p in ipairs(people) do
    names[#names + 1] = p.name
end
print("sort", table.concat(names, " "))

local list = {}
for i = 1, 10 do
    table.insert(list, i)
end
table.insert(list, 1, 0)
table.remove(list, 5)
table.remove(list)
print("list", table.concat(list, ","), #list)
print("unpack", table.unpack(list, 2, 4))

local mixed = {
    10,
    20,
    30,
    x = 1,
    y = 2,
}
mixed.z = 3
mixed.x = nil
local keys = {}
for k, v in pairs(mixed) do
    keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
end
print("pairs", table.concat(keys, " "))

local grow = {}
for i = 1, 200 do
    grow["k" .. i] = i
end
for i = 1, 200, 2 do
    grow["k" .. i] = nil
end
local total = 0
for _, v in pairs(grow) do
    total = total + v
end
print("grow", total)
