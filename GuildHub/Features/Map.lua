-- Guild Hub: the guild map (0.4.0-beta.2). Feature "map", switchable.
--
-- Positions (POS) are sent ONLY after the player said yes on the welcome card (or in Settings >
-- What I share), only out in the world (never in dungeons, raids, battlegrounds), never during a
-- boss fight / lockdown or combat, at most one per 12 s and only when the player moved. GUILD
-- broadcast only. Positions are kept in memory only (GH.positions): never saved, never synced.
-- Fair trade (Features.lua): only a player who shares their own position sees guildmates' dots.
-- Zone counts (UI\MapPins.lua) come from Blizzard's own guild list zone, numbers only.
-- The dots themselves are drawn by UI\MapPins.lua (HereBeDragons).
-- 0.6.0 (plans\map-extras): hidden while AFK (setting, default on), "Find me" (a POS with f = 1,
-- click only, one per 30 s; receivers: pulse + at most one chat line per sender per 2 min), the
-- welcome card's "Zone only" (= the lasting no). Dungeon labels: Features\MapDungeons.lua.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local POS_SECONDS = 12     -- the message type's minimum gap (tos: at most one per 12 s)
local TICK_SECONDS = 13    -- the job's rhythm: a little over the gap, so a send the chat queue held back
                           -- for a moment never lands closer than 12 s to the next one
local KEEP_SECONDS = 330   -- a dot without POS / HB "ps" for this long is removed (HB comes every 300 s)
local CHECK_SECONDS = 30   -- expiry check
local MOVE_MIN = 0.002     -- of the zone's width/height (a few yards)
local ROUND = 1000         -- 3 decimals
local OFF_GAP = 3          -- seconds between two "off" messages (they skip the 12 s gap)
local WELCOME_DELAY = 10   -- seconds after start-up
local FIND_SECONDS = 30    -- 0.6.0 "Find me": at most one per 30 s (tos), click only
local FIND_LINE_SECONDS = 120 -- receiver: at most one chat line per sender per 2 minutes (tos b)
local FIND_WAIT_SECONDS = 60  -- a line that arrived in combat is shown after combat if still this fresh
GH.MAP_POS_SECONDS, GH.MAP_KEEP_SECONDS = POS_SECONDS, KEEP_SECONDS
GH.MAP_FIND_SECONDS, GH.MAP_FIND_LINE_SECONDS = FIND_SECONDS, FIND_LINE_SECONDS

-- Enum.UIMapType values (from the game when there)
local function MapTypes()
	local e = Enum and Enum.UIMapType
	return {
		continent = e and e.Continent or 2, zone = e and e.Zone or 3,
		dungeon = e and e.Dungeon or 4, micro = e and e.Micro or 5,
	}
end

GH.positions = {}  -- [name] = { m, x, y, t } other players' dots: memory only, never saved
GH.posStats = { sent = 0, offSent = 0, beforeYes = 0, inInstance = 0, inCombat = 0, inAfk = 0, minGap = nil, last = nil }
-- Find me (self-test): sent / sent without sharing / smallest gap; got = pulses received, lines = chat lines shown
GH.findStats = { sent = 0, noShare = 0, minGap = nil, last = nil, got = 0, lines = 0 }
local SHARE = { ask = true, yes = true, no = true }

------------------------------------------------------------------------
-- The player's answer (per character): "ask" (default) / "yes" / "no"
------------------------------------------------------------------------
function GH:MapShareAnswer()
	local c = self.db and self.db.char
	local v = c and c.mapShare
	return SHARE[v] and v or "ask"
end

-- "yes" = share; "no" = a real no (the card stops asking); "ask" = ask again next login.
function GH:SetMapShare(v)
	if not SHARE[v] or not (self.db and self.db.char) then return end
	local old = self:MapShareAnswer()
	self.db.char.mapShare = v
	if v == "yes" then
		self.posLast = nil
		if old ~= "yes" and self:FeatureOn("map") then self:PosTick() end
	else
		self:SendPosOff()
		wipe(self.positions) -- fair trade: no dots for someone who doesn't share
	end
	if self.MapRedraw then self:MapRedraw() end
	if self.optionsChanged then self:optionsChanged() end
