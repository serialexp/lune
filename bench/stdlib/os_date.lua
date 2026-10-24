-- os.date and os.time(t) over a spread of instants: the C-locale strftime
-- in the VM and the local-zone lookups (doc 65 §8, §9).
--
--   mahina              bench/stdlib/os_date.lua   # tier-0
--   luajit              bench/stdlib/os_date.lua   # reference
--
-- @bench args="300000" luajit=compatible
-- The output does not depend on the machine's zone: the format has a
-- fixed width (no %Z), and a local noon converted and broken down again
-- is the calendar's own date. (The date comes back through os.date: Lua
-- 5.1, as LuaJIT runs it, does not normalize the table os.time reads.)
local N = tonumber(arg and arg[1]) or 300000
local len, days = 0, 0
for i = 1, N do
  local s = os.date("%Y-%m-%d %H:%M:%S %a %b %j", 1700000000 + i * 3607)
  len = len + #s
  local t = os.date("*t", os.time({year = 2024, month = 1 + i % 12, day = 1 + i % 40, hour = 12}))
  days = days + t.day + t.month
end
print(len, days)
