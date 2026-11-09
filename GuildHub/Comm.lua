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

-- Shortest time between two messages of the same type (seconds). A message sent sooner
-- is held back and only the newest one goes out when the time is up.
local MIN_INTERVAL = {
	HELLO   = 30,
	HB      = 60,
	CFG     = 10,
	TEST    = 10,
	STATUS  = 10,
	GRP     = 15, -- group size; also waits for 2 s without roster changes (Status.lua)
	SYNCING = 0,
	SYNC    = 0,
}
-- Kept and sent later when a boss fight / PvP match blocks messages.
local KEEP_IN_LOCKDOWN = { HELLO = true, HB = true, CFG = true, STATUS = true, GRP = true }

local MAX_INCOMING = 30000 -- characters; anything bigger is dropped

GH.handlers  = {}  -- [TYPE] = function(self, sender, data, distribution)
GH.addonUsers = {} -- ["Name-Realm"] = { seen = GetTime(), version, inst }
GH.lastSent  = {}
GH.held      = {}

function GH:InitComm()
	self:RegisterComm(self.PREFIX, "OnCommReceived")
	if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid("ADDON_RESTRICTION_STATE_CHANGED") then
		self:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", "FlushHeld")
	end
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
	if self.cannotSend or not IsInGuild() then return end
	local key = target and (mtype .. ":" .. target) or mtype

	-- pacing per type
	local wait = (MIN_INTERVAL[mtype] or 5) - (GetTime() - (self.lastSent[key] or -1000))
	if wait > 0 then
		local h = self.held[key]
		local timer = h and h.timer or self:ScheduleTimer("SendHeld", wait + 0.1, key)
		self.held[key] = { mtype, data, target, prio, timer = timer }
		return
	end

	-- boss fight / PvP match: keep the important ones, drop the rest
	if self:InLockdown() then
		if KEEP_IN_LOCKDOWN[mtype] then
			self.held[key] = { mtype, data, target, prio, lockdown = true }
			if not self.lockdownTimer then
				self:Debug(L.LOCKDOWN_PAUSED)
				self.lockdownTimer = self:ScheduleRepeatingTimer("FlushHeld", 5)
			end
		else
			self:Debug("dropped %s (messages are paused)", mtype)
		end
		return
	end

	local text = tconcat({ self.PROTO, mtype, self:Serialize(data) }, "\t")
	local channel = target and "WHISPER" or "GUILD"
	self.lastSent[key] = GetTime()
	self:Debug("> %s to %s (%d chars, %d pieces)", mtype, target and U.ShortName(target) or "guild",
		#text, math.ceil(#text / 254))
	-- whisper to "Mira Ashford", not "Mira Ashford-Realm" (WoW Forever names); info keeps the key
	self:SendCommMessage(self.PREFIX, text, channel, target and U.WhisperName(target), prio or "NORMAL", self.OnSendResult,
		{ mtype = mtype, target = target })
end

-- Called by AceComm for each piece: (arg, bytesSent, bytesTotal, didSend)
function GH.OnSendResult(info, sent, total, didSend)
	if didSend == false then
		GH:OnSendFailed(info)
	elseif sent == total then
		GH:Debug("  %s sent OK", info.mtype)
	end
end

function GH:OnSendFailed(info)
	local why
	if self:InLockdown() then
		why = "messages are paused (boss fight or PvP match)"
	elseif not IsInGuild() then
		why = "not in a guild"
	elseif self:IsTrial() then
		why = "trial account"
		self:CheckTrialAccount()
	elseif info.target and not self:IsOnline(info.target) then
		why = "player went offline"
	else
		why = "the game refused it"
	end
	self:Debug("|cffff6060%s was NOT sent: %s|r", info.mtype, why)
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
	if self.lockdownTimer then
		self:CancelTimer(self.lockdownTimer)
		self.lockdownTimer = nil
	end
	for key, h in pairs(self.held) do
		if h.lockdown then
			self.held[key] = nil
			self:SendMsg(h[1], h[2], h[3], h[4])
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
	if distribution ~= "GUILD" and distribution ~= "WHISPER" then
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
	if not self.updateNoted and U.CompareVersions(version, self.VERSION) > 0 then
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
	return {
		v = self.VERSION,
		class = m and m.class, level = m and m.level, ts = m and m.ts,
		inst = IsInInstance() and true or false,
		afk = UnitIsAFK("player") and true or false,
		g = g, r = r and 1 or nil,
	}
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
	if GetTime() - (self.lastSent.TEST or -1000) < MIN_INTERVAL.TEST then
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