end

------------------------------------------------------------------------
-- Where are we? (open world only)
------------------------------------------------------------------------
local mapOk = {} -- [uiMapID] = true / false (cache)

-- An open-world zone (or a cave/building inside one): walks up to the continent. Dungeon maps and
-- anything without a continent above it are not.
function GH:OpenWorldMap(m)
	if type(m) ~= "number" or U.IsSecret(m) or m <= 0 or m ~= math.floor(m) then return false end
	if mapOk[m] ~= nil then return mapOk[m] end
	local T = MapTypes()
	local ok = false
	if C_Map and C_Map.GetMapInfo then
		local id, first = m, true
		for _ = 1, 8 do
			local okI, info = pcall(C_Map.GetMapInfo, id)
			if not okI or type(info) ~= "table" then break end
			local t = info.mapType
			if first and t ~= T.zone and t ~= T.micro then break end
			if t == T.dungeon then break end
			if t == T.continent then ok = true break end
			first = false
			if type(info.parentMapID) ~= "number" or info.parentMapID == 0 then break end
			id = info.parentMapID
		end
	end
	mapOk[m] = ok
	return ok
end

local function Round(v) return math.floor(v * ROUND + 0.5) / ROUND end

-- Own position: uiMapID, x, y (0-1), or nil (instance, boat, unknown map, secret value).
function GH:OwnPosition()
	local ok, m, x, y = pcall(function()
		local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
		local px, py, pm
		if HBD then px, py, pm = HBD:GetPlayerZonePosition() end
		if not pm and C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
			pm = C_Map.GetBestMapForUnit("player")
			if type(pm) == "number" and not U.IsSecret(pm) then
				local v = C_Map.GetPlayerMapPosition(pm, "player")
				if v and v.GetXY then px, py = v:GetXY() end
			end
		end
		return pm, px, py
	end)
	if not ok then return nil end
	-- tos: secret values are never sent
	if U.IsSecret(m) or U.IsSecret(x) or U.IsSecret(y) then return nil end
	if type(m) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then return nil end
	if x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
	if not self:OpenWorldMap(m) then return nil end
	return m, Round(x), Round(y)
end

------------------------------------------------------------------------
-- The send gate (used by Comm.lua before queueing AND before the real send)
------------------------------------------------------------------------
-- 0.6.0: AFK with "Hide my dot while AFK" on (the default).
function GH:PosAfkHidden()
	local p = self.db and self.db.profile
	return p ~= nil and p.mapHideAfk ~= false and UnitIsAFK ~= nil and UnitIsAFK("player") and true or false
end

-- Not in an instance, no lockdown, no combat, not hidden while AFK. Returns ok, why.
function GH:PosCanSend()
	if IsInInstance() then return false, "instance" end
	if self:InLockdown() then return false, "lockdown" end
	if InCombatLockdown and InCombatLockdown() then return false, "combat" end
	if self.cannotSend then return false, "trial" end
	if self:PosAfkHidden() then return false, "afk" end
	return true
end

-- Sharing right now (also the HB "ps" flag): the yes, the feature on, the gate open, a dot out.
function GH:PosSharingNow()
	return self:FeatureOn("map") and self:MapShareAnswer() == "yes" and self.posOn == true
		and (self:PosCanSend()) and true or false
end

local function PosGate(gh, data, target)
	if target ~= nil then return false end                       -- GUILD broadcast only
	if type(data) == "table" and data.off == 1 then return true end -- "my dot is gone" is always fine
	if gh:MapShareAnswer() ~= "yes" then return false end
	return (gh:PosCanSend())
end

