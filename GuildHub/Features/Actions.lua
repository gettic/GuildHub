-- Guild Hub: the name menu's actions (0.6.0-beta.3, plans\next-beta, tos: plans\next-beta\tos-check.md).
-- Waypoint, Show on map, Ask to join, Join me, Mute / Unmute. Every action runs ONLY inside the
-- player's own click (the name menu's click handler or a button), one action per click; nothing here
-- is called from a message, an event, a timer or the ticker. Nothing is sent as an addon message and
-- nothing is saved (cooldowns are memory only).
--   *State(name) -> ok, why, seconds   (why = a key of L.ACT_WHY: the greyed entry's reason)
--   the action itself re-checks its state and does nothing when it isn't ok.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local ACT_GAP = 60      -- Ask to join / Join me: one per target per 60 s (tos 2, 3)
local KEEP = 330        -- a position older than this is not used (= the map's KEEP_SECONDS; tos 1)
local PARTY_MAX, RAID_MAX = 5, 40
local ACTIVITY_FRESH = 3600
GH.ACT_GAP = ACT_GAP
-- self-test / tests: how often each action really ran
GH.actStats = { waypoint = 0, showMap = 0, ask = 0, askFallback = 0, join = 0 }
local actAt = {} -- ["ask:" .. name] / ["join:" .. name] = GetTime() of the last use (memory only)

local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local function OpenChatWith(text)
	local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
	if open then pcall(open, text) end
end

local function Cooldown(kind, name)
	local t = actAt[kind .. ":" .. name]
	if not t then return 0 end
	return math.max(0, ACT_GAP - (GetTime() - t))
end

-- for tests and /ghub selftest: drop all cooldowns
function GH:ActCooldownsClear() wipe(actAt) end

------------------------------------------------------------------------
-- Positions we may use (tos 1): a sharer's dot, while we share too, not ignored, < 330 s old
------------------------------------------------------------------------
function GH:UsablePosition(name)
	if type(name) ~= "string" then return nil, "unknown" end
	if not self:FeatureOn("map") then return nil, "mapoff" end
	local can, why = self:CanUse("pos")
	if not can then return nil, why == "trial" and "trial" or "share" end
	if self:IsIgnored(name) then return nil, "ignored" end
	local p = self.positions[name]
	if not p then return nil, "noshare" end
	if GetTime() - p.t > KEEP then return nil, "old" end
	return p
end

local function MapName(m)
	if not (C_Map and C_Map.GetMapInfo) then return nil end
	local ok, info = pcall(C_Map.GetMapInfo, m)
	local n = ok and type(info) == "table" and info.name
	if type(n) ~= "string" or U.IsSecret(n) or n == "" then return nil end
	return U.CleanText(n, 40)
end

------------------------------------------------------------------------
-- Waypoint (tos 1): Blizzard's one user waypoint + its arrow, a snapshot (never refreshed)
------------------------------------------------------------------------
function GH:WaypointState(name)
	if type(name) ~= "string" then return false, "unknown" end
	if self:IsMyChar(name) then return false, "self" end
	if InCombat() then return false, "combat" end
	local p, why = self:UsablePosition(name)
	if not p then return false, why end
	if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then return false, "api" end
	if C_Map.CanSetUserWaypointOnMap then
		local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, p.m)
		if not ok or U.IsSecret(can) or not can then return false, "nowp" end -- a secret is never tested
	end
	return true
end

function GH:WaypointTo(name)
	if not self:WaypointState(name) then return false end
	local p = self.positions[name]
	local okP, point = pcall(UiMapPoint.CreateFromCoordinates, p.m, p.x, p.y)
	if not okP or not point then return false end
	if not pcall(C_Map.SetUserWaypoint, point) then return false end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
	self.actStats.waypoint = self.actStats.waypoint + 1
	-- tos 1: our own chat frame only, with the "Guild Hub:" prefix
	self:Msg(L.ACT_WP_SET, U.ShortName(name), MapName(p.m) or "?", math.floor(p.x * 100 + 0.5), math.floor(p.y * 100 + 0.5))
	return true
end

------------------------------------------------------------------------
-- Show on map: opens Blizzard's world map (out of combat only, tos 5) on their zone; with a dot we
-- may see, our own map pulses it (local only). No hooks or child frames on WorldMapFrame.
------------------------------------------------------------------------
-- The map to open for this player: their dot's map, else their guild-list zone (an instance zone =
-- the zone with its entrance). Returns uiMapID, hasDot.
function GH:ShowOnMapTarget(name)
	if name == self:MyName() then
		local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
		if type(m) == "number" and not U.IsSecret(m) then return m, false end
		return nil
	end
	local p = self:UsablePosition(name)
	if p then return p.m, true end
	local r = self.roster[name]
	local zone = r and r.zone
	if type(zone) ~= "string" or U.IsSecret(zone) or zone == "" then return nil end
	local m = self.ZoneMapID and self:ZoneMapID(zone)
	if m then return m, false end
	local short = self.DungeonShortFor and self.DungeonShortFor(self, name, zone)
	local e = short and self.ENTRANCE_BY_SHORT and self.ENTRANCE_BY_SHORT[short]
	if e then return e.m, false end
	return nil
