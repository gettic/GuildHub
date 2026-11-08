-- Guild Hub: login sync.
-- 1. A player who logs in sends HELLO (with the time they were last online).
-- 2. Everyone with Guild Hub makes the same sorted list of possible responders, so they
--    agree who answers: #1 after 1 s, #2 after 4 s, #3 after 10 s, #4 after 13 s.
--    The one who answers first sends SYNCING to the guild, and the others stay quiet.
--    Nobody after #4 ever answers, so there is no retry storm.
-- 3. The answer goes by WHISPER (not throttled outside instances), in batches.
--    No answers to players who are in an instance (whispers are throttled there);
--    they send HELLO again when they come out.
local _, ns = ...
local GH, U = ns.GH, ns.Util

local RESPONDER_DELAYS = { 1, 4, 10, 13 }
local BATCH_SIZE = 6 -- members per SYNC batch (records carry statuses since step 2)
local ACTIVE_SECONDS = 600 -- a Guild Hub user heard from in the last 10 minutes

GH.syncSeen = {} -- [asker] = GetTime() when someone announced SYNCING for them

function GH:SendHello()
	self.helloPending = false
	local gdb = self:GetGuildDB()
	if not gdb then return end
	local info = self:SelfInfo()
	info.since = gdb.lastOnline or 0
	self:SendMsg("HELLO", info)
	gdb.lastOnline = U.Now()
	-- tell the guild our status right away (if we have one)
	if self:HasStatusToShare() then self:SendStatus() end
end

-- Same list on every client: active Guild Hub users, online, not in an instance, not the asker.
function GH:ResponderList(asker)
	local list = {}
	local now = GetTime()
	local me = self:MyName()
	for name, u in pairs(self.addonUsers) do
		if name ~= asker then
			local ok
			if name == me then
				ok = not IsInInstance()
			else
				ok = self:IsOnline(name) and (now - (u.seen or 0)) < ACTIVE_SECONDS and not u.inst
			end
			if ok then list[#list + 1] = name end
		end
	end
	table.sort(list)
	return list
end

GH.handlers.HELLO = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	self:ReadSelfInfo(sender, data)

	if data.inst == true then
		self:Debug("no sync for %s (they are in an instance)", U.ShortName(sender))
		return
	end

	local list = self:ResponderList(sender)
	local myRank
	for i, name in ipairs(list) do
		if name == self:MyName() then myRank = i break end
	end
	if not myRank or not RESPONDER_DELAYS[myRank] then return end

	local since = U.ValidTime(data.since) or 0
	local helloTime = GetTime()
	self:Debug("I am sync responder #%d for %s", myRank, U.ShortName(sender))
	self:ScheduleTimer(function()
		local seen = GH.syncSeen[sender]
		if myRank > 1 and seen and seen >= helloTime then
			GH:Debug("someone else is syncing %s, staying quiet", U.ShortName(sender))
			return
		end
		GH:AnswerSync(sender, since)
	end, RESPONDER_DELAYS[myRank])
end

GH.handlers.SYNCING = function(self, sender, data, distribution, isSelf)
	if distribution ~= "GUILD" then return end
	local asker = U.ValidName(data.n)
	if asker then self.syncSeen[asker] = GetTime() end
end

function GH:AnswerSync(asker, since)
	local gdb = self:GetGuildDB()
	if not gdb or not self:IsOnline(asker) then return end
	if self:InLockdown() or IsInInstance() then return end
	local au = self.addonUsers[asker]
	if au and au.inst then return end -- they went into an instance meanwhile; they ask again later

	self:SendMsg("SYNCING", { n = asker })

	local now = U.Now()
	local cutoff = now - self.PRUNE_DAYS * 86400
	local names, newest, statuses = {}, {}, {}
	for name, m in pairs(gdb.members) do
		-- statuses only for members online now, whose preset/note is still within its own duration
		-- (1-8 h) or whose activity changed in the last hour
		local s = m.status
		local useful = type(s) == "table" and self:IsOnline(name)
			and (self:IsStatusFresh(s) or (s.a ~= nil and (now - (s.ts or 0)) < self.STATUS_TTL))
		local sts = useful and (s.ts or 0) or 0
		if name ~= asker and (m.lastSeen or 0) >= cutoff and ((m.ts or 0) > since or sts > since) then
			names[#names + 1] = name
			newest[name] = math.max(m.ts or 0, sts)
			if sts > 0 then statuses[name] = self:StatusPayload(s) end
		end
	end
	-- newest first
	table.sort(names, function(a, b) return newest[a] > newest[b] end)

	local cfg = ((gdb.cfg.ts or 0) > since and gdb.cfg.by) and gdb.cfg or nil
	local batches = math.max(1, math.ceil(#names / BATCH_SIZE))
	for b = 1, batches do
		local part = {}
		for i = (b - 1) * BATCH_SIZE + 1, math.min(b * BATCH_SIZE, #names) do
			local name = names[i]
			local m = gdb.members[name]
			part[name] = { ts = m.ts, class = m.class, level = m.level, version = m.version, lastSeen = m.lastSeen,
				status = statuses[name] } -- older clients drop "status" (CleanRecord ignores unknown fields)
		end
		self:SendMsg("SYNC", { b = b, of = batches, m = part, cfg = (b == 1) and cfg or nil }, asker, "BULK")
	end
	self:Debug("sync for %s: %d members in %d batches", U.ShortName(asker), #names, batches)
end

GH.handlers.SYNC = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" then return end
	local count = 0
	if type(data.m) == "table" then
		for name, rec in pairs(data.m) do
			name = U.ValidName(name)
			if name and not self:IsGuildMember(name) then name = nil end
			local clean = name and self:CleanRecord(rec)
			if clean and self:MergeMember(name, clean) then count = count + 1 end
			if name and type(rec) == "table" and type(rec.status) == "table" then
				-- statuses from a sync never show notes
				self:MergeStatus(name, self:CleanStatus(rec.status))
			end
		end
	end
	if data.cfg then self:MergeCfg(data.cfg) end
	self.syncedThisSession = true
	self:RefreshBoard()
	self:Debug("sync batch %s/%s from %s: %d records updated", tostring(data.b), tostring(data.of),
		U.ShortName(sender), count)
end
