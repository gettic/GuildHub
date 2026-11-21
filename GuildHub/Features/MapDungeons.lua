-- Guild Hub: dungeon labels on the guild map (0.6.0). Part of the map feature; nothing sent, nothing saved.
--
-- Forever's client has no dungeon entrance data (the api test: GetDungeonEntrancesForMap gave 0 on
-- the zone, the continent and three known entrance zones, 2026-11-19), so this is our own table.
-- Written by us from the game's own (Classic) zone maps; spots are approximate and checked in game
-- (the self-test checks every map ID against the real maps). Background: the dungeons' pages on
-- warcraft.wiki.gg. Never copied from another addon.
--
-- tos (plans\map-extras\tos-check.md item 3): numbers only, online members only, not yourself, never
-- saved or sent; secret zones skipped; the instance from a status only from members who share
-- their status; labels are not clickable and nothing hooks WorldMapFrame (UI\MapPins.lua draws them).
local _, ns = ...
local GH, U = ns.GH, ns.Util

-- One spot per entrance. list = the short names (Status.lua INSTANCES) counted at this spot, in label order.
-- m = Classic uiMapID of the zone, x / y = 0-1 on that zone's map. also = a second spot showing the
-- same label (Blackrock Mountain has a door in two zones; the continent shows only the first).
local ENTRANCES = {
	{ key = "RFC",    m = 1454, x = 0.520, y = 0.495, list = { "RFC" } },                 -- Orgrimmar, Cleft of Shadow
	{ key = "WC",     m = 1413, x = 0.460, y = 0.365, list = { "WC" } },                  -- The Barrens
	{ key = "DM",     m = 1436, x = 0.425, y = 0.717, list = { "DM" } },                  -- Westfall, Moonbrook
	{ key = "SFK",    m = 1421, x = 0.449, y = 0.679, list = { "SFK" } },                 -- Silverpine Forest
	{ key = "BFD",    m = 1440, x = 0.142, y = 0.140, list = { "BFD" } },                 -- Ashenvale, Zoram Strand
	{ key = "Stocks", m = 1453, x = 0.405, y = 0.558, list = { "Stocks" } },              -- Stormwind City
	{ key = "Gnomer", m = 1426, x = 0.243, y = 0.395, list = { "Gnomer" } },              -- Dun Morogh
	{ key = "RFK",    m = 1413, x = 0.423, y = 0.899, list = { "RFK" } },                 -- The Barrens, south
	{ key = "SM",     m = 1420, x = 0.830, y = 0.330, list = { "SM" } },                  -- Tirisfal Glades
	{ key = "RFD",    m = 1413, x = 0.490, y = 0.940, list = { "RFD" } },                 -- The Barrens, south edge
	{ key = "Ulda",   m = 1418, x = 0.430, y = 0.125, list = { "Ulda" } },                -- Badlands
	{ key = "ZF",     m = 1446, x = 0.390, y = 0.205, list = { "ZF" } },                  -- Tanaris
	{ key = "Mara",   m = 1443, x = 0.290, y = 0.625, list = { "Mara" } },                -- Desolace
	{ key = "ST",     m = 1435, x = 0.698, y = 0.536, list = { "ST" } },                  -- Swamp of Sorrows
	{ key = "BRM",    m = 1428, x = 0.293, y = 0.383, list = { "BRD", "LBRS", "UBRS", "BRS", "MC", "BWL" },
		name = "BRM", also = { m = 1427, x = 0.348, y = 0.845 } },                        -- Burning Steppes / Searing Gorge
	{ key = "DireM",  m = 1444, x = 0.590, y = 0.449, list = { "Dire Maul" } },           -- Feralas
	{ key = "Scholo", m = 1422, x = 0.697, y = 0.732, list = { "Scholo" } },              -- Western Plaguelands, Caer Darrow
	{ key = "Strat",  m = 1423, x = 0.310, y = 0.155, list = { "Strat" } },               -- Eastern Plaguelands
	{ key = "Ony",    m = 1445, x = 0.526, y = 0.768, list = { "Ony" }, raid = true },                 -- Dustwallow Marsh
	{ key = "ZG",     m = 1434, x = 0.539, y = 0.176, list = { "ZG" }, raid = true },                  -- Stranglethorn Vale
	{ key = "AQ",     m = 1451, x = 0.286, y = 0.924, list = { "AQ20", "AQ40" }, name = "AQ", raid = true }, -- Silithus
	{ key = "Naxx",   m = 1423, x = 0.399, y = 0.259, list = { "Naxx" }, raid = true },                -- Eastern Plaguelands
}
GH.ENTRANCES = ENTRANCES