end

function GH:ShowOnMapState(name)
	if type(name) ~= "string" then return false, "unknown" end
	if type(_G.OpenWorldMap) ~= "function" then return false, "api" end
	if InCombat() then return false, "combat" end
	if name ~= self:MyName() then
		if self:IsIgnored(name) then return false, "ignored" end
		if not self:IsOnline(name) then return false, "offline" end
	end
	if not self:ShowOnMapTarget(name) then return false, "nozone" end
	return true
end

function GH:ShowOnMap(name)
	if not self:ShowOnMapState(name) then return false end
	local m, hasDot = self:ShowOnMapTarget(name)
	if not pcall(_G.OpenWorldMap, m) then
		self:Msg(L.ACT_MAP_FAILED) -- tos 5: if it fails, the player opens the map with M
		return false
	end
	self.actStats.showMap = self.actStats.showMap + 1
	if hasDot and self.MapPulse then self:MapPulse(name) end
	return true
end

-- The Map tab's "Open world map" button (out of combat).
function GH:OpenTheWorldMap()
	if InCombat() then self:Msg(L.ACT_NOT, L.ACT_WHY.combat) return false end
	local fn = _G.ToggleWorldMap
	if type(fn) ~= "function" or not pcall(fn) then self:Msg(L.ACT_MAP_FAILED) return false end
	self.actStats.showMap = self.actStats.showMap + 1
	return true
end

------------------------------------------------------------------------
-- Ask to join (tos 2): Blizzard's own group request, only when we KNOW they are in a group that has room,
-- not in an instance, we are on our own, not ignored; one per target per 60 s.
------------------------------------------------------------------------
-- Are they in a dungeon or raid right now? (a fresh status, or an instance zone in the guild list)
function GH:MemberInInstance(name)
	local gdb = self:GetGuildDB()
	local m = gdb and gdb.members and gdb.members[name]
	local s = m and m.status
	if type(s) == "table" and (s.a == "dng" or s.a == "raid") and type(s.ts) == "number"
		and U.Now() - s.ts < ACTIVITY_FRESH then return true end
	local r = self.roster[name]
	local zone = r and r.zone
	if type(zone) == "string" and not U.IsSecret(zone) and self.INSTANCE_BY_NAME[zone] then return true end
	return false
end

