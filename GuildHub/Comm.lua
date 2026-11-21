-- Guild Hub: the message system. Sending (with pacing, lockdown and trial checks),
-- receiving (with checks on everything that comes in), heartbeat, guild settings, split test.
--
-- Wire format: "<proto>\t<TYPE>\t<AceSerializer data>"
-- AceComm splits anything over 255 characters and ChatThrottleLib paces the sending.
-- Incoming messages only ever update stored data or print a line; they never make
-- the game do anything (no invites, whispers, follows ...).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local tconcat = table.concat

-- The message system's own types (other features register theirs: Status.lua, Professions.lua).
-- min = shortest time between two messages of the same type (seconds): a message sent sooner is
-- held back and only the newest one goes out when the time is up. keep = kept and sent later when
-- a boss fight / PvP match blocks messages (others are dropped then). class = budget class
-- (Budget.lua). latest = while waiting for the budget, a newer one replaces the older one.
GH:RegisterFeature({
	key = "comm", core = true,
	messages = {
		HELLO   = { class = "live", min = 30, keep = true, latest = true },
		HB      = { class = "live", min = 60, keep = true, latest = true },
		CFG     = { class = "live", min = 10, keep = true, latest = true },
		FOFF    = { class = "live", min = 10, keep = true, latest = true }, -- officers' guild feature switch
		REC     = { class = "normal", min = 30, keep = true, latest = true }, -- bundle: changed fields only
		TEST    = { class = "bulk", min = 10 },
		SYNCING = { class = "live", min = 0 },
		SYNC    = { class = "bulk", min = 0 },
	},
})

local MAX_INCOMING = 30000 -- characters; anything bigger is dropped

GH.handlers  = GH.handlers or {} -- [TYPE] = function(self, sender, data, distribution) (Features.lua adds FOFF, REC)
GH.addonUsers = {} -- ["Name-Realm"] = { seen = GetTime(), version, inst }
GH.lastSent  = {}
GH.held      = {}
GH.sendQueue = {}  -- messages waiting for the budget (Budget.lua): { key, mtype, text, target, prio, class, bucket, pieces }
GH.goneTargets = {} -- [name] = GetTime(): a whisper to them failed because they went offline

local function MsgType(mtype)
	return GH.msgTypes[mtype] or { class = "normal", min = 5, keep = false, latest = false }
end

