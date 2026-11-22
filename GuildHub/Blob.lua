-- Guild Hub: BLOB, per-member lists fetched only when someone looks (1.0.2, plans\next-batch-2-1.0.x X3,
-- tos-check.md). The first kind is "gear" (Features\Gear.lua). Recipe lists stay on RREQ/RLIST (D2).
--   BREQ {k, o, h}           asker -> owner (WHISPER): "send me your list k; I have the copy with hash h"
--   BLST {k, o, n = 1}        owner -> asker: "no" (not shared, or nothing to send)
--   BLST {k, o, h, s = 1}     owner -> asker: "same" (your copy is current)
--   BLST {k, o, h, i, c, d}   owner -> asker: piece i of c (d = at most CHUNK characters)
-- Rules (tos): only the owner answers about itself; only online guildmates with Guild Hub are asked; one
-- open request at a time, at least REQ_GAP apart; 30 s timeout, 120 s back-off per owner; no answers in an
-- instance or lockdown; answers paced at RATE bytes per second; pieces put together and the hash checked.
local _, ns = ...
local GH, U = ns.GH, ns.Util

local RATE = 200          -- bytes per second of answers (same as recipe lists, tos cap ~300)
local REQ_GAP = 3         -- seconds between two requests we send
local REQ_TIMEOUT = 30
local BACKOFF = 120       -- seconds an owner who didn't answer is not asked again
local CHUNK = 150         -- list characters per BLST piece
local PARTS_TIMEOUT = 120
local QUEUE_MAX = 20      -- requests waiting to be sent
local OUT_MAX = 12        -- answers waiting to be sent
local ASKER_GAP = 10      -- one answer per asker and kind per 10 s
local PAUSE = 30          -- after a failed send of an answer
local OUT_STALE = REQ_TIMEOUT -- an answer not (further) sent for this long: the asker gave up, dropped
GH.BLOB_LIMITS = { RATE = RATE, REQ_GAP = REQ_GAP, REQ_TIMEOUT = REQ_TIMEOUT, BACKOFF = BACKOFF, CHUNK = CHUNK,
	QUEUE_MAX = QUEUE_MAX, OUT_MAX = OUT_MAX, ASKER_GAP = ASKER_GAP }

GH.blobKinds = {}
GH.blobQueue, GH.blobOut, GH.blobParts, GH.blobBackoff, GH.blobAnswered = {}, {}, {}, {}, {}
GH.blobStats = { asked = 0, answers = 0, same = 0, no = 0, got = 0, bad = 0, timeouts = 0, ignored = 0, stale = 0 }

-- spec = { feature, maxBytes, build(gh) -> data string or nil (= "no"), accept(gh, owner, data|nil, h, same),
--          fail(gh, owner, why), canAsk(gh) -> ok }
function GH:BlobKind(kind, spec)
	assert(type(kind) == "string" and type(spec) == "table" and type(spec.build) == "function"
		and type(spec.accept) == "function", "BlobKind: needs build and accept")
	spec.maxBytes = spec.maxBytes or 1000
	self.blobKinds[kind] = spec
end

function GH:BlobHash(data) return U.Checksum(data or "") end

local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local function CanTalk()
	return not (GH:InLockdown() or IsInInstance() or GH.cannotSend)
end
GH.BlobCanTalk = CanTalk

local function KindOn(gh, spec)
	return spec and (not spec.feature or gh:FeatureOn(spec.feature)) and true or false
end

-- May we ask this owner for this kind now? Returns ok, why.
function GH:BlobCanAsk(kind, owner)
	local spec = self.blobKinds[kind]
	if not KindOn(self, spec) then return false, "feature" end
	if spec.canAsk and not spec.canAsk(self) then return false, "share" end
	if type(owner) ~= "string" or owner == self:MyName() then return false, "self" end
	if not self:IsGuildMember(owner) then return false, "member" end
	if not self:IsAddonUserOnline(owner) then return false, "offline" end -- tos: online guildmates with Guild Hub only
	if (self.blobBackoff[owner] or 0) > GetTime() then return false, "wait" end
	if InCombat() or not CanTalk() then return false, "busy" end
	return true
end

