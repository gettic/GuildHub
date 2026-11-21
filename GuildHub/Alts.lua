-- Guild Hub: your own characters (alts) on this account.
-- Saved account-wide in GuildHubDB.global.account.chars = { ["Name Suffix-Realm"] = { ts, g, c } }.
-- LOCAL ONLY: nothing from this table is ever put into an addon message (tos condition). It is used
-- so the Professions tab, search, popup and tooltips never offer to whisper or ask yourself.
local _, ns = ...
local GH, U = ns.GH, ns.Util

local KEEP_DAYS      = 365 -- a character not logged in for a year is forgotten
local GONE_SECONDS   = 60  -- not in the guild list this long -> its guild is cleared (entry kept)
local LOGIN_GRACE    = 30  -- after login, "seen online" is ignored (the guild list can still show the
                           -- character you just logged off)
local ONLINE_CONFIRM = 30  -- the guild list must still show it online this much later
local MAX_CHARS      = 200
GH.ALT_CAPS = { KEEP_DAYS = KEEP_DAYS, GONE_SECONDS = GONE_SECONDS, LOGIN_GRACE = LOGIN_GRACE,
	ONLINE_CONFIRM = ONLINE_CONFIRM, MAX_CHARS = MAX_CHARS }

GH.altLoginAt = GetTime and GetTime() or 0 -- this file loads at login / reload
GH.altOnlineSince, GH.altGoneSince, GH.altForgotten = {}, {}, 0

local function Finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- Repair of the saved table (no self: RepairSaved also runs on copies). Returns true if it changed something.
function GH.CleanAccountData(g)
	if type(g) ~= "table" then return false end
	local a = rawget(g, "account")
	if a == nil then return false end
	local fixed = false
	if type(a) ~= "table" then
		g.account = { chars = {} }
		return true
	end
	if type(a.chars) ~= "table" then
		a.chars, fixed = {}, a.chars ~= nil
	end
	local n, list = 0, {}
	for k, v in pairs(a.chars) do
		if type(k) ~= "string" or not U.ValidName(k) or type(v) ~= "table" then
			a.chars[k] = nil -- clearing a field during pairs() is allowed in Lua
			fixed = true
		else
			if not Finite(v.ts) then v.ts, fixed = 0, true end
			if v.g ~= nil and type(v.g) ~= "string" then v.g, fixed = nil, true end
			if v.c ~= nil and type(v.c) ~= "string" then v.c, fixed = nil, true end
			n = n + 1
			list[n] = k
		end
	end
	if n > MAX_CHARS then -- keep the newest
		table.sort(list, function(x, y) return a.chars[x].ts > a.chars[y].ts end)
		for i = MAX_CHARS + 1, n do a.chars[list[i]] = nil end
		fixed = true
	end
	return fixed
end

local function Account(create)
	local g = GH.db and GH.db.global
	if type(g) ~= "table" then return nil end
	if not GH.altsChecked then
		GH.altsChecked = true
		if GH.CleanAccountData(g) then GH:Debug("repaired saved own-character list") end
	end
	local a = rawget(g, "account")
	if type(a) ~= "table" then
		if not create then return nil end
		a = { chars = {} }
		g.account = a
	end
	return a
end

-- The own-character table (nil before the first login is recorded).
function GH:OwnChars()
	local a = Account(false)
	return a and a.chars or nil
end

-- The current character or one recorded on this account.
function GH:IsMyChar(name)
	if type(name) ~= "string" then return false end
	if name == self:MyName() then return true end
	local chars = self:OwnChars()
	return chars ~= nil and chars[name] ~= nil
end

-- Another character of this account (not the one logged in).
function GH:IsMyAlt(name)
	return type(name) == "string" and name ~= self:MyName() and self:IsMyChar(name)
end

