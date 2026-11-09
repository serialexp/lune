-- proc.run capturing a large stream: the poll pump must stay linear in the
-- bytes read and keep memory bounded by max_bytes (doc 75 §3.5, Rule #20).
--
--   mahina              bench/stdlib/proc_capture.lua   # tier-0
--
-- @bench args="64" luajit=skip
-- arg[1] is MiB of output the child writes; each run captures all of it
-- once unbounded-ish (max_bytes = the whole stream) and once keeping only
-- the latest 64 KiB (the default), then prints sizes, which are exact.
local mib = tonumber(arg and arg[1]) or 64
local total = mib * 1024 * 1024
local cmd = "head -c " .. total .. " /dev/zero"

local full = proc.run({ "/bin/sh", "-c", cmd, max_bytes = total })
print(#full.stdout, full.truncated)

local tail = proc.run({ "/bin/sh", "-c", cmd })
print(#tail.stdout, tail.truncated)
