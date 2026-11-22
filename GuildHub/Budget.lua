-- Guild Hub: the message budget. One bucket mirrors the game's limit on our ONE prefix
-- (10 messages at once, +1 per second, every 255-character piece counts). Pieces are counted when
-- they really leave (Comm.lua's send-result callback); the gate before a send counts the tokens
-- minus the pieces still waiting in ChatThrottleLib.
--   live   (HELLO, HB, STATUS, GRP, CFG, FOFF, SYNCING): may use every token
--   normal (PROF, RREQ, REC): keeps 3 tokens free
--   bulk   (SYNC, RLIST, TEST): keeps 5 tokens free
-- Whispers outside instances don't count for the game, so they get their own allowance there
-- (10, +3 per second); inside an instance they count in the main bucket.
-- Throttled pieces are retried by ChatThrottleLib itself, so we never back off for those.
local _, ns = ...
local GH = ns.GH

local CAP = 10
local FLOOR = { live = 0, normal = 3, bulk = 5 }
-- whispers: about ChatThrottleLib's own pace (800 bytes/s = ~3 pieces/s), so sync answers are not
-- slower than in 0.3.0
local WHISPER_CAP, WHISPER_REFILL = 10, 3
local PENDING_TIMEOUT = 60
local BACKOFF_FIRST, BACKOFF_MAX = 10, 120
local MARGIN = 0.05 -- tokens kept spare on top of what a message needs (BudgetAllows)

local B = {
	guild = { tokens = CAP, cap = CAP, refill = 1, t = nil },
	whisper = { tokens = WHISPER_CAP, cap = WHISPER_CAP, refill = WHISPER_REFILL, t = nil },
	pending = {},       -- { { bucket, left = pieces, t }, ... } handed to AceComm, not all sent yet
	backoffUntil = 0,
	backoffStep = 0,
	sentLog = {},       -- { { t, pieces, bucket } } last 10 minutes (debug, /ghub status, tests)
	maxPerSecond = 0,
}
GH.budget = B
GH.BUDGET_FLOOR = FLOOR

local function Refill(b, now)
	if not b.t then b.t = now end
	local dt = now - b.t
	if dt > 0 then
		b.tokens = math.min(b.cap, b.tokens + dt * b.refill)
		b.t = now
	end
end

local function PendingOf(name)
	local n = 0
	for _, p in ipairs(B.pending) do if p.bucket == name then n = n + p.left end end
	return n
end

-- Which bucket a message uses.
function GH:BudgetBucket(target)
	if target and not IsInInstance() then return "whisper" end
	return "guild"
end

-- Tokens that can be used now (after the pieces still waiting).
function GH:BudgetFree(name)
	local b = B[name]
	Refill(b, GetTime())
	return b.tokens - PendingOf(name)
end

-- May a message of this class and size go now?
function GH:BudgetAllows(class, pieces, bucket)
	local now = GetTime()
	if class ~= "live" and now < B.backoffUntil then return false end
	local floor = FLOOR[class] or FLOOR.normal
	if bucket == "whisper" then floor = class == "bulk" and 2 or 0 end
	local b = B[bucket]
	local need = math.min(pieces, b.cap - floor) -- a message bigger than the room may start when the room is full
	local free = self:BudgetFree(bucket) - floor
	-- 1.0.0-beta.2: a small safety margin while the bucket is refilling, so a piece never goes out at
	-- 0.9999 tokens (the game's count and ours add the refill in different steps; the server refused a
	-- few in a 40-login storm). Only when the count holds refilled time: a full bucket, a burst at one
	-- moment (no time since the last spent token = whole tokens) and a full room are unchanged.
	if b.tokens < b.cap and GetTime() > (b.spentAt or -1) then need = math.min(need + MARGIN, b.cap - floor) end
	return free >= need
end

-- The message is handed to AceComm: its pieces are waiting.
function GH:BudgetHandOff(bucket, pieces)
	local p = { bucket = bucket, left = pieces, t = GetTime() }
	B.pending[#B.pending + 1] = p
	return p
end

-- One piece really left (or was given up): take a token, stop waiting for it.
function GH:BudgetPieceDone(p, didSend)
	if not p or p.left <= 0 then return end
	p.left = p.left - 1
	if p.left <= 0 then
		for i, x in ipairs(B.pending) do if x == p then table.remove(B.pending, i) break end end
	end
	if didSend then
		local now = GetTime()
		local b = B[p.bucket]
		Refill(b, now)
		b.tokens = math.max(-b.cap, b.tokens - 1)
		b.spentAt = now -- BudgetAllows: no margin for more pieces at this same moment
		B.sentLog[#B.sentLog + 1] = { t = now, bucket = p.bucket }
		B.backoffStep = 0
	end
end

-- A send failed for an unknown reason: pause normal and bulk messages (10, 20, 40 ... 120 s).
function GH:BudgetBackOff()
	B.backoffStep = B.backoffStep + 1
	local wait = math.min(BACKOFF_MAX, BACKOFF_FIRST * 2 ^ (B.backoffStep - 1))
	B.backoffUntil = GetTime() + wait
	self:Debug("messages paused for %d s after a failed send", wait)
end

-- Ticker job: drops pending pieces that never got an answer, trims the log.
function GH:BudgetTick()
	local now = GetTime()
	for i = #B.pending, 1, -1 do
		if now - B.pending[i].t > PENDING_TIMEOUT then table.remove(B.pending, i) end
	end
	local cut = now - 600
	local log = B.sentLog
	local first = 1
	while log[first] and log[first].t < cut do first = first + 1 end
	if first > 1 then
		local keep = {}
		for i = first, #log do keep[#keep + 1] = log[i] end
		B.sentLog = keep
	end
end

-- Pieces sent in the last `sec` seconds (GUILD bucket by default).
function GH:BudgetSent(sec, bucket)
	local now, n = GetTime(), 0
	for _, e in ipairs(B.sentLog) do
		if now - e.t <= (sec or 600) and (not bucket or e.bucket == bucket) then n = n + 1 end
	end
	return n
end