function GH:AskToJoinState(name)
	if type(name) ~= "string" then return false, "unknown" end
	if self:IsMyChar(name) then return false, "self" end
	if not (C_PartyInfo and C_PartyInfo.RequestInviteFromUnit) then return false, "api" end
	if InCombat() then return false, "combat" end
	if self:IsIgnored(name) then return false, "ignored" end
	if not self:IsOnline(name) then return false, "offline" end
	local own = self:GroupInfo()
	if own and own > 0 then return false, "ingroup" end
	if self:MemberInInstance(name) then return false, "instance" end
	-- we only know their group size when both share it (fair trade)
	if not self:CanUse("group") then return false, "grpshare" end
	local u = self.addonUsers and self.addonUsers[name]
	local g = u and u.grp
	if not g then return false, "grpunknown" end
	if g.g < 2 then return false, "nogroup" end
	if g.g >= (g.r and RAID_MAX or PARTY_MAX) then return false, "full" end
	local left = Cooldown("ask", name)
	if left > 0 then return false, "wait", math.ceil(left) end
	return true
end

function GH:AskToJoin(name)
	if not self:AskToJoinState(name) then return false end
	local target = U.WhisperName(name)
	actAt["ask:" .. name] = GetTime()
	self.lastAsk = { target = target, time = GetTime() }
	self.actStats.ask = self.actStats.ask + 1
	local fallbacks = self.actStats.askFallback
	if not pcall(C_PartyInfo.RequestInviteFromUnit, target) then
		self:AskFallback()
		return true
	end
	-- blocked (ADDON_ACTION_BLOCKED during the call) = the fallback already said so: one chat line only
	if self.actStats.askFallback == fallbacks then self:Msg(L.ACT_ASK_SENT, U.ShortName(name)) end
	return true
end

-- Blocked or failed: Blizzard's own slash goes into the chat box; the player presses Enter. No send,
-- no retry (tos 2).
function GH:AskFallback()
	local a = self.lastAsk
	self.lastAsk = nil
	if not a or GetTime() - a.time > 3 then return end
	self.actStats.askFallback = self.actStats.askFallback + 1
	local slash = type(_G.SLASH_REQUESTINVITE1) == "string" and _G.SLASH_REQUESTINVITE1 or "/requestinvite"
	OpenChatWith(slash .. " " .. a.target)
	self:Msg(L.ACT_ASK_FALLBACK)
end

------------------------------------------------------------------------
-- Join me (tos 3): fills a whisper to that ONE guildmate with your OWN zone (and spot when known);
-- the player presses Enter. One per target per 60 s.
------------------------------------------------------------------------
function GH:JoinMeText()
	local zone = self.LiveZone and self:LiveZone()
	if type(zone) ~= "string" or U.IsSecret(zone) or zone == "" then return nil end
	zone = U.CleanText(zone, 40)
	local m, x, y = self:OwnPosition()
	if m then return L.ACT_JOIN_TEXT_AT:format(zone, math.floor(x * 100 + 0.5), math.floor(y * 100 + 0.5)) end
	return L.ACT_JOIN_TEXT:format(zone)
end

function GH:JoinMeState(name)
	if type(name) ~= "string" then return false, "unknown" end
	if self:IsMyChar(name) then return false, "self" end
	if IsInInstance() then return false, "meinst" end
	if self:IsIgnored(name) then return false, "ignored" end
	if not self:IsOnline(name) then return false, "offline" end
	if not self:JoinMeText() then return false, "nozone" end
	local left = Cooldown("join", name)
	if left > 0 then return false, "wait", math.ceil(left) end
	return true
end

function GH:JoinMe(name)
	if not self:JoinMeState(name) then return false end
	local text = self:JoinMeText()
	local target = U.WhisperName(name)
	actAt["join:" .. name] = GetTime()
	self.actStats.join = self.actStats.join + 1
	local fill = ChatFrameUtil and ChatFrameUtil.SendTellWithMessage
	if not (fill and pcall(fill, target, text)) then OpenChatWith("/w " .. target .. " " .. text) end
	return true
end