-- Privacy counters at the real send (self-test): must stay 0 / >= 12 s.
local function OnPosSent(gh, item)
	local st = gh.posStats
	local data = item.data
	if type(data) == "table" and data.off == 1 then
		st.offSent = st.offSent + 1
		return
	end
	st.sent = st.sent + 1
	-- only now is our dot really out: the spot it shows and the HB "ps" flag (a POS dropped on the way
	-- leaves neither, so the next tick sends again and a "no" sends no needless "off")
	if type(data) == "table" then gh.posLast = { m = data.m, x = data.x, y = data.y } end
	gh.posOn = true
	if gh:MapShareAnswer() ~= "yes" then st.beforeYes = st.beforeYes + 1 end
	if IsInInstance() then st.inInstance = st.inInstance + 1 end
	if InCombatLockdown and InCombatLockdown() then st.inCombat = st.inCombat + 1 end
	if gh:PosAfkHidden() then st.inAfk = st.inAfk + 1 end
	local now = GetTime()
	if st.last then
		local gap = now - st.last
		if not st.minGap or gap < st.minGap then st.minGap = gap end
	end
	st.last = now
	if type(data) == "table" and data.f == 1 then
		local fs = gh.findStats
		fs.sent = fs.sent + 1
		if gh:MapShareAnswer() ~= "yes" then fs.noShare = fs.noShare + 1 end
		if fs.last then
			local gap = now - fs.last
			if not fs.minGap or gap < fs.minGap then fs.minGap = gap end
		end
		fs.last = now
	end
end

-- A "Find me" POS still waiting (held for the 12 s gap, or queued for room)?
local function FindWaiting(gh)
	local h = gh.held and gh.held.POS
	if h and type(h[2]) == "table" and h[2].f == 1 then return true end
	for _, q in ipairs(gh.sendQueue or {}) do
		if q.key == "POS" and type(q.data) == "table" and q.data.f == 1 then return true end
	end
	return false
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------
function GH:SendPos(m, x, y, find)
	-- posLast / posOn are set in OnPosSent, when it really leaves. A newer spot replaces a waiting
	-- one; a waiting "Find me" keeps its flag (the 12 s gap may hold it for a moment).
	local f = (find or FindWaiting(self)) and 1 or nil
	self:SendMsg("POS", { m = m, x = x, y = y, f = f })
end

-- Our dot is gone (no, instance, feature off). Only if one really left (posOn, set in OnPosSent).
function GH:SendPosOff()
	if not self.posOn then return end
	self.posOn = nil
	self.posLast = nil
	self:SendMsg("POS", { off = 1 })
end

-- Every 12 s (and right after the yes): send if moved.
function GH:PosTick()
	if not self:FeatureOn("map") or self:MapShareAnswer() ~= "yes" then return end
	local ok, why = self:PosCanSend()
	if not ok then
		if why == "instance" or why == "afk" then self:SendPosOff() end
		return
	end
	local m, x, y = self:OwnPosition()
	if not m then return end
	local last = self.posLast
	if last and last.m == m and math.abs(x - last.x) <= MOVE_MIN and math.abs(y - last.y) <= MOVE_MIN then return end
	self:SendPos(m, x, y)
end

local function OnZone()
	if IsInInstance() then GH:SendPosOff() end
end

-- 0.6.0: AFK on → our dot goes at once ("off", 3 s gap); AFK off → the next spot (12 s gap kept).
local function OnFlags(_, unit)
	if unit ~= nil and unit ~= "player" then return end
	if GH:PosAfkHidden() then
		GH:SendPosOff()
	elseif GH:MapShareAnswer() == "yes" and not GH.posOn then
		GH:PosTick()
	end
	if GH.UpdateFindButton then GH:UpdateFindButton() end
end

------------------------------------------------------------------------
-- "Find me" (0.6.0): one click = our dot pulses on guildmates' maps. Click only, at most one per
-- 30 s, only while we share our exact position (same gate as POS). Old clients see a normal POS.
------------------------------------------------------------------------
-- ok, why ("feature" / "trial" / "share" / "instance" / "lockdown" / "combat" / "afk" / "wait" / "nopos"), seconds left
function GH:FindMeState()
	if not self:FeatureOn("map") then return false, "feature" end
	if self.cannotSend then return false, "trial" end
	if self:MapShareAnswer() ~= "yes" then return false, "share" end
	local ok, why = self:PosCanSend()
	if not ok then return false, why end
	-- 30 s from the last click AND from the last one that really left (the 12 s POS gap can hold a
	-- click back for a moment), so two never go out closer than 30 s
	local last = math.max(self.findLast or -1000, self.findStats.last or -1000)
	local left = FIND_SECONDS - (GetTime() - last)
	if left > 0 then return false, "wait", math.ceil(left) end
	if FindWaiting(self) then return false, "wait", FIND_SECONDS end
	if not self:OwnPosition() then return false, "nopos" end
	return true
