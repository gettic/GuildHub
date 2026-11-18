-- Guild Hub: one event dispatcher and one ticker for every part of the addon.
--   GH:On(owner, event, fn [, unit])   several owners may listen to the same event
--   GH:Off(owner [, event])            an owner stops listening (all its events, or one)
--   GH:Every(owner, name, seconds, fn) a repeating job on the one 0.5-s ticker
--   GH:Cancel(owner [, name])          stops an owner's jobs (all, or one)
-- Every handler and job runs through xpcall with the game's error handler: one part's bug can't
-- stop the others, and the error still shows (BugGrabber, the game's error frame).
local _, ns = ...
local GH = ns.GH

local TICK = 0.5

local frame = CreateFrame("Frame") -- events only, never shown
local handlers = {}  -- [event] = { { owner, fn }, ... } in the order they were added
local jobs = {}      -- { { owner, name, every, due, fn }, ... }
GH.eventHandlers, GH.tickerJobs = handlers, jobs

local function ErrorHandler(err)
	local h = geterrorhandler and geterrorhandler()
	if h then h(err) end
	return err
end

local function Valid(event)
	if C_EventUtils and C_EventUtils.IsEventValid then
		local ok, valid = pcall(C_EventUtils.IsEventValid, event)
		if ok then return valid and true or false end
	end
	return true
end

frame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	-- a copy: a handler may add or remove handlers
	local n = #list
	local copy = {}
	for i = 1, n do copy[i] = list[i] end
	for i = 1, n do
		local h = copy[i]
		if not h.removed then xpcall(h.fn, ErrorHandler, event, ...) end
	end
end)

-- fn(event, ...). unit: "player" for unit events (RegisterUnitEvent).
function GH:On(owner, event, fn, unit)
	if type(fn) ~= "function" or type(event) ~= "string" then return false end
	local list = handlers[event]
	for _, h in ipairs(list or {}) do
		if h.owner == owner then h.fn = fn return true end -- one handler per owner and event
	end
	if not list then
		if not Valid(event) then return false end
		local ok
		if unit then
			ok = pcall(frame.RegisterUnitEvent, frame, event, unit)
		else
			ok = pcall(frame.RegisterEvent, frame, event)
		end
		if not ok then return false end
		list = {}
		handlers[event] = list
	end
	list[#list + 1] = { owner = owner, fn = fn }
	return true
end

function GH:Off(owner, event)
	for ev, list in pairs(handlers) do
		if not event or ev == event then
			for i = #list, 1, -1 do
				if list[i].owner == owner then
					list[i].removed = true
					table.remove(list, i)
				end
			end
			if #list == 0 then
				handlers[ev] = nil
				pcall(frame.UnregisterEvent, frame, ev)
			end
		end
	end
end

-- How many events an owner listens to (self-test, tests).
function GH:EventCount(owner)
	local n = 0
	for _, list in pairs(handlers) do
		for _, h in ipairs(list) do if h.owner == owner then n = n + 1 end end
	end
	return n
end

------------------------------------------------------------------------
-- The ticker
------------------------------------------------------------------------
local function Tick()
	local now = GetTime()
	local i = 1
	while i <= #jobs do
		local j = jobs[i]
		if not j.removed and now >= j.due - 0.001 then
			-- no drift (like AceTimer's repeating timers); after a long pause it starts afresh
			j.due = j.due + j.every
			if j.due <= now then j.due = now + j.every end
			xpcall(j.fn, ErrorHandler)
		end
		i = i + 1
	end
end
GH.TickNow = Tick -- tests

local function StartTicker()
	if GH.tickerHandle then return end
	GH.tickerHandle = GH:ScheduleRepeatingTimer(Tick, TICK)
end

-- A repeating job: first run `seconds` from now (like ScheduleRepeatingTimer).
function GH:Every(owner, name, seconds, fn)
	if type(fn) ~= "function" or type(seconds) ~= "number" or seconds <= 0 then return false end
	for _, j in ipairs(jobs) do
		if j.owner == owner and j.name == name then
			j.every, j.fn, j.due = seconds, fn, GetTime() + seconds
			StartTicker()
			return true
		end
	end
	jobs[#jobs + 1] = { owner = owner, name = name, every = seconds, due = GetTime() + seconds, fn = fn }
	StartTicker()
	return true
end

function GH:Cancel(owner, name)
	for i = #jobs, 1, -1 do
		local j = jobs[i]
		if j.owner == owner and (not name or j.name == name) then
			j.removed = true
			table.remove(jobs, i)
		end
	end
end

function GH:JobCount(owner)
	local n = 0
	for _, j in ipairs(jobs) do if not owner or j.owner == owner then n = n + 1 end end
	return n
end