------------------------------------------------------------------------
-- I can help (1.0.0-beta.1; tos plans\next-beta-2\tos-check.md item 3): fills a whisper to that ONE
-- guildmate who needs help, quoting their note; the player presses Enter. One per target per 60 s.
------------------------------------------------------------------------
local LINE_MAX = 255 -- bytes in one chat line

-- Their note without any escape or link code (|c |r |H |h |T |t |A |a |K |k |n ...), and no "|" left.
function GH.StripCodes(s)
	if type(s) ~= "string" or U.IsSecret(s) then return nil end
	s = s:gsub("|H.-|h(.-)|h", "%1")   -- a link: keep its shown text
	s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|K.-|k", "")
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " ")
	s = s:gsub("|%a", ""):gsub("|", "")
	s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
	return s ~= "" and s or nil
end

-- Cut to at most n bytes without splitting a UTF-8 letter.
local function CutBytes(s, n)
	if #s <= n then return s end
	s = s:sub(1, n)
	local i = #s
	while i > 0 do
		local b = s:byte(i)
		if b < 0x80 then break end          -- plain letter: the end is whole
		if b >= 0xC0 then                    -- start of a letter: whole only if all its bytes are there
			local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
			if #s - i + 1 < need then s = s:sub(1, i - 1) end
			break
		end
		i = i - 1
	end
	return s
end
GH.CutBytes = CutBytes

-- Their fresh Need-help status, or nil.
local function NeedsHelp(gh, name)
	local gdb = gh:GetGuildDB()
	local m = gdb and gdb.members and gdb.members[name]
	local s = type(m) == "table" and m.status
	if type(s) == "table" and s.p == "help" and gh:IsStatusFresh(s) then return s end
	return nil
end
GH.NeedsHelpStatus = function(gh, name) return NeedsHelp(gh, name) end

function GH:CanHelpText(name)
	local s = NeedsHelp(self, name)
	local note = s and self.StripCodes(s.t)
	local text = note and L.CANHELP_TEXT:format(note) or L.CANHELP_PLAIN
	return CutBytes(text, LINE_MAX)
end

function GH:CanHelpState(name)
	if type(name) ~= "string" then return false, "unknown" end
	if self:IsMyChar(name) then return false, "self" end
	if self.IsIgnored and self:IsIgnored(name) then return false, "ignored" end
	if self:IsMuted(name) then return false, "muted" end
	if not self:IsOnline(name) then return false, "offline" end
	if not NeedsHelp(self, name) then return false, "notneed" end
	local left = Cooldown("help", name)
	if left > 0 then return false, "wait", math.ceil(left) end
	return true
end

function GH:CanHelp(name)
	if not self:CanHelpState(name) then return false end
	local text = self:CanHelpText(name)
	local target = U.WhisperName(name)
	actAt["help:" .. name] = GetTime()
	self.actStats.help = (self.actStats.help or 0) + 1
	local fill = ChatFrameUtil and ChatFrameUtil.SendTellWithMessage
	if not (fill and pcall(fill, target, text)) then OpenChatWith("/w " .. target .. " " .. text) end
	if self.RefreshBoard then self:RefreshBoard() end -- the row's button greys for the wait
	return true
end

-- The greyed button's tooltip (row, note): the reason.
function GH:CanHelpTooltip(owner, name)
	GameTooltip:SetOwner(owner, "ANCHOR_TOP")
	GameTooltip:AddLine(L.BTN_CANHELP, 1, 0.82, 0)
	GameTooltip:AddLine(L.CANHELP_TIP, 1, 1, 1, true)
	local ok, why, secs = self:CanHelpState(name)
	if not ok then GameTooltip:AddLine((L.ACT_WHY[why] or why):format(secs or 0), 1, 0.3, 0.3, true) end
	GameTooltip:Show()
end

------------------------------------------------------------------------
-- Mute alerts from someone (Status.lua GH:Mute) and the way back
------------------------------------------------------------------------
function GH:Unmute(name)
	local muted = self.db and self.db.profile.alerts.muted
	if not (name and muted and muted[name]) then return end
	muted[name] = nil
	self:Msg(L.ACT_UNMUTED, U.ShortName(name))
	self:RefreshBoard()