local SPOT_BY_SHORT = {}
for _, e in ipairs(ENTRANCES) do
	for _, s in ipairs(e.list) do SPOT_BY_SHORT[s] = e end
end
GH.ENTRANCE_BY_SHORT = SPOT_BY_SHORT

-- Short name of the instance an online guildmate is in, or nil. Guild Hub users who share a status
-- in a dungeon give the exact one (LBRS / UBRS); everyone else from Blizzard's guild-list zone.
local function ShortFor(gh, name, zone)
	local gdb = gh:GetGuildDB()
	local m = gdb and gdb.members and gdb.members[name]
	local s = m and m.status
	if s and gh:IsStatusFresh(s) and (s.a == "dng" or s.a == "raid") then
		local short = gh:InstanceLabel(s, zone, false)
		if short and SPOT_BY_SHORT[short] then return short end
	end
	local e = gh.INSTANCE_BY_NAME[zone]
	return e and e.short or nil
end
GH.DungeonShortFor = ShortFor -- 0.6.0-beta.3: Show on map / Ask to join (Features\Actions.lua)

-- { [entrance] = { total = n, [short] = n } } for online guild members (not you). Numbers only.
function GH:DungeonCounts()
	local counts = {}
	local me = self:MyName()
	for name, r in pairs(self.roster) do
		local z = r.zone
		if r.online and name ~= me and type(z) == "string" and not U.IsSecret(z) and z ~= "" then
			local short = ShortFor(self, name, z)
			local e = short and SPOT_BY_SHORT[short]
			if e then
				local c = counts[e]
				if not c then c = { total = 0 }; counts[e] = c end
				c.total = c.total + 1
				c[short] = (c[short] or 0) + 1
			end
		end
	end
	-- /ghub test map: a made-up 2 at an entrance near you (only on your screen)
	local t = self.testDungeon
	if t then
		local c = counts[t]
		if not c then c = { total = 0 }; counts[t] = c end
		c.total = c.total + 2
		c[t.list[1]] = (c[t.list[1]] or 0) + 2
	end
	return counts
end

-- The continent above a map (nil if none).
local function ContinentOf(m)
	if not (C_Map and C_Map.GetMapInfo) then return nil end
	local T = (Enum and Enum.UIMapType) or {}
	local id = m
	for _ = 1, 8 do
		if type(id) ~= "number" or id == 0 then return nil end
		local ok, info = pcall(C_Map.GetMapInfo, id)
		if not ok or type(info) ~= "table" then return nil end
		if info.mapType == (T.Continent or 2) then return id end
		id = info.parentMapID
	end
	return nil
end

-- /ghub test map: an entrance in your zone, else one on your continent, else the first.
function GH:TestDungeonSpot(m)
	for _, e in ipairs(ENTRANCES) do
		if e.m == m or (e.also and e.also.m == m) then return e end
	end
	local cont = ContinentOf(m)
	if cont then
		for _, e in ipairs(ENTRANCES) do
			if ContinentOf(e.m) == cont then return e end
		end
	end
	return ENTRANCES[1]
end

-- Full name of a short name ("WC" → "Wailing Caverns"), from Status.lua's instance table.
local fullNames
local function FullName(gh, short)
	if not fullNames then
		fullNames = {}
		for _, v in pairs(gh.INSTANCE_BY_ID or {}) do fullNames[v.short] = v.name end
	end
	return fullNames[short] or short
end

-- Label text: "Wailing Caverns 3" for one dungeon, "Blackrock Mountain: BRD 2 · MC 5" for a shared door.
function GH:DungeonLabelText(e, c)
	local L = ns.L
	if #e.list == 1 then
		local short = e.list[1]
		return L.MAP_DUNGEON_ONE:format(FullName(self, short), c.total)
	end
	local parts = {}
	for _, s in ipairs(e.list) do
		if c[s] then parts[#parts + 1] = ("%s %d"):format(s, c[s]) end
	end
	return L.MAP_DUNGEON_MANY:format(L.MAP_SPOT[e.name] or e.key, table.concat(parts, " · "))
end

-- Self-test: every spot's map must be an open-world zone on the REAL maps, x / y inside 0-1.
-- Returns ok, total, bad keys.
function GH:CheckEntrances()
	local ok, bad = 0, {}
	local total = 0
	local function One(key, m, x, y)
		total = total + 1
		local good = type(x) == "number" and type(y) == "number" and x > 0 and x < 1 and y > 0 and y < 1
			and self:OpenWorldMap(m)
		if good then ok = ok + 1 else bad[#bad + 1] = key end
	end
	for _, e in ipairs(ENTRANCES) do
		One(e.key, e.m, e.x, e.y)
		if e.also then One(e.key .. "2", e.also.m, e.also.x, e.also.y) end
	end
	return ok, total, bad
end
