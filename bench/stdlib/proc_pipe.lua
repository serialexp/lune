-- proc.pipe moving a large stream through several stages: the parent's poll
-- pump and the kernel pipes must stay linear in the bytes and bounded in
-- memory by max_bytes (doc 75 §3.5-3.6, Rule #20).
--
--   mahina              bench/stdlib/proc_pipe.lua   # tier-0
--
-- @bench args="64" luajit=skip
-- arg[1] is MiB the first stage writes; three `cat` stages carry it; only
-- the latest 64 KiB of the last stage's stdout is kept.
local mib = tonumber(arg and arg[1]) or 64
local total = mib * 1024 * 1024

local r = proc.pipe({
  {"/bin/sh", "-c", "head -c " .. total .. " /dev/zero"},
  {"cat"},
  {"cat"},
  {"cat"},
})
print(#r.stdout, r.truncated, r.ok, #r.stages)
