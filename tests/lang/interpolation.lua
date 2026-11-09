-- String interpolation (doc 82): backtick templates. Every template form the
-- compiler accepts, so the Tree-sitter drift check
-- (editors/tree-sitter-mahina/test/drift.test.ts) keeps the editor grammar in
-- step with src/parser.zig. The program prints what each form evaluates to.
local name, n = "world", 3
local t = setmetatable({}, {
    __tostring = function()
        return "T"
    end,
})

local function f(...)
    return ...
end

local function g(...)
    return `{...}`
end

print(`hello {name}!`)
print(`{n + 1} {n * n} {#name}`)
print(`{t}{nil}{true}{1.5}`)
print(`escapes: \` \{ \} \\ \n \t \x41 \u{41} \z
        done`)
print(`a{`b{`c{n}`}`}d`)
print(`{f("}")} {[=[}]=]} {1 --[[ } ]] + 1}`)
print(`{({a = 1}).a} { #{1, 2} } {({1, 2})[2]}`)
print(`a
multi-line
text {name}`)
print(`line one \
line two`)
print(`{1 +
  2}`)
print(`plain text`, ``, `{n}`, `{n}{n}`)
local s = `first {f(1, 2)} {f()} {g(7, 8)}`
print(s)
