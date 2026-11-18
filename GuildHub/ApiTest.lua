-- Guild Hub: /ghub test api. Checks which game functions this client has, for the next versions
-- (map, calendar, raid lockouts, guild log ...). One line to copy, also shown in the copy box.
-- Safety: every check runs in pcall; it never sends a message and never acts for the player.
-- Functions that would act (invite, promote, sign up) are only checked to EXIST, never called.
-- Markers: "-" = the function is missing, "!" = it raised an error, "s" = the answer was secret.
-- Names checked in Forever's API docs and UI source (plans\offline-tests\wow-ui-source, build
-- 1.60.1.70959); see plans\v040-beta1\PLAN.md sec. 4.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local LOG_WAIT = 5 -- seconds to wait for GUILD_EVENT_LOG_UPDATE / UPDATE_INSTANCE_INFO
-- quest IDs: Attunement to the Core (Molten Core), Blackhand's Command (Blackwing Lair),
-- Drakefire Amulet (Onyxia, Alliance) / Blood of the Black Dragon Champion (Onyxia, Horde)
local QUESTS = { 7848, 7761, 6502, 6602 }
-- spell IDs: Ritual of Summoning; Portal: Stormwind; Portal: Orgrimmar
local SPELLS = { 698, 10059, 11417 }

local function Secret(v) return U.IsSecret(v) end

-- Calls fn in pcall: "-" when it's missing, "!" on an error, "s" when any answer is secret,
-- else the answers.
local function Call(fn, ...)
	if type(fn) ~= "function" then return "-" end
	local r = { pcall(fn, ...) }
	if not r[1] then return "!" end
	for i = 2, #r do if Secret(r[i]) then return "s" end end
	return true, unpack(r, 2)
end

local function yn(v) return v and "y" or "n" end
local function Exists(fn) return type(fn) == "function" and "y" or "-" end
local function Has(t, k) return (type(t) == "table" and type(t[k]) == "function") and "y" or "-" end
local function Num(ok, n)
	if ok ~= true then return ok end
	if type(n) ~= "number" then return "?" end
	return tostring(n)
end

