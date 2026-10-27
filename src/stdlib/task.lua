-- Doc 73 §7: the task library `async function` and `await` compile to
-- (bytecode `intrinsic`). The VM compiles it the first time a program uses
-- either and calls this chunk with the natives below, made fresh, so a
-- program that rebinds `coroutine` or `error` can't reach into it. It
-- returns spawn, wait (`await`) and drain; the VM runs drain when the
-- main chunk finishes.
--
-- A task is a table marked by TAG. It runs its function in a coroutine of
-- its own, which yields only from `await`: (TAG, the awaited task). The
-- ready queue holds the tasks the task they wait on has woken, in order.
local create, resume, yield, running, status, close, error, select, unpack, type, rawget = ...

local TAG = {}
local queue, head, tail = {}, 1, 0
-- Failed tasks no one may have awaited yet, judged at idle.
local unobserved, nun = {}, 0
-- The task whose coroutine is resumed innermost.
local current = nil

local function pack(...)
  return { n = select("#", ...), ... }
end

local function finish(t, ok, r)
  if ok then
    t.state = "done"
    t.results = r
  else
    t.state = "failed"
    t.err = r
    nun = nun + 1
    unobserved[nun] = t
  end
  local ws = t.waiters
  t.waiters = nil
  if ws then
    for i = 1, #ws do
      tail = tail + 1
      queue[tail] = ws[i]
    end
  end
end

-- Resume `t` until it waits or ends.
local function step(t, ...)
  local prev = current
  current = t
  t.state = "running"
  local r = pack(resume(t.co, ...))
  current = prev
  if not r[1] then return finish(t, false, r[2]) end
  if status(t.co) == "dead" then return finish(t, true, r) end
  if r[2] == TAG then
    local x = r[3]
    t.state = "waiting"
    local ws = x.waiters
    if ws == nil then
      ws = {}
      x.waiters = ws
    end
    ws[#ws + 1] = t
  else
    -- A task's coroutine is the library's: yielding from it is yielding
    -- from outside a coroutine.
    close(t.co)
    finish(t, false, "attempt to yield from outside a coroutine")
  end
end

-- Raise the first failure no one awaited.
local function idle()
  local n = nun
  nun = 0
  local found = nil
  for i = 1, n do
    local t = unobserved[i]
    unobserved[i] = nil
    if not t.observed then
      if found == nil then
        found = t
      else
        nun = nun + 1
        unobserved[nun] = t
      end
    end
  end
  if found then
    found.observed = true
    local e = found.err
    if type(e) == "string" then e = "unobserved task error: " .. e end
    error(e, 0)
  end
end

-- Run the next ready task; false when none is.
local function runReady()
  if head > tail then return false end
  local t = queue[head]
  queue[head] = nil
  head = head + 1
  step(t)
  return true
end

local function spawn(f, ...)
  local t = { [TAG] = true, co = create(f), observed = false }
  step(t, ...)
  -- Before its first wait an error is the call's, as a coroutine's is
  -- the resume's.
  if t.state == "failed" then
    t.observed = true
    error(t.err, 0)
  end
  return t
end

local function wait(x)
  if type(x) ~= "table" or rawget(x, TAG) == nil then return x end
  while true do
    local s = x.state
    if s == "done" then
      local r = x.results
      return unpack(r, 2, r.n)
    end
    if s == "failed" then
      x.observed = true
      error(x.err, 0)
    end
    local c = current
    if c ~= nil and running() == c.co then
      if x == c then error("a task cannot await itself", 2) end
      yield(TAG, x)
    elseif not runReady() then
      idle()
      error("deadlock: the awaited task can never finish", 2)
    end
  end
end

-- The main chunk's results, once every ready task has run.
local function drain(r)
  while runReady() do end
  idle()
  return unpack(r, 1, r.n)
end

-- A host's operation in flight: a task with no coroutine, which `settle`
-- finishes. The host's, not a program's (doc 73 §7 P4b).
local function pending()
  return { [TAG] = true, state = "waiting", observed = false }
end

local function settle(t, ok, ...)
  if t.co ~= nil or t.state ~= "waiting" then error("not a pending operation", 2) end
  if ok then
    finish(t, true, pack(true, ...))
  else
    finish(t, false, (...))
  end
end

return { spawn, wait, drain, pending, settle }