end

-- The click (Status tab button or /ghub findme). Returns true when it was sent.
function GH:FindMe()
	local ok, why, left = self:FindMeState()
	if not ok then
		self:Msg(L.FIND_NOT, (L.FIND_WHY[why] or why):format(left or 0))
		return false
	end
	local m, x, y = self:OwnPosition()
	self.findLast = GetTime()
	self:SendPos(m, x, y, true)
	self:Msg(L.FIND_SENT)
	if self.UpdateFindButton then self:UpdateFindButton() end
	-- the button lights up again when the 30 s are over
	self:ScheduleTimer(function() if GH.UpdateFindButton then GH:UpdateFindButton() end end, FIND_SECONDS + 0.2)
	return true
end

-- Receiver: a guildmate asked to be found. Only called for a dot we keep (fair trade, not ignored).
local findLineAt, findWaiting = {}, {}

local function FindLine(gh, sender)
	local now = GetTime()
	if findLineAt[sender] and now - findLineAt[sender] < FIND_LINE_SECONDS then return end -- tos (b)
	findLineAt[sender] = now
	local r = gh.roster[sender]
	local zone = r and type(r.zone) == "string" and not U.IsSecret(r.zone) and r.zone ~= "" and U.CleanText(r.zone, 40) or nil
	gh.findStats.lines = gh.findStats.lines + 1
	-- tos (a): our own chat frame only (AddMessage), "Guild Hub:" in the addon's colour; (c) no sound,
	-- no waypoint, the map is not opened
	if zone then gh:Msg(L.FIND_LINE, U.ShortName(sender), zone)
	else gh:Msg(L.FIND_LINE_NOZONE, U.ShortName(sender)) end
end

function GH:MapFindMe(sender)
	if self:IsMuted(sender) then return end -- tos (b): the mute stops the line and the pulse
	self.findStats.got = self.findStats.got + 1
	local inCombat = InCombatLockdown and InCombatLockdown()
	if not inCombat and self.MapPulse then self:MapPulse(sender) end
	if self.db.profile.mapFindLines == false then return end
	if inCombat then findWaiting[sender] = GetTime() return end
	FindLine(self, sender)
end

local function AfterCombatFind()
	local now = GetTime()
	for sender, t in pairs(findWaiting) do
		findWaiting[sender] = nil
		if now - t <= FIND_WAIT_SECONDS and GH.positions[sender] and not GH:IsMuted(sender) then FindLine(GH, sender) end
	end
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
function GH:CleanPos(data)
	if type(data) ~= "table" then return nil end
	local m, x, y = data.m, data.x, data.y
	if U.IsSecret(m) or U.IsSecret(x) or U.IsSecret(y) then return nil end
	if type(m) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then return nil end
	if x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
	if not self:OpenWorldMap(m) then return nil end
	return m, Round(x), Round(y)
end

local function SeesDots(gh) return gh:FeatureOn("map") and gh:CanUse("pos") end
GH.MapSeesDots = SeesDots

function GH:RemovePos(name)
	if self.positions[name] then
		self.positions[name] = nil
		if self.MapDotChanged then self:MapDotChanged(name) end
	end
end