local function Waiting(gh, kind, owner)
	local r = gh.blobReq
	if r and r.k == kind and r.o == owner then return true end
	for _, q in ipairs(gh.blobQueue) do if q.k == kind and q.o == owner then return true end end
	return false
end
function GH:BlobWaiting(kind, owner) return Waiting(self, kind, owner) end

-- Queue one request. Returns true when queued (or already waiting), else false, why.
function GH:BlobRequest(kind, owner, h)
	local ok, why = self:BlobCanAsk(kind, owner)
	if not ok then return false, why end
	if Waiting(self, kind, owner) then return true end
	if #self.blobQueue >= QUEUE_MAX then return false, "full" end
	self.blobQueue[#self.blobQueue + 1] = { k = kind, o = owner, h = type(h) == "number" and h or nil }
	return true
end

-- Drops waiting requests (a stopped "Check enchants" run). filter(q) -> true = drop.
function GH:BlobDropQueued(filter)
	for i = #self.blobQueue, 1, -1 do
		if filter(self.blobQueue[i]) then table.remove(self.blobQueue, i) end
	end
end

local function Fail(gh, req, why)
	local spec = gh.blobKinds[req.k]
	if spec and spec.fail then pcall(spec.fail, gh, req.o, why) end
end

-- One step (0.5 s): the open request's timeout, the next request, the next answer piece.
function GH:BlobTick()
	local now = GetTime()
	local req = self.blobReq
	if req and now - req.t >= REQ_TIMEOUT then
		self.blobReq = nil
		self.blobBackoff[req.o] = now + BACKOFF
		self.blobStats.timeouts = self.blobStats.timeouts + 1
		Fail(self, req, "timeout")
		req = nil
	end
	if not req and #self.blobQueue > 0 and now - (self.blobReqLast or -1000) >= REQ_GAP then
		local q = table.remove(self.blobQueue, 1)
		local ok, why = self:BlobCanAsk(q.k, q.o)
		if ok then
			self.blobReq = { k = q.k, o = q.o, t = now }
			self.blobReqLast = now
			self.blobStats.asked = self.blobStats.asked + 1
			self:SendMsg("BREQ", { k = q.k, o = q.o, h = q.h }, q.o)
		elseif why ~= "busy" then
			Fail(self, q, why)
		else
			table.insert(self.blobQueue, 1, q) -- combat / instance / lockdown: wait
		end
	end
	self:BlobOutTick(now)
end

-- Answers, one piece per step, RATE bytes per second on average.
function GH:BlobOutTick(now)
	now = now or GetTime()
	-- stale answers (held back by an instance / lockdown / a failed send): the asker timed out, so drop them
	for i = #self.blobOut, 1, -1 do
		local a = self.blobOut[i]
		if now - (a.last or a.at or now) > OUT_STALE then
			table.remove(self.blobOut, i)
			self.blobStats.stale = (self.blobStats.stale or 0) + 1
		end
	end
	if #self.blobOut == 0 or now < (self.blobOutNext or 0) then return end
	if not CanTalk() then
		self.blobOutNext = now + 10
		return
	end
	local a = self.blobOut[1]
	if not self:IsOnline(a.to) then table.remove(self.blobOut, 1) return end
	local d
	if a.no or a.same then
		table.remove(self.blobOut, 1)
		d = a.no and { k = a.k, o = a.o, n = 1 } or { k = a.k, o = a.o, h = a.h, s = 1 }
	else
		local count = math.max(1, math.ceil(#a.data / CHUNK))
		a.i = (a.i or 0) + 1
		a.last = now
		d = { k = a.k, o = a.o, h = a.h, i = a.i, c = count, d = a.data:sub((a.i - 1) * CHUNK + 1, a.i * CHUNK) }
		if a.i >= count then table.remove(self.blobOut, 1) end
	end
	self.blobOutNext = now + (#self:Serialize(d) + 12) / RATE
	self:SendMsg("BLST", d, a.to, "BULK")
end

-- Comm.lua OnSendFailed.
function GH:OnBlobSendFailed(info)
	if not info then return end
	if info.mtype == "BLST" then
		self.blobOutNext = GetTime() + PAUSE
	elseif info.mtype == "BREQ" and self.blobReq then
		local req = self.blobReq
		self.blobReq = nil
		self.blobBackoff[req.o] = GetTime() + BACKOFF
		Fail(self, req, "failed")
	end
end

GH.handlers.BREQ = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" or type(data) ~= "table" then return end
	local spec = type(data.k) == "string" and self.blobKinds[data.k]
	if not KindOn(self, spec) or data.o ~= self:MyName() then return end -- only lists about ourselves
	if not self:IsGuildMember(sender) then return end
	if IsInInstance() or self:InLockdown() then return end -- no answers in an instance or lockdown
	local key = sender .. "\001" .. data.k
	local now = GetTime()
	if now - (self.blobAnswered[key] or -1000) < ASKER_GAP then
		self.blobStats.ignored = self.blobStats.ignored + 1
		return
	end
	for _, a in ipairs(self.blobOut) do if a.to == sender and a.k == data.k then return end end
	if #self.blobOut >= OUT_MAX then return end
	self.blobAnswered[key] = now
	local ok, payload = pcall(spec.build, self)
	if not ok or type(payload) ~= "string" or payload == "" or #payload > spec.maxBytes then
		self.blobOut[#self.blobOut + 1] = { to = sender, k = data.k, o = data.o, no = true, at = now }
		self.blobStats.no = self.blobStats.no + 1
		return
	end
	local h = self:BlobHash(payload)
	if data.h == h then
		self.blobOut[#self.blobOut + 1] = { to = sender, k = data.k, o = data.o, h = h, same = true, at = now }
		self.blobStats.same = self.blobStats.same + 1
	else
		self.blobOut[#self.blobOut + 1] = { to = sender, k = data.k, o = data.o, h = h, data = payload, at = now }
		self.blobStats.answers = self.blobStats.answers + 1
	end
end

GH.handlers.BLST = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" or type(data) ~= "table" then return end
	local spec = type(data.k) == "string" and self.blobKinds[data.k]
	if not KindOn(self, spec) or data.o ~= sender then return end -- only the owner answers about itself
	local req = self.blobReq
	local mine = req and req.k == data.k and req.o == sender
	if not mine then return end -- we never asked (or gave up): ignored
	if data.n then
		self.blobReq = nil
		Fail(self, req, "no")
		return
	end
	local h = U.ValidNumber(data.h, 0, 4294967295)
	if not h then return end
	if data.s then
		self.blobReq = nil
		pcall(spec.accept, self, sender, nil, h, true)
		return
	end
	local maxPieces = math.ceil(spec.maxBytes / CHUNK)
	local count = U.ValidNumber(data.c, 1, maxPieces)
	local i = count and U.ValidNumber(data.i, 1, count)
	if not (count and i and type(data.d) == "string" and #data.d <= CHUNK) then
		self.blobStats.bad = self.blobStats.bad + 1
		return
	end
	req.t = GetTime() -- pieces coming in: the request is alive
	local now = GetTime()
	for k, b in pairs(self.blobParts) do
		if now - b.t > PARTS_TIMEOUT then self.blobParts[k] = nil end
	end
	local pk = sender .. "\001" .. data.k
	local b = self.blobParts[pk]
	if i == 1 then
		b = { h = h, c = count, got = {}, n = 0, t = now }
		self.blobParts[pk] = b
	elseif not b or b.h ~= h or b.c ~= count then
		return
	end
	if not b.got[i] then b.got[i], b.n = data.d, b.n + 1 end
	b.t = now
	if b.n < b.c then return end
	self.blobParts[pk] = nil
	self.blobReq = nil
	local whole = table.concat(b.got, "", 1, b.c)
	if #whole > spec.maxBytes or self:BlobHash(whole) ~= h then
		self.blobStats.bad = self.blobStats.bad + 1
		Fail(self, req, "bad")
		return
	end
	self.blobStats.got = self.blobStats.got + 1
	pcall(spec.accept, self, sender, whole, h, false)
end

-- Started and stopped by the features that use it (Features\Gear.lua).
function GH:BlobStart(owner)
	self:Every(owner, "blob", 0.5, function() GH:BlobTick() end)
end

function GH:BlobReset()
	self.blobQueue, self.blobOut, self.blobParts, self.blobReq = {}, {}, {}, nil
end