local function Pieces(text)
	if #text <= 255 then return 1 end
	return math.ceil(#text / 254)
end

function GH:InitComm()
	self:RegisterComm(self.PREFIX, "OnCommReceived")
	self:On("comm", "ADDON_RESTRICTION_STATE_CHANGED", function() GH:FlushHeld() end)
	self:On("comm", "PLAYER_GUILD_UPDATE", function() GH.notInGuild = nil end)
	self:Every("comm", "budget", 0.5, function() GH:FlushQueue() end)
	self:Every("comm", "budgetTidy", 10, function() GH:BudgetTick() end)
	self.addonUsers[self:MyName() or "?"] = { seen = GetTime(), version = self.VERSION }
end

------------------------------------------------------------------------
-- Can we send at all?
------------------------------------------------------------------------
function GH:InLockdown()
	return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() and true or false
end

function GH:IsTrial()
	return (IsTrialAccount and IsTrialAccount()) or (IsVeteranTrialAccount and IsVeteranTrialAccount()) or false
end

function GH:CheckTrialAccount()
	if self:IsTrial() then
		self.cannotSend = true
		if not self.db.char.trialNoticeShown then
			self.db.char.trialNoticeShown = true
			self:Msg(L.TRIAL_NOTE)
		end
	end
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------
-- mtype: message type; data: table; target: name for WHISPER (nil = GUILD); prio: "NORMAL"/"BULK"
function GH:SendMsg(mtype, data, target, prio)
	if self.cannotSend or self.notInGuild or not IsInGuild() then return end
	if not self:TypeOn(mtype) then
		self:Debug("not sent: %s (that part is switched off)", mtype)
		return
	end
	local mt = MsgType(mtype)
	-- a type with its own gate (POS: only after the player's yes, never in instances ...)
	if mt.gate and not mt.gate(self, data, target) then
		self:Debug("not sent: %s (not allowed right now)", mtype)
		return
	end
	local key = target and (mtype .. ":" .. target) or mtype

	-- pacing per type. An urgent one (e.g. POS 'off') replaces a held one and skips the type's gap;
	-- urgent may return a number = its own smaller gap between two urgent ones.
	local wait = mt.min - (GetTime() - (self.lastSent[key] or -1000))
	local urgent = mt.urgent and mt.urgent(data)
	if urgent then
		local h = self.held[key]
		if h and h.timer and not h.urgent then
			self:CancelTimer(h.timer)
			self.held[key] = nil
		end
		self.urgentAt = self.urgentAt or {}
		wait = type(urgent) == "number" and (urgent - (GetTime() - (self.urgentAt[key] or -1000))) or 0
		if wait <= 0 then self.urgentAt[key] = GetTime() end
	end
	if wait > 0 then
		local h = self.held[key]
		local timer = h and h.timer or self:ScheduleTimer("SendHeld", wait + 0.1, key)
		self.held[key] = { mtype, data, target, prio, timer = timer, urgent = urgent and true or nil }
		return
	end

	-- boss fight / PvP match: keep the important ones, drop the rest
	if self:InLockdown() then
		self:HoldForLockdown(key, mtype, data, target, prio)
		return
	end

	local text = tconcat({ self.PROTO, mtype, self:Serialize(data) }, "\t")
	local item = { key = key, mtype = mtype, text = text, target = target, prio = prio, class = mt.class,
		bucket = self:BudgetBucket(target), pieces = Pieces(text), t = GetTime(),
		data = (mt.gate or mt.onSend) and data or nil }
	-- the budget: wait in the queue if there is no room (or others are already waiting)
	if self:QueueWaiting(item.bucket, item.class) or not self:BudgetAllows(item.class, item.pieces, item.bucket) then
		self:Enqueue(item, mt.latest)
		return
	end
	self:DoSend(item)
end

function GH:HoldForLockdown(key, mtype, data, target, prio)
	if MsgType(mtype).keep then
		self.held[key] = { mtype, data, target, prio, lockdown = true }
		if not self.lockdownJob then
			self:Debug(L.LOCKDOWN_PAUSED)
			self.lockdownJob = true
			self:Every("comm", "lockdown", 5, function() GH:FlushHeld() end)
		end
	else
		self:Debug("dropped %s (messages are paused)", mtype)
	end
end

-- Something of this bucket and class (or a more urgent class) is already waiting: keep the order.
local CLASS_RANK = { live = 1, normal = 2, bulk = 3 }
function GH:QueueWaiting(bucket, class)
	for _, q in ipairs(self.sendQueue) do
		if q.bucket == bucket and CLASS_RANK[q.class] <= CLASS_RANK[class] then return true end
	end
	return false
end

function GH:Enqueue(item, latest)
	if latest then
		for i, q in ipairs(self.sendQueue) do
			if q.key == item.key then
				item.t = q.t
				self.sendQueue[i] = item -- the newest replaces the waiting one, keeps its place
				return
			end
		end
	end
	self.sendQueue[#self.sendQueue + 1] = item
	self:Debug("waiting for room: %s (%d pieces)", item.mtype, item.pieces)
end

-- Ticker (0.5 s): send what fits, most urgent class first, oldest first, never out of order
-- within one bucket and class.
function GH:FlushQueue()
	local q = self.sendQueue
	if #q == 0 then return end
	if self.cannotSend or self.notInGuild or not IsInGuild() then return end
	local lockdown = self:InLockdown()
	local blocked = {}
	for rank = 1, 3 do
		local i = 1
		while i <= #q do
			local item = q[i]
			if CLASS_RANK[item.class] == rank then
				local bk = item.bucket .. ":" .. item.class
				local gate = MsgType(item.mtype).gate
				if not self:TypeOn(item.mtype) or (item.target and self.goneTargets[item.target])
					or (gate and not gate(self, item.data, item.target)) then
					table.remove(q, i) -- switched off meanwhile / the player went offline / no longer allowed
				elseif lockdown then
					table.remove(q, i)
					self:HoldForLockdown(item.key, item.mtype, nil, item.target, item.prio)
					if self.held[item.key] then self.held[item.key].text = item.text end
				elseif blocked[bk] or not self:BudgetAllows(item.class, item.pieces, item.bucket) then
					blocked[bk] = true
					i = i + 1
				else
					table.remove(q, i)
					self:DoSend(item)
				end
			else
				i = i + 1
			end
		end
	end
end

function GH:DoSend(item)
	-- officer types (Guild Recruiter lists) go on OFFICER, never on GUILD; it counts in the guild bucket
	local channel = item.target and "WHISPER" or (MsgType(item.mtype).officer and "OFFICER" or "GUILD")
	self.lastSent[item.key] = GetTime()
	local pend = self:BudgetHandOff(item.bucket, item.pieces)
	local free = self:BudgetFree(item.bucket)
	self:Debug("> %s to %s (%d chars, %d pieces, budget %d/10)", item.mtype,
		item.target and U.ShortName(item.target) or "guild", #item.text, item.pieces, math.max(0, math.floor(free)))
	if item.mtype == "REC" and self.OnRecSent then self:OnRecSent() end
	local onSend = MsgType(item.mtype).onSend
	if onSend then onSend(self, item) end
	if self.goneTargets[item.target or ""] then self.goneTargets[item.target] = nil end
	-- whisper to "Mira Ashford", not "Mira Ashford-Realm" (WoW Forever names); info keeps the key
	self:SendCommMessage(self.PREFIX, item.text, channel, item.target and U.WhisperName(item.target),
		item.prio or "NORMAL", self.OnSendResult, { mtype = item.mtype, target = item.target, pend = pend })
end

-- Called by AceComm for each piece when it really leaves (or fails): (arg, bytesSent, bytesTotal, didSend)
function GH.OnSendResult(info, sent, total, didSend)
	GH:BudgetPieceDone(info.pend, didSend ~= false)
	if didSend == false then
		if not info.failed then
			info.failed = true
			GH:OnSendFailed(info)
		end
	elseif sent == total then
		GH:Debug("  %s sent OK", info.mtype)
	end
end

-- AceComm only says "sent / not sent", so the reason is worked out from the game state.
-- (Throttled pieces never get here: ChatThrottleLib retries them itself.)
function GH:OnSendFailed(info)
	local why
	if self:InLockdown() then
		why = "messages are paused (boss fight or PvP match)"
	elseif not IsInGuild() then
		why = "not in a guild"
		self.notInGuild = true -- until PLAYER_GUILD_UPDATE
	elseif self:IsTrial() then
		why = "trial account"
		self:CheckTrialAccount()
	elseif info.target and not self:IsOnline(info.target) then
		why = "player went offline"
		self.goneTargets[info.target] = GetTime() -- their waiting answers are dropped; no pause
	else
		why = "the game refused it"
		self:BudgetBackOff()
	end
	self:Debug("|cffff6060%s was NOT sent: %s|r", info.mtype, why)
	if self.OnProfSendFailed then self:OnProfSendFailed(info) end -- recipe lists back off
end

function GH:SendHeld(key)
	local h = self.held[key]
	if not h then return end
	self.held[key] = nil
	self:SendMsg(h[1], h[2], h[3], h[4])
end

-- Lockdown ended (event or 5-second check): send what was kept.
function GH:FlushHeld()
	if self:InLockdown() then return end
	if self.lockdownJob then
		self:Cancel("comm", "lockdown")
		self.lockdownJob = nil
	end
	for key, h in pairs(self.held) do
		if h.lockdown then
			self.held[key] = nil
			if h[2] ~= nil then
				self:SendMsg(h[1], h[2], h[3], h[4])
			elseif h.text then -- came from the budget queue already serialized
				local mt = MsgType(h[1])
				self:Enqueue({ key = key, mtype = h[1], text = h.text, target = h[3], prio = h[4], class = mt.class,
					bucket = self:BudgetBucket(h[3]), pieces = Pieces(h.text), t = GetTime() }, mt.latest)
			end
		end
	end
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
function GH:OnCommReceived(prefix, text, distribution, sender)
	if prefix ~= self.PREFIX then return end
	if U.IsSecret(text) or U.IsSecret(sender) or U.IsSecret(distribution) then
		self:Debug("ignored a message (hidden by the game)")
		return
	end
	if type(text) ~= "string" or type(sender) ~= "string" then
		self:Debug("ignored a message (bad data)")
		return
	end
	-- names from outside are cleaned before they are printed
	local shown = U.CleanText(sender, 40) or "?"
	if #text > MAX_INCOMING then
		self:Debug("ignored a message from %s (too big: %d chars)", shown, #text)
		return
	end
	if distribution ~= "GUILD" and distribution ~= "WHISPER" and distribution ~= "OFFICER" then
		self:Debug("ignored a message from %s (channel %s)", shown, U.CleanText(tostring(distribution), 20) or "?")
		return
	end

	local full = U.ValidName(U.FullName(sender))
	if not full then
		self:Debug("ignored a message: bad sender name '%s'", shown)
		return
	end
	sender = full

	local proto, mtype, body = text:match("^(%d+)\t(%u+)\t(.*)$")
	proto = tonumber(proto)
	if not proto then
		self:Debug("ignored a message from %s (unreadable format)", U.ShortName(sender))
		return
	end

	-- OFFICER carries only officer types, and officer types come only on OFFICER (never GUILD/WHISPER)
	local mtInfo = self.msgTypes[mtype]
	if (distribution == "OFFICER") ~= (mtInfo ~= nil and mtInfo.officer == true) then
		self:Debug("ignored %s from %s (wrong channel %s)", mtype, U.ShortName(sender), distribution)
		return
	end

	local isSelf = sender == self:MyName()
	if not isSelf then
		-- only guild members, using our own copy of the guild list
		if not self.rosterReady or not self:IsGuildMember(sender) then
			self:Debug("ignored %s from %s (not in our guild list)", mtype, sender)
			return
		end
	end

	-- A newer protocol: only HELLO and HB are promised to stay readable.
	if proto > self.PROTO and mtype ~= "HELLO" and mtype ~= "HB" then
		self:Debug("ignored %s from %s (newer protocol %d)", mtype, sender, proto)
		return
	end

	local handler = self.handlers[mtype]
	if not handler then
		self:Debug("ignored unknown type %s from %s", mtype, sender)
		return
	end
	if not self:TypeOn(mtype) then
		self:Debug("ignored %s from %s (that part is switched off)", mtype, U.ShortName(sender))
		return
	end

	local ok, data = self:Deserialize(body)
	if not ok or type(data) ~= "table" then
		self:Debug("ignored broken %s from %s", mtype, sender)
		return
	end

	self:Debug("< %s from %s%s (%d chars)", mtype, U.ShortName(sender), isSelf and " (your own echo)" or "", #text)

	if not isSelf then
		local u = self.addonUsers[sender] or {}
		u.seen = GetTime()
		self.addonUsers[sender] = u
		self:TouchMember(sender)
		if self.AltHeard then self:AltHeard(sender) end -- a recorded "own character" that talks isn't ours
	end

	local okCall, err = pcall(handler, self, sender, data, distribution, isSelf)
	if not okCall then
		self:Debug("|cffff6060error handling %s: %s|r", mtype, U.CleanText(tostring(err), 200) or "?")
	end
end

-- Online with Guild Hub = game says online and we heard from them in the last 11 minutes.
function GH:IsAddonUserOnline(name)
	if name == self:MyName() then return true end
	local u = self.addonUsers[name]
	return u ~= nil and self:IsOnline(name) and (GetTime() - (u.seen or 0)) < 660
end

-- "update available" once per session
function GH:NoteVersion(sender, version)
	version = U.ValidVersion(version)
	if not version then return end
	local u = self.addonUsers[sender]
	if u then u.version = version end
	-- players on a normal release are only told about newer releases, not about someone's beta
	local worthNoting = not U.IsPreRelease(version) or U.IsPreRelease(self.VERSION)
	if not self.updateNoted and worthNoting and U.CompareVersions(version, self.VERSION) > 0 then
		self.updateNoted = true
		self:Msg(L.UPDATE_AVAILABLE, version, self.VERSION)
	end
end

------------------------------------------------------------------------
-- Shared info about ourselves (used by HELLO and HB)
------------------------------------------------------------------------
function GH:SelfInfo()
	local m = self:UpdateSelf()
	-- group size (g, r) too, so players who log in learn it; v0.1.2 clients ignore these fields
	local g, r, gk = self:OwnGroupShare()
	if gk then self.lastGroupKey = gk end
	local info = {
		v = self.VERSION,
		class = m and m.class, level = m and m.level, ts = m and m.ts,
		inst = IsInInstance() and true or false,
		afk = self:PlayerAFK(), -- secret-safe (Status.lua)
		g = g, r = r and 1 or nil,
		-- 0.4.0-b2: "my map dot is still where it was" (Features\Map.lua); only through the same gate
		-- as POS itself (after the yes, out in the world, no lockdown)
		ps = (self.PosSharingNow and self:PosSharingNow()) and 1 or nil,
	}
	-- the bundle record (Features.lua): whole if HB still fits one piece, else only its hash.
	-- Older clients ignore both fields.
	local b = self.OwnBundle and self:OwnBundle()
	if b then
		info.b = b
		if #self:Serialize(info) + 12 > 254 then
			info.b = nil
			info.bh = self:BundleHash(b)
		end
	end
	return info
end

-- Store what HELLO/HB told us about the sender.
function GH:ReadSelfInfo(sender, data)
	self:NoteVersion(sender, data.v)
	local u = self.addonUsers[sender]
	if u then
		u.inst = data.inst == true
		u.grp = self:CleanGroup(data) -- nil from v0.1.2 clients or when they don't share it
	end
	local rec = self:CleanRecord({
		ts = data.ts, class = data.class, level = data.level, version = data.v, lastSeen = U.Now(),
	})
	if rec then self:MergeMember(sender, rec) end
	if type(data.b) == "table" and self.ReadBundle then self:ReadBundle(sender, data.b, true) end
	if self.MapReadHB then self:MapReadHB(sender, data.ps) end -- keeps (or drops) the sender's map dot
	self:RefreshBoard()
end

------------------------------------------------------------------------
-- HB: "I'm here" every 5 minutes
------------------------------------------------------------------------
function GH:SendHeartbeat()
	if not self.started then return end
	local gdb = self:GetGuildDB()
	if gdb then gdb.lastOnline = U.Now() end
	self:SendMsg("HB", self:SelfInfo())
	-- refresh for players who missed a change (e.g. they were in a dungeon); only if there is something
	if self:HasStatusToShare() then self:SendStatus() end
end

GH.handlers.HB = function(self, sender, data, _, isSelf)
	if isSelf then return end
	self:ReadSelfInfo(sender, data)
end

------------------------------------------------------------------------
-- CFG: guild settings, only from the Guild Master
------------------------------------------------------------------------
function GH:SetOfficerRank(rankIndex)
	local me = self:MyName()
	local gdb = self:GetGuildDB()
	if not gdb or not self:IsGuildMaster(me) then return end
	gdb.cfg = { officerMaxRank = rankIndex, ts = U.Now(), by = me }
	self:SendMsg("CFG", gdb.cfg)
	local names = self:GetRankNames()
	self:Msg(L.OPT_OFFICER_SET, names[rankIndex] or tostring(rankIndex))
end

-- Accept guild settings only if they were set by whoever is Guild Master in OUR guild list.
function GH:MergeCfg(cfg, sender)
	local gdb = self:GetGuildDB()
	if not gdb or type(cfg) ~= "table" then return end
	local by = U.ValidName(cfg.by)
	local ts = U.ValidTime(cfg.ts)
	local rank = U.ValidNumber(cfg.officerMaxRank, 0, 9)
	if not by or not ts or not rank then return end
	if sender and sender ~= by then return end
	if not self:IsGuildMaster(by) then
		self:Debug("ignored guild settings from %s (not the Guild Master)", by)
		return
	end
	if ts > (gdb.cfg.ts or 0) then
		gdb.cfg = { officerMaxRank = rank, ts = ts, by = by }
		self:Debug("guild settings updated: officer ranks 0-%d", rank)
	end
end

GH.handlers.CFG = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	self:MergeCfg(data, sender)
end

------------------------------------------------------------------------
-- TEST: "/ghub test big" - one long message to check splitting (only ever sent by hand)
------------------------------------------------------------------------
function GH:SendBigTest()
	if not IsInGuild() then return self:Msg(L.NOT_IN_GUILD) end
	if GetTime() - (self.lastSent.TEST or -1000) < MsgType("TEST").min then
		return self:Msg(L.TEST_WAIT)
	end
	local parts, n = {}, 0
	while n < 2000 do
		local chunk = ("GuildHub-test-%04d;"):format(n)
		parts[#parts + 1] = chunk
		n = n + #chunk
	end
	local s = tconcat(parts):sub(1, 2000)
	local data = { len = #s, sum = U.Checksum(s), s = s }
	local size = #self:Serialize(data) + 10
	self:Msg(L.TEST_SENDING, #s, math.ceil(size / 254))
	self:SendMsg("TEST", data, nil, "BULK")
end

GH.handlers.TEST = function(self, sender, data)
	local s = type(data.s) == "string" and data.s or ""
	if #s == data.len and U.Checksum(s) == data.sum then
		self:Msg(L.TEST_OK, U.ShortName(sender), #s)
	else
		self:Msg(L.TEST_BAD, U.ShortName(sender), #s, tonumber(data.len) or 0)
	end
end