local checks = {}
local function Check(key, fn) checks[#checks + 1] = { key = key, fn = fn } end

local mapID
Check("map", function()
	local ok, m = Call(C_Map and C_Map.GetBestMapForUnit, "player")
	if ok ~= true then return ok end
	mapID = type(m) == "number" and m or nil
	return mapID and tostring(mapID) or "n"
end)
Check("pos", function()
	if not mapID then return "n" end
	local ok, p = Call(C_Map and C_Map.GetPlayerMapPosition, mapID, "player")
	if ok ~= true then return ok end
	if type(p) ~= "table" and type(p) ~= "userdata" then return "n" end
	local okX, x, y = pcall(function() return p:GetXY() end)
	if not okX then return "!" end
	if Secret(x) or Secret(y) then return "s" end
	return yn(type(x) == "number" and type(y) == "number")
end)
Check("wp", function()
	if not mapID then return "n" end
	local ok, v = Call(C_Map and C_Map.CanSetUserWaypointOnMap, mapID)
	if ok ~= true then return ok end
	return yn(v)
end)
Check("ent", function()
	if not mapID or not (C_Map and C_Map.GetMapInfo) then return "-" end
	-- the continent above our map
	local id, cont = mapID, nil
	for _ = 1, 6 do
		local ok, info = Call(C_Map.GetMapInfo, id)
		if ok ~= true or type(info) ~= "table" then break end
		if info.mapType == 2 then cont = id break end -- Enum.UIMapType.Continent
		if not info.parentMapID or info.parentMapID == 0 then break end
		id = info.parentMapID
	end
	local ok, list = Call(C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap, cont or mapID)
	if ok ~= true then return ok end
	return type(list) == "table" and tostring(#list) or "n"
end)
Check("canvas", function()
	return yn(WorldMapFrame and type(WorldMapFrame.AddDataProvider) == "function" and MapCanvasDataProviderMixin ~= nil)
end)
Check("mm", function()
	local shape = "ROUND"
	if type(GetMinimapShape) == "function" then
		local ok, s = Call(GetMinimapShape)
		shape = ok == true and tostring(s) or ok
	end
	local ok, rot = Call(GetCVar, "rotateMinimap")
	return shape .. "/" .. (ok == true and tostring(rot) or ok)
end)
Check("cal", function()
	if type(C_Calendar) ~= "table" then return "-" end
	local okN, n = Call(C_Calendar.GetNumGuildEvents)
	return ("y,%s,%s,%s"):format(Num(okN, n), Has(C_Calendar, "EventSignUp"),
		(type(ToggleCalendar) == "function" or type(Calendar_Toggle) == "function") and "y" or "-")
end)
Check("log", function(state)
	if state.logCount ~= nil then return state.logCount end
	return Exists(GetNumGuildEvents) == "y" and "?" or "-"
end)
Check("news", function() return Num(Call(GetNumGuildNews)) end)
Check("ach", function()
	local ok, v = Call(AreGuildAchievementsEnabled)
	if ok ~= true then return ok end
	return yn(v)
end)
Check("ask", function() return Has(C_PartyInfo, "RequestInviteFromUnit") end) -- never called
Check("lfg", function()
	local a = Has(C_LFGList, "GetActiveEntryInfo")
	local ok, v = Call(C_LFGList and C_LFGList.HasActiveEntryInfo)
	return a .. "," .. (ok == true and yn(v) or ok)
end)
Check("quest", function()
	local okN, n = Call(C_QuestLog and C_QuestLog.GetNumQuestLogEntries)
	local fn = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
	local bits = {}
	for _, id in ipairs(QUESTS) do
		local ok, v = Call(fn, id)
		bits[#bits + 1] = ok == true and (v and "1" or "0") or ok
	end
	return Num(okN, n) .. "," .. table.concat(bits)
end)
Check("kill", function()
	local valid = "-"
	if C_EventUtils and C_EventUtils.IsEventValid then
		local ok, v = Call(C_EventUtils.IsEventValid, "ENCOUNTER_END")
		valid = ok == true and yn(v) or ok
	end
	local gdb = GH:GetGuildDB()
	local k = gdb and gdb.rec and gdb.rec.kills and gdb.rec.kills[1]
	return valid .. "," .. (k and "y" or "-") -- "y" only: the report has no names
end)
Check("lock", function()
	local okN, n = Call(GetNumSavedInstances)
	if okN ~= true then return okN end
	if type(n) ~= "number" or n < 1 then return tostring(n or "?") .. ",-" end
	local ok, name, _, reset, _, locked = Call(GetSavedInstanceInfo, 1)
	if ok ~= true then return n .. "," .. ok end
	return n .. "," .. yn(type(name) == "string" and type(reset) == "number" and type(locked) == "boolean")
end)
Check("res", function()
	if type(UnitResistance) ~= "function" then return "-" end
	local r = {}
	for i = 2, 6 do
		local ok, _, total = Call(UnitResistance, "player", i)
		r[#r + 1] = ok == true and tostring(type(total) == "number" and total or "?") or ok
	end
	return table.concat(r, "/")
end)
Check("hearth", function()
	local ok, s = Call(GetBindLocation)
	if ok ~= true then return ok end
	return yn(type(s) == "string")
end)
Check("ign", function()
	local ok, n = Call(C_FriendList and C_FriendList.GetNumIgnores)
	return Has(C_FriendList, "IsIgnored") .. "," .. Num(ok, n)
end)
Check("off", function()
	local ok, v = Call(C_GuildInfo and C_GuildInfo.CanEditOfficerNote)
	local a = ok == true and yn(v) or ok
	local okV, vv = Call(CanViewOfficerNote or (C_GuildInfo and C_GuildInfo.CanViewOfficerNote))
	local b = okV == true and yn(vv) or okV
	return a .. "," .. b .. "," .. Exists(CanGuildPromote) -- promote: never called
end)
Check("motd", function()
	local ok, s = Call((C_GuildInfo and C_GuildInfo.GetMOTD) or GetGuildRosterMOTD)
	if ok ~= true then return ok end
	return yn(type(s) == "string")
end)
Check("ej", function() return Has(C_EncounterJournal, "GetLootInfoByIndex") end)
Check("gbank", function() return yn(type(C_GuildBank) == "table") end)
Check("rep", function()
	local ok, t = Call(C_Reputation and C_Reputation.GetFactionDataByID, 529)
	if ok ~= true then return ok end
	return yn(type(t) == "table")
end)
Check("mount", function() return Has(C_MountJournal, "GetNumMounts") end)
Check("time", function() return Exists(GameTime_GetFormattedTime) end)
Check("spell", function()
	local fn = (C_SpellBook and C_SpellBook.IsSpellKnown) or IsSpellKnown
	local r = {}
	for _, id in ipairs(SPELLS) do
		local ok, v = Call(fn, id)
		r[#r + 1] = ok == true and yn(v) or ok
	end
	return table.concat(r, ",")
end)
Check("ochat", function()
	local ok, v = Call(C_GuildInfo and C_GuildInfo.CanSpeakInOfficerChat)
	if ok ~= true then return ok end
	return yn(v)
end)
Check("lastonline", function() return Exists(GetGuildRosterLastOnline) end)
Check("calday", function(state)
	return state.calday or "-"
end)
Check("qtitle", function()
	local ok, t = Call(C_QuestLog and C_QuestLog.GetTitleForQuestID, QUESTS[2])
	local a = ok == true and yn(type(t) == "string") or ok
	return a .. "," .. Has(C_QuestLog, "RequestLoadQuestByID")
end)
Check("pvp", function()
	local a = (type(GetNumBattlegroundTypes) == "function" or type(C_PvP) == "table") and "y" or "-"
	local ok, s = Call(GetBattlefieldStatus, 1)
	return a .. "," .. (ok == true and tostring(s or "none") or ok)
end)
Check("pet", function() return Has(C_PetJournal, "GetNumPets") end)
Check("xmog", function() return yn(type(C_TransmogCollection) == "table") end)
Check("role", function()
	local ok, r = Call(UnitGroupRolesAssigned, "player")
	return (ok == true and tostring(r or "NONE") or ok) .. "," .. Exists(GetSpecialization)
end)
Check("emote", function()
	local valid = "-"
	if C_EventUtils and C_EventUtils.IsEventValid then
		local ok, v = Call(C_EventUtils.IsEventValid, "CHAT_MSG_TEXT_EMOTE")
		valid = ok == true and yn(v) or ok
	end
	local ok, lock = Call(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown)
	return valid .. "," .. (ok == true and yn(lock) or ok)
end)
Check("fish", function() return Exists(IsFishingLoot) end)
GH.API_CHECKS = checks

-- Guild calendar events in the next 14 days (after OpenCalendar has loaded the data).
local function CountCalendar()
	if type(C_Calendar) ~= "table" or type(C_Calendar.GetNumDayEvents) ~= "function" then return "-" end
	local okD, today = Call(C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime)
	if okD ~= true or type(today) ~= "table" then return "-" end
	local okM, info = Call(C_Calendar.GetMonthInfo, 0)
	local days = (okM == true and type(info) == "table" and info.numDays) or 31
	local n = 0
	for i = 0, 13 do
		local day, offset = today.monthDay + i, 0
		if day > days then day, offset = day - days, 1 end
		local ok, count = Call(C_Calendar.GetNumDayEvents, offset, day)
		if ok ~= true then return ok end
		for j = 1, (type(count) == "number" and count or 0) do
			local okE, e = Call(C_Calendar.GetDayEvent, offset, day, j)
			if okE == true and type(e) == "table" and (e.calendarType == "GUILD_EVENT" or e.calendarType == "GUILD_ANNOUNCEMENT") then
				n = n + 1
			end
		end
	end
	return tostring(n)
end

-- Runs every check; returns the line.
function GH:ApiLine(state)
	state = state or {}
	local parts = {}
	for _, c in ipairs(checks) do
		local ok, v = pcall(c.fn, state)
		parts[#parts + 1] = c.key .. "=" .. (ok and tostring(v) or "!")
	end
	return table.concat(parts, " ")
end

local function Finish(state)
	if GH.apiTestRunning ~= state then return end
	GH:Off("apitest")
	GH.apiTestRunning = nil
	state.calday = CountCalendar()
	local line = L.TEST_API:format(GH:ApiLine(state))
	GH:Msg(line)
	GH.lastApiLine = line
	local st = ns.SelfTest
	if st and st.ShowCopyBox then pcall(st.ShowCopyBox, L.PREFIX .. line) end
end

function GH:TestApi()
	if self.apiTestRunning then return end
	if InCombatLockdown() then
		self:Msg(L.SELFTEST_WAIT)
		self:On("apitest", "PLAYER_REGEN_ENABLED", function()
			GH:Off("apitest")
			GH:TestApi()
		end)
		return
	end
	local state = {}
	self.apiTestRunning = state
	self:Msg(L.TEST_API_WAIT)
	local waiting = 0
	local function Done()
		waiting = waiting - 1
		if waiting <= 0 then Finish(state) end
	end
	-- the guild event log and raid lockouts arrive as events
	if type(QueryGuildEventLog) == "function" and IsInGuild() then
		waiting = waiting + 1
		self:On("apitest", "GUILD_EVENT_LOG_UPDATE", function()
			if state.logCount then return end
			state.logCount = Num(Call(GetNumGuildEvents))
			GH:Off("apitest", "GUILD_EVENT_LOG_UPDATE")
			Done()
		end)
		pcall(QueryGuildEventLog)
	end
	if type(RequestRaidInfo) == "function" then
		waiting = waiting + 1
		self:On("apitest", "UPDATE_INSTANCE_INFO", function()
			GH:Off("apitest", "UPDATE_INSTANCE_INFO")
			Done()
		end)
		pcall(RequestRaidInfo)
	end
	if C_Calendar and type(C_Calendar.OpenCalendar) == "function" then pcall(C_Calendar.OpenCalendar) end
	-- at the latest after LOG_WAIT seconds
	C_Timer.After(LOG_WAIT, function() Finish(state) end)
	if waiting == 0 then C_Timer.After(1, function() Finish(state) end) end
end
