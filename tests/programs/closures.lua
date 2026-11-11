-- Closures (doc 86 P1 corpus): shared and per-iteration upvalues, varargs,
-- recursion and a closure that outlives its frame.
local function counter(step)
    local n = 0
    return function()
        n = n + step
        return n
    end,
        function()
            return n
        end
end

local inc, peek = counter(3)
for _ = 1, 4 do
    inc()
end
print("counter", peek())

local fns = {}
for i = 1, 5 do
    fns[i] = function()
        return i * i
    end
end
local acc = {}
for i = 1, #fns do
    acc[#acc + 1] = fns[i]()
end
print("squares", table.concat(acc, " "))

local function sum(...)
    local s = 0
    for i = 1, select("#", ...) do
        s = s + (select(i, ...) or 0)
    end
    return s, select("#", ...)
end

print("varargs", sum(1, 2, nil, 4))

local function fib(n)
    if n < 2 then
        return n
    end
    return fib(n - 1) + fib(n - 2)
end

print("fib", fib(15))

local function compose(f, g)
    return function(...)
        return f(g(...))
    end
end

local twice = compose(
    function(x)
        return x * 2
    end,
    function(a, b)
        return a + b
    end
)
print("compose", twice(3, 4))