-- Records the current character (login, guild change). Local only.
function GH:NoteOwnChar()
	local me = self:MyName()
	if not me then return end
	local a = Account(true)
	if not a then return end
	local e = a.chars[me]
	if type(e) ~= "table" then
		e = {}
		a.chars[me] = e
		self:Debug("recorded this character as one of yours")
	end
	e.ts = U.Now()
	local _, class = UnitClass("player")
	if type(class) == "string" and not U.IsSecret(class) then e.c = class end
	e.g = self:GuildKey()
	self.altOnlineSince[me], self.altGoneSince[me] = nil, nil
end

local function Forget(name, why)
	local chars = GH:OwnChars()
	if not chars or chars[name] == nil then return end
	chars[name] = nil
	GH.altOnlineSince[name], GH.altGoneSince[name] = nil, nil
	GH.altForgotten = GH.altForgotten + 1
	GH:Debug("%s is not one of your characters (%s)", U.ShortName(name), why)
	GH.profDirty = true
	if GH.RefreshProfTab then GH:RefreshProfTab() end
end

local function InGrace() return GetTime() - (GH.altLoginAt or 0) < LOGIN_GRACE end

-- A message really came from this name: one account can't have two characters online, so a
-- recorded name that talks while we're logged in isn't ours (deleted, name taken by someone else).
function GH:AltHeard(sender)
	if InGrace() or not self:IsMyAlt(sender) then return end
	Forget(sender, "sent a message")
end

-- From RebuildRoster: online in the guild list (twice, 30 s apart, after the login grace) -> forgotten;
-- recorded in this guild but gone from its list for 60 s -> guild cleared (the character is still yours).
function GH:AltRosterCheck(roster)
	local chars = self:OwnChars()
	if not chars or type(roster) ~= "table" or next(roster) == nil then return end
	local me, gk, t = self:MyName(), self:GuildKey(), GetTime()
	local grace = InGrace()
	local drop = {}
	for name, e in pairs(chars) do
		if name ~= me then
			local r = roster[name]
			if r and r.online and not grace then
				local since = self.altOnlineSince[name]
				if not since then
					self.altOnlineSince[name] = t
				elseif t - since >= ONLINE_CONFIRM then
					drop[#drop + 1] = name
				end
			else
				self.altOnlineSince[name] = nil
			end
			if gk and e.g == gk and not r then
				local gone = self.altGoneSince[name]
				if not gone then
					self.altGoneSince[name] = t
				elseif t - gone >= GONE_SECONDS then
					e.g = nil
					self.altGoneSince[name] = nil
					self:Debug("%s left the guild (still your character)", U.ShortName(name))
				end
			else
				self.altGoneSince[name] = nil
			end
		end
	end
	for _, name in ipairs(drop) do Forget(name, "online in the guild list") end
end

-- From Prune: characters not logged in for a year.
function GH:PruneOwnChars()
	local chars = self:OwnChars()
	if not chars then return 0 end
	local me, cutoff, n = self:MyName(), U.Now() - KEEP_DAYS * 86400, 0
	for name, e in pairs(chars) do
		if name ~= me and (e.ts or 0) < cutoff then
			chars[name] = nil
			n = n + 1
		end
	end
	return n
end

-- Self-test: problems + one info line (no names).
function GH:AltSelfTest()
	local problems, chars = {}, self:OwnChars()
	if not chars or not chars[self:MyName() or ""] then problems[#problems + 1] = "this character is not recorded" end
	if not self:IsMyChar(self:MyName()) then problems[#problems + 1] = "IsMyChar(self) is false" end
	local n, here, onlineNow = 0, 0, 0
	local gk = self:GuildKey()
	for name, e in pairs(chars or {}) do
		n = n + 1
		if gk and e.g == gk then here = here + 1 end
		if name ~= self:MyName() and self:IsOnline(name) then onlineNow = onlineNow + 1 end
	end
	return problems, ("alts n=%d inGuild=%d onlineNow=%d forgotten=%d"):format(n, here, onlineNow, self.altForgotten or 0)
end