local function HandlePos(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	if data.off == 1 then return self:RemovePos(sender) end
	-- fair trade: only someone who shares sees dots (nothing kept otherwise)
	if not SeesDots(self) then return self:RemovePos(sender) end
	local m, x, y = self:CleanPos(data)
	if not m then
		self:Debug("ignored a position from %s (not an open-world map)", U.ShortName(sender))
		return
	end
	if self:IsIgnored(sender) then return self:RemovePos(sender) end
	self.positions[sender] = { m = m, x = x, y = y, t = GetTime() }
	self:Debug("position from %s", U.ShortName(sender)) -- never the coordinates (chat logs)
	if self.MapDotChanged then self:MapDotChanged(sender) end
	if data.f == 1 then self:MapFindMe(sender) end
end

-- HB: "ps" = still sharing at the same spot (keeps the dot); no "ps" = no dot any more.
function GH:MapReadHB(sender, ps)
	local p = self.positions[sender]
	if not p then return end
	if ps == 1 then p.t = GetTime() else self:RemovePos(sender) end
end

-- Expired dots, players who went offline, ignored players; all of them once we can't see dots any more.
function GH:MapCheckDots()
	local now = GetTime()
	local sees = SeesDots(self)
	for name, p in pairs(self.positions) do
		if not sees or now - p.t > KEEP_SECONDS or (self.rosterReady and not self:IsOnline(name)) or self:IsIgnored(name) then
			self:RemovePos(name)
		end
	end
end

-- Roster.lua after each rebuild.
function GH:MapRosterCheck()
	if not self:FeatureOn("map") then return end
	self:MapCheckDots()
	if self.MapAfkRefresh then self:MapAfkRefresh() end
	if self.MapZoneCountsDirty then self:MapZoneCountsDirty() end
end

------------------------------------------------------------------------
-- Blizzard's ignore list
------------------------------------------------------------------------
local ignoreCache = {}
GH.ignoreMode = nil -- "api" / "list" / "none" (self-test)

local function Lower(s) return type(s) == "string" and s:lower() or nil end

function GH:IsIgnored(name)
	if type(name) ~= "string" then return false end
	local c = ignoreCache[name]
	if c ~= nil then return c end
	local F = C_FriendList
	local short = U.WhisperName(name)
	local result
	if F and F.IsIgnored then
		local ok, v = pcall(F.IsIgnored, short)
		if ok and not U.IsSecret(v) then
			result = v and true or false
			self.ignoreMode = "api"
		end
	end
	if result == nil and F and F.GetNumIgnores and F.GetIgnoreName then
		local okN, n = pcall(F.GetNumIgnores)
		if okN and type(n) == "number" then
			result = false
			local a, b = Lower(short), Lower(U.ShortName(name))
			for i = 1, math.min(n, 100) do
				local okI, ig = pcall(F.GetIgnoreName, i)
				ig = okI and not U.IsSecret(ig) and Lower(ig) or nil
				if ig and (ig == a or ig == b or ig == Lower(name)) then result = true break end
			end
			self.ignoreMode = "list"
		end
	end
	if result == nil then
		result = false
		self.ignoreMode = "none" -- acceptable fallback (tos): nobody ignored; the self-test reports it
	end
	ignoreCache[name] = result
	return result
end

local function OnIgnoreList()
	wipe(ignoreCache)
	GH:MapCheckDots()
end

------------------------------------------------------------------------
-- The welcome card that asks (UI\Card.lua draws it)
------------------------------------------------------------------------
function GH:MapWelcomeCard()
	return {
		key = "welcome-map",
		title = L.CARD_MAP_TITLE,
		text = L.CARD_MAP_BODY,
		note = L.CARD_MAP_NOTE,
		buttons = {
			{ label = L.CARD_MAP_SHARE, width = 140, fn = function() GH:SetMapShare("yes") end },
			-- 0.6.0: the lasting no (tos item 7: the card's note says it can be changed in Settings)
			{ label = L.CARD_MAP_ZONE, width = 106, fn = function() GH:SetMapShare("no") end },
			{ label = L.CARD_MAP_NOTNOW, width = 106, fn = function() GH.mapAskedThisSession = true end },
		},
		-- the X / Esc is "Not now": asked again next login
		onClose = function() GH.mapAskedThisSession = true end,
	}
end

-- Called from Core's start-up (10 s later): the first welcome section that still has a question.
function GH:ShowWelcome(tries)
	if not self.ShowCard then return end
	if not self.rosterReady and (tries or 0) < 6 then
		self:ScheduleTimer(function() GH:ShowWelcome((tries or 0) + 1) end, 5)
		return
	end
	-- the Getting started card deferred from last login comes first (UI\Guide.lua, tos C2)
	if self.GuideFirstThisLogin and self:GuideFirstThisLogin() then return end
	for _, e in ipairs(self:Hooks("welcome")) do
		if type(e.pending) == "function" and e.pending() and type(e.card) == "function" then
			self:ShowCard(e.card())
			break
		end
	end
	-- then the Getting started card (once per character; skipped after a "Not now" this session)
	if self.ShowGuide then self:ShowGuide(true) end
end

------------------------------------------------------------------------
-- The feature
------------------------------------------------------------------------
GH:RegisterFeature({
	key = "map", name = "OPT_FEAT_MAP",
	defaults = { profile = { mapMinimap = true, mapHideAfk = true, mapFindLines = true }, char = { mapShare = "ask" } },
	messages = { POS = { class = "normal", min = POS_SECONDS, latest = true, gate = PosGate, onSend = OnPosSent,
		-- "my dot is gone" skips the 12 s gap, but keeps OFF_GAP seconds from the last "off" (tos: fast toggling)
		urgent = function(data) return type(data) == "table" and data.off == 1 and OFF_GAP or nil end } },
	welcome = { {
		key = "map", order = 10,
		pending = function()
			return GH:FeatureOn("map") and GH:MapShareAnswer() == "ask" and not GH.mapAskedThisSession and not GH.cannotSend
		end,
		card = function() return GH:MapWelcomeCard() end,
	} },
	enable = function(gh)
		gh:Every("map", "pos", TICK_SECONDS, function() GH:PosTick() end)
		gh:Every("map", "dots", CHECK_SECONDS, function() GH:MapCheckDots() end)
		gh:On("map", "ZONE_CHANGED_NEW_AREA", OnZone)
		gh:On("map", "PLAYER_ENTERING_WORLD", OnZone)
		gh:On("map", "IGNORELIST_UPDATE", OnIgnoreList)
		gh:On("map", "PLAYER_FLAGS_CHANGED", OnFlags)
		gh:On("map", "PLAYER_REGEN_ENABLED", AfterCombatFind)
		if gh.MapPinsEnable then gh:MapPinsEnable() end
	end,
	disable = function(gh)
		-- POS is switched off now (it can't even send "off"), so a heartbeat without "ps" tells
		-- guildmates to drop our dot (HB is always on)
		local had = gh.posOn
		gh.posOn, gh.posLast = nil, nil
		if had and gh.started then gh:SendMsg("HB", gh:SelfInfo()) end
		wipe(gh.positions)
		wipe(findWaiting)
		if gh.MapPinsDisable then gh:MapPinsDisable() end
	end,
	selftest = function(api)
		local st, fs = GH.posStats, GH.findStats
		api.Count(7)
		if st.beforeYes > 0 then api.Problem("MAP", "privacy", st.beforeYes .. " position(s) sent before a yes") end
		if st.inInstance > 0 then api.Problem("MAP", "privacy", st.inInstance .. " position(s) sent in an instance") end
		if st.inCombat > 0 then api.Problem("MAP", "privacy", st.inCombat .. " position(s) sent in combat") end
		if st.inAfk > 0 then api.Problem("MAP", "privacy", st.inAfk .. " position(s) sent while hidden for AFK") end
		if st.minGap and st.minGap < POS_SECONDS - 0.2 then api.Problem("MAP", "rate", ("positions %.1f s apart"):format(st.minGap)) end
		if fs.noShare > 0 then api.Problem("MAP", "findme", fs.noShare .. " Find me sent without sharing") end
		if fs.minGap and fs.minGap < FIND_SECONDS - 0.2 then api.Problem("MAP", "findme", ("Find me %.1f s apart"):format(fs.minGap)) end
		if GH.MapSelfTest then GH:MapSelfTest(api) end
	end,
})
GH.handlers.POS = HandlePos

-- Fair trade: no position shared = no guildmates' dots (zone counts stay: they come from the guild list).
GH:RegisterShare({
	key = "pos", order = 1, optKey = "sharePos", feature = "map",
	name = "OPT_SHAREPOS", desc = "OPT_SHAREPOS_DESC",
	get = function(gh) return gh:MapShareAnswer() == "yes" end,
	set = function(gh, on) gh:SetMapShare(on and "yes" or "no") end,
})

-- Core's start-up asks for the welcome card.
GH.WELCOME_DELAY = WELCOME_DELAY
