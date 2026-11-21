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
-- 0.6.0 (plans\map-extras, tos-check.md): the hover card, AFK dimming, the Find me pulse ring
-- (Blizzard's ping file by path), dungeon labels (numbers only, not clickable).
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

local function MakeDot(size, which)
	local f = CreateFrame("Frame", nil, UIParent)
	f.kind = which -- "world" / "mini" (the tooltip's "Also here" compares dots of the same kind)
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
		ic = { world = MakeDot(DOT_WORLD, "world"), mini = MakeDot(DOT_MINI, "mini") }
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
local STACK_PX, STACK_MAX = 10, 5

-- A guildmate's AFK flag from the guild list (Roster.lua), never tested when it is a secret value.
local function RosterAfk(r)
	return r ~= nil and not U.IsSecret(r.afk) and r.afk == true
end

-- Other dots of the same kind (world / minimap) within STACK_PX screen pixels of this one: only dots
-- already on this player's map (tos 4: "Also here" names only dots the receiver already sees).
local function DotsNear(owner)
	local names = {}
	if not (owner.GetCenter and owner.GetEffectiveScale) then return names end
	local ox, oy = owner:GetCenter()
	if not ox then return names end
	local os = owner:GetEffectiveScale()
	for name, ic in pairs(GH.mapIcons) do
		local d = ic[owner.kind or "world"]
		if d and d ~= owner and d:IsShown() and (GH.testPositions[name] or GH.positions[name]) then
			local x, y = d:GetCenter()
			if x then
				local s = d:GetEffectiveScale()
				local dx, dy = x * s - ox * os, y * s - oy * os
				if dx * dx + dy * dy <= STACK_PX * STACK_PX then names[#names + 1] = name end
			end
		end
	end
	table.sort(names)
	return names
end
GH.MapDotsNear = DotsNear

-- The hover card (0.6.0): name (+ AFK), level · class · rank, zone, status, group size, professions,
-- the hoverLines hook, "Also here", position age. Hover only; nothing in combat; none for ignored.
function GH:DotTooltip(owner)
	local name = owner.who
	if not name or InCombat() then return end
	local p = self.positions[name] or self.testPositions[name]
	if not p then return end
	if not p.test and self:IsIgnored(name) then return end -- tos: no tooltip for ignored players
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	self:AddHoverCard(name, p)
	local near = DotsNear(owner)
	if #near > 0 then
		local shown = {}
		for i = 1, math.min(#near, STACK_MAX) do shown[i] = U.ShortName(near[i]) end
		local text = L.TIP_DOT_ALSO:format(table.concat(shown, ", "))
		if #near > STACK_MAX then text = text .. L.TIP_DOT_MORE:format(#near - STACK_MAX) end
		GameTooltip:AddLine(text, 0.8, 0.8, 0.8, true)
	end
	if p.test then GameTooltip:AddLine(L.TIP_DOT_TEST, 0.6, 0.6, 0.6)
	else GameTooltip:AddLine(L.TIP_DOT_AGO:format(U.Ago(math.max(0, GetTime() - p.t))), 0.6, 0.6, 0.6) end
	GameTooltip:Show()
end

-- The hover card's lines for one guildmate (also the Map tab's rows, 0.6.0-beta.3). p = their dot or nil.
function GH:AddHoverCard(name, p)
	local r = self.roster[name]
	local class = ClassOf(name, p)
	GameTooltip:AddLine(U.ClassColored(name, class) .. (RosterAfk(r) and L.TIP_DOT_AFK or ""))
	local parts = {}
	if r and r.level then parts[#parts + 1] = L.TIP_DOT_LEVEL:format(tostring(r.level)) end
	local cname = class and type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE[class]
	if type(cname) == "string" then parts[#parts + 1] = cname end
	if r and type(r.rankName) == "string" and r.rankName ~= "" then parts[#parts + 1] = r.rankName end
	if #parts > 0 then GameTooltip:AddLine(table.concat(parts, " · "), 1, 1, 1) end
	local zone = r and r.zone
	if type(zone) == "string" and not U.IsSecret(zone) and zone ~= "" then
		GameTooltip:AddLine(U.CleanText(zone, 40), 0.8, 0.8, 0.8)
	end
	local gdb = self:GetGuildDB()
	local m = gdb and gdb.members[name]
	local s = m and m.status
	if s and self:IsStatusFresh(s) then
		local line = self:StatusLine(s, true, self:IsMuted(name))
		if line and line ~= "" then GameTooltip:AddLine(line, 1, 0.82, 0, true) end
	end
	-- group size: only what they share, and only for someone who shares their own (fair trade)
	local u = self.addonUsers and self.addonUsers[name]
	local g = u and u.grp
	if g and type(g.g) == "number" and g.g > 0 and self:CanUse("group") then
		GameTooltip:AddLine((g.r and L.TIP_GRP_RAID or L.TIP_GRP_PARTY):format(g.g), 0.8, 0.8, 0.8)
	end
	local prof = self.ProfLine and self:ProfLine(name) -- fair trade inside
	if prof and prof ~= "" then GameTooltip:AddLine(prof, 0.8, 0.8, 0.8, true) end
	-- later features' lines (each needs its own tos check)
	for _, h in ipairs(self:Hooks("hoverLines")) do
		if type(h) == "table" and type(h.fn) == "function" then
			local ok, text, cr, cg, cb = pcall(h.fn, self, name)
			if ok and type(text) == "string" and text ~= "" then GameTooltip:AddLine(text, cr or 1, cg or 1, cb or 1, true) end
		end
	end
end

------------------------------------------------------------------------
-- "Find me" pulse (0.6.0): a ring grows and fades around the dot for 15 s. Our own OnUpdate, only
-- while a pulse runs and the dot is visible; the ring takes no mouse (the dot keeps its tooltip).
------------------------------------------------------------------------
local PULSE_SECONDS, PULSE_LOOP = 15, 1.2
GH.pulseCount = 0

local function RingUpdate(ring)
	local now = GetTime()
	if now >= ring.untilT then
		ring:SetScript("OnUpdate", nil)
		ring:Hide()
		return
	end
	local t = (now % PULSE_LOOP) / PULSE_LOOP
	local size = ring.base * (1 + 2 * t)
	ring:SetSize(size, size)
	ring:SetAlpha(1 - t)
end

local function Ring(dot)
	local ring = dot.ring
	if ring then return ring end
	ring = CreateFrame("Frame", nil, dot)
	ring:SetPoint("CENTER")
	ring:EnableMouse(false)
	local tex = ring:CreateTexture(nil, "ARTWORK")
	tex:SetAllPoints()
	local kind, art = W.PingArt()
	if kind == "file" then
		tex:SetTexture(art)
	else
		local dk, da = GH:DotArt()
		if dk == "atlas" then
			tex:SetAtlas(da)
		else
			tex:SetTexture(da)
			if ring.CreateMaskTexture and tex.AddMaskTexture then
				local mask = ring:CreateMaskTexture()
				mask:SetTexture(W.ART.dot.mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
				mask:SetAllPoints(tex)
				tex:AddMaskTexture(mask)
			end
		end
	end
	ring.tex, ring.art = tex, kind
	ring:Hide()
	dot.ring = ring
	return ring
end
GH.MapRing = Ring

local function Pulse(dot, r, g, b)
	local ring = Ring(dot)
	ring.base = dot:GetWidth() > 0 and dot:GetWidth() or DOT_WORLD
	ring.untilT = GetTime() + PULSE_SECONDS
	ring.tex:SetVertexColor(r, g, b)
	ring:SetSize(ring.base, ring.base)
	ring:SetScript("OnUpdate", RingUpdate)
	ring:Show()
end

-- The sender's dots pulse (world map + minimap). Not in combat (Map.lua checks), only a dot we show.
function GH:MapPulse(name)
	local ic = self.mapIcons[name]
	if not ic or not (self.positions[name] or self.testPositions[name]) then return end
	local r, g, b = ClassColor(ClassOf(name, self.positions[name] or self.testPositions[name]))
	Pulse(ic.world, r, g, b)
	if self.db.profile.mapMinimap then Pulse(ic.mini, r, g, b) end
	self.pulseCount = self.pulseCount + 1
end

------------------------------------------------------------------------
-- AFK dimming (0.6.0): dots of guildmates Blizzard's guild list marks AFK (older clients, or the
-- hide setting off) at half strength. Only an alpha change: no pin is added, moved or removed.
------------------------------------------------------------------------
local AFK_ALPHA = 0.5
local function DimAfk(name, ic)
	local r = GH.roster[name]
	local a = (RosterAfk(r) and not GH.testPositions[name]) and AFK_ALPHA or 1
	ic.world:SetAlpha(a)
	ic.mini:SetAlpha(a)
	ic.dimmed = a < 1 -- (tests and the self-test read this)
end

function GH:MapAfkRefresh()
	for name, ic in pairs(self.mapIcons) do DimAfk(name, ic) end
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
	DimAfk(name, ic)
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

-- 0.6.0-beta.3: the uiMapID of an open-world zone by its name (Show on map), or nil.
function GH:ZoneMapID(zone)
	if type(zone) ~= "string" or U.IsSecret(zone) then return nil end
	if not zoneIndex or not next(zoneIndex) then BuildZoneIndex() end
	local e = zoneIndex[zone]
	return e and e.id or nil
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
	f:SetSize(160, 16)
	if f.icon then f.icon:Hide() end
	f.dungeon = nil
	f:EnableMouse(false)
	return f
end

-- 0.6.0: a dungeon label = a label with Blizzard's dungeon / raid icon in front (text only without it).
local function DungeonLabel(text, raid)
	local f = Label()
	f:SetSize(240, 16)
	f.text:SetText(text)
	local atlas = W.DungeonIconArt(raid and "raid" or "dungeon")
	if atlas then
		if not f.icon then
			f.icon = f:CreateTexture(nil, "ARTWORK")
			f.icon:SetSize(14, 14)
		end
		f.icon:ClearAllPoints()
		f.icon:SetPoint("RIGHT", f.text, "LEFT", -2, 0)
		f.icon:SetAtlas(atlas)
		f.icon:Show()
	end
	f.dungeon = true
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
	-- 0.6.0 dungeon labels at the entrance (zone map + continent); a second door only on its zone map
	if self.DungeonCounts then
		local showCont = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2
		for d, c in pairs(self:DungeonCounts()) do
			local text = self:DungeonLabelText(d, c)
			local f = DungeonLabel(text, d.raid)
			if pcall(P.AddWorldMapIconMap, P, REF, f, d.m, d.x, d.y, showCont) then self.mapLabels[#self.mapLabels + 1] = f end
			if d.also then
				local f2 = DungeonLabel(text, d.raid)
				if pcall(P.AddWorldMapIconMap, P, REF, f2, d.also.m, d.also.x, d.also.y, 0) then self.mapLabels[#self.mapLabels + 1] = f2 end
			end
		end
	end
end

-- Dungeon labels on the map now (self-test).
function GH:MapDungeonLabelCount()
	local n = 0
	for _, f in ipairs(self.mapLabels) do if f.dungeon then n = n + 1 end end
	return n
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
	-- 0.6.0: a made-up dungeon label count near you, and the first test dot pulses ("Find me")
	self.testDungeon = self.TestDungeonSpot and self:TestDungeonSpot(m) or nil
	self:MapRedraw()
	self:MapPulse(fake[1][1])
	self:Msg(L.TEST_MAP_ON, TEST_SECONDS)
	if self.testMapTimer then self:CancelTimer(self.testMapTimer) end
	self.testMapTimer = self:ScheduleTimer(function()
		GH.testMapTimer = nil
		GH.testDungeon = nil
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
	if type(func) == "string" and not U.IsSecret(func) and func:find("InviteUnit", 1, true) then return end
	-- 0.6.0-beta.3: Ask to join's request falls back to the chat box too (Features\Actions.lua)
	if type(func) == "string" and not U.IsSecret(func) and func:find("RequestInviteFromUnit", 1, true) then return end
	if GH.lastAsk and GetTime() - GH.lastAsk.time < 3 then return end
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
	-- (members' "lastSeen" is a plain time stamp, not a place: not checked)
	if rawget(t, "positions") ~= nil or rawget(t, "testPositions") ~= nil or rawget(t, "findStats") ~= nil then return true end
	local m, x, y = rawget(t, "m"), rawget(t, "x"), rawget(t, "y")
	if type(m) == "number" and type(x) == "number" and type(y) == "number" and x <= 1 and y <= 1 then return true end
	for _, v in pairs(t) do
		if type(v) == "table" and HasPositions(v, depth + 1, seen, budget) then return true end
	end
	return false
end
GH.MapHasSavedPositions = function(t) return HasPositions(t, 0, {}, { 20000 }) end

local testRingDot -- the self-test's hidden dot for the ring check

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
	-- 0.6.0: the own entrance table against this game's REAL maps (every spot an open-world zone)
	if self.CheckEntrances then
		api.Count()
		local good, total, bad = self:CheckEntrances()
		if #bad > 0 then api.Problem("MAP", "entrances", table.concat(bad, ",", 1, math.min(#bad, 6))) end
		-- the Find me ring: built on a hidden test dot, it must have art
		api.Count()
		local okR, ring = pcall(function()
			testRingDot = testRingDot or CreateFrame("Frame", nil, UIParent) -- one hidden frame, reused
			testRingDot:Hide()
			return Ring(testRingDot)
		end)
		if not okR or not (ring and ring.tex) then api.Problem("MAP", "pulse", "the Find me ring failed") end
		local fs, st = self.findStats, self.posStats
		api.Info(("map extras: entrances %d/%d, afk-hide %s (sent while afk %d, afk unknown %d), find sent %d got %d lines %d, pulses %d dropped %d, ping art %s, dlabels %d, dungeon art %s"):format(
			good, total, self.db.profile.mapHideAfk ~= false and "y" or "n", st.inAfk, self.afkUnknown or 0, fs.sent, fs.got, fs.lines,
			self.pulseCount, fs.pulseDropped or 0, okR and ring and ring.art or "-", self:MapDungeonLabelCount(),
			W.DungeonIconArt("dungeon") and "y" or "n"))
	end
end