end

------------------------------------------------------------------------
-- 1.0.0-beta.2 (N6): Promote / Demote / Remove from guild in the name menu's officer section
-- (tos plans\next-beta-3\tos-check.md): each entry ONLY fills the chat box with the game's own
-- command ("/gpromote Name") through ChatFrameUtil.OpenChat; the officer presses Enter. Never
-- ChatEdit_SendText, never C_GuildInfo.Promote/Demote/Uninvite or GuildPromote/GuildDemote/
-- GuildUninvite. One name per click. Greyed with a reason when the rank can't (the game's own
-- CanGuildPromote/CanGuildDemote/CanGuildRemove, as Blizzard's GuildRoster.lua) or the command is
-- missing on this server (SLASH_GUILD_PROMOTE1 ...). NameMenu.lua builds the officer section only
-- for officers on non-officer members.
------------------------------------------------------------------------
GH.actStats.rank = 0
local RANK_CMDS = {
	promote = { slash = "SLASH_GUILD_PROMOTE1", can = "CanGuildPromote" },
	demote  = { slash = "SLASH_GUILD_DEMOTE1", can = "CanGuildDemote" },
	remove  = { slash = "SLASH_GUILD_UNINVITE1", can = "CanGuildRemove" },
}
GH.RANK_CMDS = RANK_CMDS

-- The command text, or nil when the server has no such command.
function GH:RankCommandText(kind, name)
	local c = RANK_CMDS[kind]
	local slash = c and _G[c.slash]
	if type(slash) ~= "string" or slash == "" or type(name) ~= "string" or name == "" then return nil end
	return slash .. " " .. U.WhisperName(name)
end

-- ok, why ("combat" / "noslash" / "rank" / "highest" / "lowest" / "self" / "notmember").
function GH:RankActionState(kind, name)
	local c = RANK_CMDS[kind]
	if not c then return false, "api" end
	if InCombat() then return false, "combat" end
	if not self:RankCommandText(kind, name) then return false, "noslash" end
	if self:IsMyChar(name) then return false, "self" end
	local r, me = self.roster[name], self.roster[self:MyName()]
	if not (r and me) then return false, "notmember" end
	local can = _G[c.can]
	local ok, allowed = false, false
	if type(can) == "function" then ok, allowed = pcall(can) end
	if not ok or U.IsSecret(allowed) or not allowed then return false, "rank_" .. kind end
	local their, mine = r.rankIndex, me.rankIndex
	if type(their) ~= "number" or type(mine) ~= "number" or their <= mine then return false, "rank_" .. kind end
	if kind == "promote" and their <= mine + 1 then return false, "highest" end
	if kind == "demote" then
		local n = GuildControlGetNumRanks and GuildControlGetNumRanks()
		if type(n) == "number" and not U.IsSecret(n) and their >= n - 1 then return false, "lowest" end
	end
	return true
end

-- One click: the command goes into the chat box, nothing is sent.
function GH:RankAction(kind, name)
	if not self:RankActionState(kind, name) then return false end
	local text = self:RankCommandText(kind, name)
	self.actStats.rank = self.actStats.rank + 1
	OpenChatWith(text)
	return true
end

-- The nameMenu "officer" hook entries (Status.lua registers it on the core status feature).
function GH:RankMenuEntries(name)
	local e = {}
	for _, kind in ipairs({ "promote", "demote", "remove" }) do
		local ok, why = self:RankActionState(kind, name)
		e[#e + 1] = { key = kind, text = L["MENU_" .. kind:upper()], ok = ok and true or false,
			why = not ok and (L.ACT_WHY[why] or why) or nil, red = kind == "remove" or nil,
			run = function() GH:RankAction(kind, name) end }
	end
	return e
end
