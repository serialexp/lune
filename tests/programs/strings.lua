-- Strings (doc 86 P1 corpus): gsub with function and table replacements,
-- gmatch, find with captures, format, rep and codepoint/char.
local text = "the quick brown fox jumps over the lazy dog"

local caps = text:gsub("%w+", function(w)
    return w:sub(1, 1):upper() .. w:sub(2)
end)
print("gsub fn", caps)

local swap = { quick = "slow", lazy = "eager" }
print("gsub tbl", (text:gsub("%w+", swap)))

local words = {}
for w in text:gmatch("%a+") do
    words[#words + 1] = #w
end
print("gmatch", table.concat(words, " "))

print("find", text:find("(b%a+) (f%a+)"))
print("format", string.format("%5d|%-5s|%.3f|%x|%q", 42, "ab", math.pi, 255, 'q"t'))
print("rep", ("ab"):rep(3, "-"))
print("codepoints", string.codepoint("mahina", 1, -1))
print("reverse", ("mahina"):reverse(), ("MiXeD"):lower())
print("char", string.char(104, 105))

local parts = {}
for k, v in ("a=1, b=22, c=333"):gmatch("(%a)=(%d+)") do
    parts[#parts + 1] = k .. v
end
print("pairs", table.concat(parts, ";"))
