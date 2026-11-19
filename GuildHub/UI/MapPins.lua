-- Guild Hub: guildmates' dots on the world map and the minimap, and zone counts (0.4.0-beta.2).
-- Drawn with HereBeDragons-Pins (Blizzard's own map pin system on WorldMapFrame; the minimap maths).
-- tos conditions built in:
--  * hover-only pins: plain frames with a tooltip, no click handlers, no secure templates, no hooks
--    on WorldMapFrame, no protected calls;
--  * no pin is added, moved or removed while in combat with the world map open: queued for
--    PLAYER_REGEN_ENABLED;
--  * zone counts: numbers only, online members only, from the guild list the addon already reads
--    every 60 s, rebuilt only while the world map is shown, never saved or sent;
--  * no zone-enter or near-you alerts, no trails, nothing saved.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util
local W = ns.Widgets

local REF = "GuildHub"
local DOT_WORLD, DOT_MINI = 14, 12
local TEST_SECONDS = 60
local LABEL_CHECK = 1 -- s: is the world map open? (a read, not a hook)

GH.mapIcons = {}      -- [name] = { world = frame, mini = frame }
GH.mapLabels = {}     -- zone count labels in use
GH.testPositions = {} -- /ghub test map: made-up guildmates around you (local only, 60 s)
GH.actionBlocked = { n = 0 } -- ADDON_ACTION_BLOCKED / FORBIDDEN naming Guild Hub (self-test)

local labelPool = {}

local function Pins() return LibStub and LibStub("HereBeDragons-Pins-2.0", true) end
local function MapShown()
	return WorldMapFrame ~= nil and type(WorldMapFrame.IsShown) == "function" and WorldMapFrame:IsShown() and true or false
end
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end
-- tos (a): no pin changes while in combat with the world map open
local function Blocked() return InCombat() and MapShown() end

------------------------------------------------------------------------
-- Dot art (theme point W.ART.dot): Blizzard's group-member dot, tinted; else a round white square
------------------------------------------------------------------------
function GH:DotArt()
	local a = W.ART.dot
	if W.HasAtlas(a.atlas) then return "atlas", a.atlas end
	return "file", a.file
end

local function ClassColor(class)
	local c = type(RAID_CLASS_COLORS) == "table" and class and RAID_CLASS_COLORS[class]
	if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
	return W.GOLD[1], W.GOLD[2], W.GOLD[3]
end

local function MakeDot(size)
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetSize(size, size)
	f:EnableMouse(true) -- hover only (no OnClick / OnMouseUp)
	local tex = f:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints()
	local kind, art = GH:DotArt()
	if kind == "atlas" then
		tex:SetAtlas(art)
	else
		tex:SetTexture(art)
		if f.CreateMaskTexture and tex.AddMaskTexture then
			local mask = f:CreateMaskTexture()
			mask:SetTexture(W.ART.dot.mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			mask:SetAllPoints(tex)
			tex:AddMaskTexture(mask)
		end
	end
	f.tex, f.art = tex, kind
	f:SetScript("OnEnter", function(self) GH:DotTooltip(self) end)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f:Hide()
	return f
end

local function Icons(name)
	local ic = GH.mapIcons[name]
	if not ic then
		ic = { world = MakeDot(DOT_WORLD), mini = MakeDot(DOT_MINI) }
		ic.world.who, ic.mini.who = name, name
		GH.mapIcons[name] = ic
	end
	return ic
end

local function ClassOf(name, p)
	if p and p.class then return p.class end
	local r = GH.roster[name]
	if r and r.class then return r.class end
	local gdb = GH:GetGuildDB()
	local m = gdb and gdb.members[name]
	return m and m.class
end

------------------------------------------------------------------------
-- Tooltip (hover only)
------------------------------------------------------------------------
function GH:DotTooltip(owner)
	local name = owner.who
	if not name or InCombat() then return end
	local p = self.positions[name] or self.testPositions[name]
	if not p then return end
	if not p.test and self:IsIgnored(name) then return end -- tos: no tooltip for ignored players
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:AddLine(U.ClassColored(name, ClassOf(name, p)))
	local r = self.roster[name]
	if r and r.level then GameTooltip:AddLine(L.TIP_DOT_LEVEL:format(tostring(r.level)), 1, 1, 1) end
	local gdb = self:GetGuildDB()
	local m = gdb and gdb.members[name]
	local s = m and m.status
	if s and self:IsStatusFresh(s) then
		local line = self:StatusLine(s, true, self:IsMuted(name))
		if line and line ~= "" then GameTooltip:AddLine(line, 1, 0.82, 0, true) end
	end
	if p.test then GameTooltip:AddLine(L.TIP_DOT_TEST, 0.6, 0.6, 0.6)
	else GameTooltip:AddLine(L.TIP_DOT_AGO:format(U.Ago(math.max(0, GetTime() - p.t))), 0.6, 0.6, 0.6) end
	GameTooltip:Show()
end

------------------------------------------------------------------------
-- Drawing the dots
------------------------------------------------------------------------
local function RemoveIcons(P, ic)
	pcall(P.RemoveWorldMapIcon, P, REF, ic.world)
	pcall(P.RemoveMinimapIcon, P, REF, ic.mini)
	ic.world:Hide()
	ic.mini:Hide()
end

-- One guildmate's dot: add, move or remove.
function GH:MapDotChanged(name)
	local P = Pins()
	if not P then return end
	if Blocked() then self.mapDirty = true return end
	local p = self.testPositions[name]
	if not p then
		p = self.positions[name]
		if p and (not GH.MapSeesDots(self) or self:IsIgnored(name)) then p = nil end
	end
	local ic = self.mapIcons[name]
	if not p then
		if ic then RemoveIcons(P, ic) end
		return
	end
	ic = ic or Icons(name)
	local r, g, b = ClassColor(ClassOf(name, p))
	ic.world.tex:SetVertexColor(r, g, b)
	ic.mini.tex:SetVertexColor(r, g, b)
	pcall(P.AddWorldMapIconMap, P, REF, ic.world, p.m, p.x, p.y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
	if self.db.profile.mapMinimap then
		pcall(P.AddMinimapIconMap, P, REF, ic.mini, p.m, p.x, p.y, true, false)
	else
		pcall(P.RemoveMinimapIcon, P, REF, ic.mini)
		ic.mini:Hide()
	end
end

-- Everything again (share answer, minimap switch, after combat, feature on).
function GH:MapRedraw()
	local P = Pins()
	if not P then return end
	if Blocked() then self.mapDirty = true return end
	self.mapDirty = nil
	for name in pairs(self.mapIcons) do
		if not self.positions[name] and not self.testPositions[name] then RemoveIcons(P, self.mapIcons[name]) end
	end
	if self:FeatureOn("map") then
		for name in pairs(self.positions) do self:MapDotChanged(name) end
	end
	for name in pairs(self.testPositions) do self:MapDotChanged(name) end
	self:MapZoneCountsDirty()
end

-- How many dots are on the maps now (self-test).
function GH:MapDotCount()
	local n = 0
	for _, ic in pairs(self.mapIcons) do if ic.world:IsShown() or ic.mini:IsShown() then n = n + 1 end end
	return n
end

------------------------------------------------------------------------
-- Zone counts (numbers only, from Blizzard's guild list zone, online only)
------------------------------------------------------------------------
local zoneIndex -- [zone name] = { id, cont, cx, cy }

local function BuildZoneIndex()
	zoneIndex = {}
	if not (C_Map and C_Map.GetMapChildrenInfo and C_Map.GetMapInfo) then return end
	local T = (Enum and Enum.UIMapType) or {}
	local okC, list = pcall(C_Map.GetMapChildrenInfo, 947, T.Zone or 3, true)
	if not okC or type(list) ~= "table" then return end
	for _, z in ipairs(list) do
		if type(z) == "table" and type(z.name) == "string" and type(z.mapID) == "number" and not zoneIndex[z.name] then
			-- the continent above it
			local id, cont = z.parentMapID, nil
			for _ = 1, 6 do
				if type(id) ~= "number" or id == 0 then break end
				local ok, info = pcall(C_Map.GetMapInfo, id)
				if not ok or type(info) ~= "table" then break end
				if info.mapType == (T.Continent or 2) then cont = id break end
				id = info.parentMapID
			end
			local e = { id = z.mapID, cont = cont }
			if cont and C_Map.GetMapRectOnMap then
				local ok, x1, x2, y1, y2 = pcall(C_Map.GetMapRectOnMap, z.mapID, cont)
				if ok and type(x1) == "number" and type(x2) == "number" and type(y1) == "number" and type(y2) == "number" then
					e.cx, e.cy = (x1 + x2) / 2, (y1 + y2) / 2
				end
			end
			zoneIndex[z.name] = e
		end
	end
end

-- { [zone name] = count } of online guild members (not you), plus the test dots' zone.
function GH:ZoneCounts()
	local counts = {}
	local me = self:MyName()
	for name, r in pairs(self.roster) do
		local z = r.zone
		if r.online and name ~= me and type(z) == "string" and not U.IsSecret(z) and z ~= "" then
			counts[z] = (counts[z] or 0) + 1
		end
	end
	if next(self.testPositions) then
		local z = self:LiveZone()
		if type(z) == "string" and z ~= "" then counts[z] = (counts[z] or 0) + 3 end
	end
	return counts
end

local function Label()
	local f = table.remove(labelPool)
	if not f then
		f = CreateFrame("Frame", nil, UIParent)
		f:SetSize(160, 16)
		f.text = W.Text(f, "GameFontHighlightSmall", nil, "CENTER")
		f.text:SetPoint("CENTER")
		f.text:SetShadowOffset(1, -1)
	end
	f:EnableMouse(false)
	return f
end

local function ClearLabels(P)
	for _, f in ipairs(GH.mapLabels) do
		if P then pcall(P.RemoveWorldMapIcon, P, REF, f) end
		f:Hide()
		labelPool[#labelPool + 1] = f
	end
	wipe(GH.mapLabels)
end

-- Dots sharing their exact position in this zone (or a cave inside it).
local function DotsIn(zoneID)
	local n = 0
	local sees = GH.MapSeesDots(GH)
	for name, p in pairs(GH.positions) do
		if sees and not GH:IsIgnored(name) then
			if p.m == zoneID then n = n + 1
			elseif C_Map and C_Map.GetMapInfo then
				local ok, info = pcall(C_Map.GetMapInfo, p.m)
				if ok and type(info) == "table" and info.parentMapID == zoneID then n = n + 1 end
			end
		end
	end
	return n
end

-- Labels: only while the world map is open (checked once a second, no hooks).
function GH:MapLabelsTick()
	local P = Pins()
	if not P then return end
	local shown = MapShown() and self:FeatureOn("map")
	if not shown then
		if #self.mapLabels > 0 and not Blocked() then ClearLabels(P) end
		self.labelsBuilt = nil
		return
	end
	if self.labelsBuilt and not self.labelsDirty then return end
	if Blocked() then self.mapDirty = true return end
	self.labelsBuilt, self.labelsDirty = true, nil
	ClearLabels(P)
	if not zoneIndex or not next(zoneIndex) then BuildZoneIndex() end
	local sees = GH.MapSeesDots(self)
	for zone, n in pairs(self:ZoneCounts()) do
		local e = zoneIndex[zone]
		if e then
			-- continent map: "Elwynn Forest 3" in the zone's middle
			if e.cont and e.cx then
				local f = Label()
				f.text:SetText(L.MAP_ZONE_COUNT:format(zone, n))
				if pcall(P.AddWorldMapIconMap, P, REF, f, e.cont, e.cx, e.cy, 0) then self.mapLabels[#self.mapLabels + 1] = f end
			end
			-- the zone's own map: one line at the top
			local f = Label()
			f:SetSize(420, 16)
			local text = L.MAP_ZONE_HERE:format(n)
			if sees then text = text .. L.MAP_ZONE_EXACT:format(DotsIn(e.id))
			else text = text .. L.MAP_ZONE_SHARE_HINT end
			f.text:SetText(text)
			if pcall(P.AddWorldMapIconMap, P, REF, f, e.id, 0.5, 0.04, 0) then self.mapLabels[#self.mapLabels + 1] = f end
		end
	end
end

function GH:MapZoneCountsDirty()
	self.labelsDirty = true
end

------------------------------------------------------------------------
-- /ghub test map: three made-up guildmates around you for 60 s (local only, nothing sent)
------------------------------------------------------------------------
function GH:TestMap()
	if not Pins() then return self:Msg(L.TEST_MAP_NOLIB) end
	local m, x, y = self:OwnPosition()
	if not m then return self:Msg(L.TEST_MAP_NOPOS) end
	wipe(self.testPositions)
	local fake = { { "Testa Mapwell", "MAGE", 0.01, 0 }, { "Brom Fakehold", "WARRIOR", -0.008, 0.008 }, { "Lia Notreal", "PRIEST", 0, -0.012 } }
	for _, e in ipairs(fake) do
		self.testPositions[e[1]] = { m = m, x = math.min(1, math.max(0, x + e[3])), y = math.min(1, math.max(0, y + e[4])), t = GetTime(), test = true, class = e[2] }
	end
	self:MapRedraw()
	self:Msg(L.TEST_MAP_ON, TEST_SECONDS)
	if self.testMapTimer then self:CancelTimer(self.testMapTimer) end
	self.testMapTimer = self:ScheduleTimer(function()
		GH.testMapTimer = nil
		wipe(GH.testPositions)
		GH:MapRedraw()
	end, TEST_SECONDS)
end

------------------------------------------------------------------------
-- Start / stop (called by the map feature), combat queue, the taint watch
------------------------------------------------------------------------
function GH:MapPinsEnable()
	self:Every("map", "labels", LABEL_CHECK, function() GH:MapLabelsTick() end)
	self:MapRedraw()
end

-- Removes our pins (not test dots) and labels; in combat with the world map open this waits
-- (mapDirty) and the after-combat clean-up below does it.
local function ClearAll(gh)
	local P = Pins()
	if P then
		for name in pairs(gh.mapIcons) do
			if not gh.testPositions[name] then RemoveIcons(P, gh.mapIcons[name]) end
		end
		ClearLabels(P)
	end
	gh.labelsBuilt = nil
end

function GH:MapPinsDisable()
	self.labelsBuilt = nil
	if Blocked() then self.mapDirty = true return end
	ClearAll(self)
end

-- After combat: anything that waited (owner "mapcombat", not "map", so it still runs after the map
-- feature was switched off in combat).
local function AfterCombat()
	if not GH.mapDirty then return end
	if GH:FeatureOn("map") then
		GH:MapRedraw()
	else
		GH.mapDirty = nil
		ClearAll(GH)
		if next(GH.testPositions) then GH:MapRedraw() end
	end
end
GH:On("mapcombat", "PLAYER_REGEN_ENABLED", AfterCombat)

-- tos (c): count ADDON_ACTION_BLOCKED / FORBIDDEN that name Guild Hub (always on, any feature).
-- The known invite fallback (InviteUnit) is not counted here.
local function OnActionBlocked(_, addon, func)
	if addon ~= "GuildHub" then return end
	if type(func) == "string" and func:find("InviteUnit", 1, true) then return end
	local a = GH.actionBlocked
	-- the recruiter's ad post / /ghub test post / guild invite (it falls back to the chat box): a refusal is expected (no key press, or
	-- the timer control) and gets its own result line, so it is not a taint problem. Blizzard's own
	-- message is never hidden (tos condition 3).
	if GH.testPosting or GH.adPending or GH.guildInvitePending or (GH.chatPostBlockedAt and GetTime() - GH.chatPostBlockedAt < 1) then
		a.chat = (a.chat or 0) + 1
		return
	end
	a.n = a.n + 1
	a.last = type(func) == "string" and func:sub(1, 60) or "?"
end
GH:On("taint", "ADDON_ACTION_BLOCKED", OnActionBlocked)
GH:On("taint", "ADDON_ACTION_FORBIDDEN", OnActionBlocked)

------------------------------------------------------------------------
-- Self-test part (called by the map feature's selftest)
------------------------------------------------------------------------
-- Is any saved table holding positions? (bounded walk over a copy-free read)
local function HasPositions(t, depth, seen, budget)
	if type(t) ~= "table" or depth > 7 or seen[t] or budget[1] <= 0 then return false end
	seen[t] = true
	budget[1] = budget[1] - 1
	if rawget(t, "positions") ~= nil or rawget(t, "testPositions") ~= nil then return true end
	local m, x, y = rawget(t, "m"), rawget(t, "x"), rawget(t, "y")
	if type(m) == "number" and type(x) == "number" and type(y) == "number" and x <= 1 and y <= 1 then return true end
	for _, v in pairs(t) do
		if type(v) == "table" and HasPositions(v, depth + 1, seen, budget) then return true end
	end
	return false
end
GH.MapHasSavedPositions = function(t) return HasPositions(t, 0, {}, { 20000 }) end

function GH:MapSelfTest(api)
	api.Count(3)
	if GH.MapHasSavedPositions(GuildHubDB) then api.Problem("MAP", "saved", "positions found in the saved data") end
	if self.actionBlocked.n > 0 then api.Problem("TAINT", "blocked", self.actionBlocked.n .. "x " .. tostring(self.actionBlocked.last)) end
	local P = Pins()
	if not P then api.Problem("MAP", "lib", "HereBeDragons not loaded") end
	local kind = self:DotArt()
	api.Info(("map %s, dots %d, ignore %s, dot art %s, lib %s, chat refused %d"):format(self:MapShareAnswer(), self:MapDotCount(),
		tostring(self.ignoreMode or "-"), kind, P and "y" or "n", self.actionBlocked.chat or 0))
	-- the ignore check itself must not throw
	api.Count()
	local ok = pcall(self.IsIgnored, self, self:MyName())
	if not ok then api.Problem("MAP", "ignore", "the ignore check failed") end
end
