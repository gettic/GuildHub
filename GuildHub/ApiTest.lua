-- Guild Hub: /ghub test api. Checks which game functions this client has, for the next versions
-- (map, calendar, raid lockouts, guild log ...). One line to copy, also shown in the copy box.
-- Safety: every check runs in pcall; it never sends a message and never acts for the player.
-- Functions that would act (invite, promote, sign up) are only checked to EXIST, never called.
-- Real calls are harmless reads only (QueryGuildEventLog, RequestRaidInfo, C_Calendar.OpenCalendar,
-- C_QuestLog.RequestLoadQuestByID).
-- Markers: "-" = the function is missing, "!" = it raised an error, "s" = the answer was secret.
-- Names checked in Forever's API docs and UI source (plans\offline-tests\wow-ui-source, build
-- 1.60.1.70959); see plans\v040-beta1\PLAN.md sec. 4.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local LOG_WAIT = 5 -- seconds to wait for GUILD_EVENT_LOG_UPDATE / UPDATE_INSTANCE_INFO
-- quest IDs (1.0.0-beta.1: WoW Forever has no MC or BWL, so their attunements are gone; Barrow Deeps /
-- Hyjal Summit quest IDs aren't known yet):
-- Drakefire Amulet (Onyxia, Alliance) / Blood of the Black Dragon Champion (Onyxia, Horde)
local QUESTS = { 6502, 6602 }
-- spell IDs: Ritual of Summoning; Portal: Stormwind; Portal: Orgrimmar
local SPELLS = { 698, 10059, 11417 }
-- 0.4.0-b3 controls, so a "n" can be told apart from a check that never works:
local SPELL_CONTROL = 6603 -- Auto Attack, every character knows it (else: the first spellbook spell)
-- zones with dungeon entrances: Burning Steppes (Blackrock Mountain), The Barrens, Badlands
local ENTRANCE_MAPS = { 1428, 1413, 1418 }

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
-- 0.4.0-b3: entrances on our zone / its continent / three zones that have some (Blizzard's map asks
-- for the map it shows); "zone/continent/known"
Check("ent", function()
	local fn = C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap
	if type(fn) ~= "function" then return "-" end
	local function Entrances(id)
		if not id then return "n" end
		local ok, list = Call(fn, id)
		if ok ~= true then return ok end
		return type(list) == "table" and tostring(#list) or "n"
	end
	-- the continent above our map
	local cont = "n"
	if mapID and C_Map and C_Map.GetMapInfo then
		local id = mapID
		for _ = 1, 6 do
			local ok, info = Call(C_Map.GetMapInfo, id)
			if ok ~= true then cont = ok break end
			if type(info) ~= "table" then break end
			if info.mapType == 2 then cont = Entrances(id) break end -- Enum.UIMapType.Continent
			if not info.parentMapID or info.parentMapID == 0 then break end
			id = info.parentMapID
		end
	end
	local known = 0
	for _, id in ipairs(ENTRANCE_MAPS) do
		local n = Entrances(id)
		if tonumber(n) then known = known + tonumber(n) elseif n ~= "n" then known = n break end
	end
	return Entrances(mapID) .. "/" .. cont .. "/" .. tostring(known)
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
	-- 0.4.0-b3 control: how many quests the game says this character has done (0 on a new one)
	local okA, all = Call(C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs)
	local done = okA == true and (type(all) == "table" and tostring(#all) or "n") or okA
	return Num(okN, n) .. "," .. table.concat(bits) .. "," .. done
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
	-- only "does it exist": calling it is blocked for addons (restricted, ADDON_ACTION_BLOCKED);
	-- the add-on reads the message of the day from the GUILD_MOTD event instead (seen = y/n)
	return Exists(C_GuildInfo and C_GuildInfo.GetMOTD) .. "," .. yn(type(GH.lastMOTD) == "string")
end)
Check("ej", function() return Has(C_EncounterJournal, "GetLootInfoByIndex") end)
-- 0.4.0-b3: the table alone is in every modern client; also the bank functions and Blizzard's bank UI
Check("gbank", function()
	local okE, e = Call(C_AddOns and C_AddOns.DoesAddOnExist, "Blizzard_GuildBankUI")
	return yn(type(C_GuildBank) == "table") .. "," .. Exists(GetNumGuildBankTabs) .. ","
		.. (okE == true and yn(e) or okE)
end)
Check("rep", function()
	local ok, t = Call(C_Reputation and C_Reputation.GetFactionDataByID, 529)
	if ok ~= true then return ok end
	return yn(type(t) == "table")
end)
Check("mount", function() -- 0.4.0-b3: the count, not only the name
	return Has(C_MountJournal, "GetNumMounts") .. "," .. Num(Call(C_MountJournal and C_MountJournal.GetNumMounts))
end)
Check("time", function() return Exists(GameTime_GetFormattedTime) end)
-- 0.4.0-b3: "CLASS,control:summon,portal SW,portal Org" (control = a spell this character surely knows)
Check("spell", function()
	local fn = (C_SpellBook and C_SpellBook.IsSpellKnown) or IsSpellKnown
	local okC, _, class = Call(UnitClass, "player")
	class = (okC == true and type(class) == "string") and class or "?"
	local okK, known = Call(fn, SPELL_CONTROL)
	local control = okK == true and yn(known) or okK
	if control == "n" and C_SpellBook and Enum and Enum.SpellBookSpellBank then
		local okI, info = Call(C_SpellBook.GetSpellBookItemInfo, 1, Enum.SpellBookSpellBank.Player)
		if okI == true and type(info) == "table" and type(info.spellID) == "number" then
			local okB, v = Call(fn, info.spellID)
			control = okB == true and (v and "b" or "n") or okB -- b = the first spellbook spell is known
		end
	end
	local r = {}
	for _, id in ipairs(SPELLS) do
		local ok, v = Call(fn, id)
		r[#r + 1] = ok == true and yn(v) or ok
	end
	return class .. "," .. control .. ":" .. table.concat(r, ",")
end)
-- 0.4.0-b3: + the own rank's permission flags (the numbers that are on), to find the officer-chat one
Check("ochat", function()
	local ok, v = Call(C_GuildInfo and C_GuildInfo.CanSpeakInOfficerChat)
	local a = ok == true and yn(v) or ok
	local flags = "-"
	local fn = C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags
	if type(fn) == "function" then
		local okR, _, _, rankIndex = Call(GetGuildInfo, "player")
		if okR ~= true then flags = okR
		elseif type(rankIndex) ~= "number" then flags = "n"
		else
			local okF, t = Call(fn, rankIndex + 1)
			if okF ~= true then flags = okF
			elseif type(t) ~= "table" then flags = "n"
			else
				local on = {}
				for i = 1, 40 do if t[i] == true then on[#on + 1] = tostring(i) end end
				flags = #on > 0 and table.concat(on, ".") or "0"
			end
		end
	end
	return a .. "," .. flags
end)
-- 0.4.0-b3: + does it give plain numbers for the first offline member (no names in the line)
Check("lastonline", function()
	local has = Exists(GetGuildRosterLastOnline)
	if has ~= "y" then return has end
	local okN, n = Call(GetNumGuildMembers)
	if okN ~= true or type(n) ~= "number" then return has .. "," .. (okN == true and "?" or okN) end
	for i = 1, math.min(n, 1000) do
		local okI, _, _, _, _, _, _, _, _, online = Call(GetGuildRosterInfo, i)
		if okI == "s" then return has .. ",s" end
		if okI == true and online == false then
			local ok, y, mo, d, h = Call(GetGuildRosterLastOnline, i)
			if ok ~= true then return has .. "," .. ok end
			local any = type(y) == "number" or type(mo) == "number" or type(d) == "number" or type(h) == "number"
			return has .. "," .. yn(any)
		end
	end
	return has .. ",-" -- nobody offline
end)
Check("calday", function(state)
	return state.calday or "-"
end)
-- 0.4.0-b3: "title now, load function exists, load answer" (TestApi asks the game to load the quest
-- first and waits for QUEST_DATA_LOAD_RESULT: y = loaded, n = failed, - = no answer in time)
Check("qtitle", function(state)
	local ok, t = Call(C_QuestLog and C_QuestLog.GetTitleForQuestID, QUESTS[2])
	local a = ok == true and yn(type(t) == "string") or ok
	return a .. "," .. Has(C_QuestLog, "RequestLoadQuestByID") .. "," .. tostring(state.qload or "-")
end)
-- 0.4.0-b3: the number of battleground types (C_PvP alone is in every modern client)
Check("pvp", function()
	local a = Num(Call(GetNumBattlegroundTypes))
	local ok, s = Call(GetBattlefieldStatus, 1)
	return a .. "," .. (ok == true and tostring(s or "none") or ok)
end)
Check("pet", function() -- 0.4.0-b3: the counts (all, owned), not only the name
	local ok, all, owned = Call(C_PetJournal and C_PetJournal.GetNumPets)
	if ok ~= true then return Has(C_PetJournal, "GetNumPets") .. "," .. ok end
	return "y," .. Num(true, all) .. "/" .. Num(true, owned)
end)
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
-- 0.4.0-b2: HereBeDragons loaded, its pins on the world map, and the ignore check on our own name
-- 1.0.0-beta.1: new instances entered this session (ID@map:x,y of the spot before going in; memory only)
Check("newdng", function() return GH:NewDungeonText(true) end)
Check("hbd", function()
	local core = LibStub and LibStub("HereBeDragons-2.0", true)
	local pins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
	local onMap = pins and WorldMapFrame and type(WorldMapFrame.dataProviders) == "table"
		and pins.worldmapProvider and WorldMapFrame.dataProviders[pins.worldmapProvider] and "y" or "n"
	local okI = GH.IsIgnored and pcall(GH.IsIgnored, GH, GH:MyName())
	return yn(core) .. "," .. yn(pins) .. "," .. (pins and onMap or "-") .. "," .. (okI and tostring(GH.ignoreMode or "?") or "!")
end)
-- Guild Recruiter R1 (plans\guild-recruiter\PLAN.md sec. 7b/8): nothing here sends or acts.
-- cf: Guild Finder on? (IsEnabled, disable reason given?, ToggleGuildFinder exists)
Check("cf", function()
	local ok, on = Call(C_ClubFinder and C_ClubFinder.IsEnabled)
	local okR, why = Call(C_ClubFinder and C_ClubFinder.GetClubFinderDisableReason)
	return (ok == true and yn(on) or ok) .. "," .. (okR == true and (why == nil and "none" or tostring(why)) or okR)
		.. "," .. Exists(ToggleGuildFinder)
end)
-- ratl: role atlases found of 3, class atlases found of 9, CLASS_ICON_TCOORDS there (fallback)
Check("ratl", function()
	local W = ns.Widgets
	local roles, classes = 0, 0
	for _, a in pairs(W.ART.roles.atlas) do if W.HasAtlas(a) then roles = roles + 1 end end
	for _, c in ipairs(GH.RECRUIT_CLASSES or {}) do if W.HasAtlas(W.ART.classes.atlasPrefix .. c:lower()) then classes = classes + 1 end end
	return roles .. "/3," .. classes .. "/9," .. yn(type(CLASS_ICON_TCOORDS) == "table")
end)
-- tabard: the function exists and runs on three test textures (nothing is shown)
local tabardFrame
Check("tabard", function()
	if type(SetLargeGuildTabardTextures) ~= "function" then return "-" end
	tabardFrame = tabardFrame or CreateFrame("Frame")
	local t1, t2, t3 = tabardFrame:CreateTexture(), tabardFrame:CreateTexture(), tabardFrame:CreateTexture()
	local ok = pcall(SetLargeGuildTabardTextures, "player", t1, t2, t3)
	return "y," .. (ok and "ok" or "!")
end)
-- ginv: may we invite (answer), C_GuildInfo.Invite exists (never called)
Check("ginv", function()
	local ok, v = Call(CanGuildInvite)
	return (ok == true and yn(v) or ok) .. "," .. Has(C_GuildInfo, "Invite")
end)
-- menu: the name-menu and chat-filter functions the next betas need
Check("menu", function()
	return Has(Menu, "ModifyMenu") .. "," .. Has(ChatFrameUtil, "AddMessageEventFilter")
end)
-- adapi: C_ChatInfo.SendChatMessage exists (never called here), chat lockdown now
Check("adapi", function()
	local ok, lock = Call(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown)
	return Has(C_ChatInfo, "SendChatMessage") .. "," .. (ok == true and yn(lock) or ok)
end)
-- adch: the game's world channels you are in, "number:name" (custom channels only counted, no names)
local WORLD = { "general", "trade", "lookingforgroup", "guildrecruitment", "localdefense", "worlddefense", "services" }
Check("adch", function()
	if type(GetChannelName) ~= "function" then return "-" end
	local parts, other = {}, 0
	for i = 1, 20 do
		local ok, id, name = Call(GetChannelName, i)
		if ok == "s" then parts[#parts + 1] = i .. ":s"
		elseif ok == true and type(id) == "number" and id > 0 and type(name) == "string" then
			local low = name:lower():gsub("%s", "")
			local world = false
			for _, w in ipairs(WORLD) do if low:sub(1, #w) == w then world = true break end end
			if world then parts[#parts + 1] = id .. ":" .. (U.CleanText(name, 40) or "?"):gsub("[ ,=]", "_")
			else other = other + 1 end
		end
	end
	return (#parts > 0 and table.concat(parts, ";") or "0") .. ",+" .. other
end)
-- mac: macro functions, used/max character macros, the 6 icon files found
Check("mac", function()
	local fns = Exists(CreateMacro) .. Exists(EditMacro) .. Exists(PickupMacro)
	local used, max = "?", "?"
	if GH.MacroSlots then
		local okS, u, m = pcall(GH.MacroSlots, GH)
		if okS and u then used, max = tostring(u), tostring(m) end
	end
	local acct = Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_ACCOUNT_MACROS
	local icons = 0
	for _, n in ipairs(GH.RECRUIT_ICONS or {}) do
		local ok, id = Call(GetFileIDFromPath, "Interface\\Icons\\" .. n)
		if ok == true and type(id) == "number" and id > 0 then icons = icons + 1 end
	end
	return fns .. "," .. used .. "/" .. max .. "," .. tostring(acct or "?") .. "," .. icons .. "/" .. #(GH.RECRUIT_ICONS or {})
end)
-- rmcm: the restriction flags Forever's own API docs give C_ChatInfo.SendChatMessage (the docs
-- addon is loaded on demand, out of combat; nothing is called). HR = HasRestrictions,
-- RMCM = RestrictedForMacroChatMessages, AWU = AllowedWhenUntainted
Check("rmcm", function(state)
	if state.rmcm then return state.rmcm end
	if InCombatLockdown() or not (C_AddOns and type(C_AddOns.LoadAddOn) == "function") then return "-" end
	local okL = pcall(C_AddOns.LoadAddOn, "Blizzard_APIDocumentationGenerated")
	local doc = _G.APIDocumentation
	if not okL or type(doc) ~= "table" or type(doc.systems) ~= "table" then return "n" end
	for _, sys in ipairs(doc.systems) do
		if type(sys) == "table" and sys.Namespace == "C_ChatInfo" then
			for _, fn in ipairs(sys.Functions or {}) do
				if type(fn) == "table" and fn.Name == "SendChatMessage" then
					local f = {}
					if fn.HasRestrictions then f[#f + 1] = "HR" end
					if fn.RestrictedForMacroChatMessages then f[#f + 1] = "RMCM" end
					if fn.SecretArguments == "AllowedWhenUntainted" then f[#f + 1] = "AWU" end
					state.rmcm = "y:" .. (#f > 0 and table.concat(f, ".") or "none")
					return state.rmcm
				end
			end
			return "y:nofn"
		end
	end
	return "y:nosys"
end)
-- tpost: the last /ghub test post result (key:sent,echo:y = the macro key press works)
Check("tpost", function()
	local c = GH.db and GH.db.global and GH.db.global.recruitCaps
	return type(c) == "table" and type(c.testPost) == "string" and c.testPost:gsub("^post=", "") or "-"
end)

-- R7 probe (PLAN.md 11.3, tos-new-ideas.md 3 "probe before building"): are whispers readable on
-- Forever, out of combat, in combat and in instances? A passive counter from file load: it only
-- COUNTS CHAT_MSG_WHISPER events (no Battle.net whispers, no other events). Memory only; no name,
-- text or GUID is kept, compared or sent. Nothing is hidden from chat (no filter).
-- Line: wsec=N:a/b,c/d,e/f,gG  N = whispers seen this session; a/b = secret author or text / seen
-- out of combat outside instances, c/d = the same in combat, e/f = in an instance (combat wins);
-- G = whispers whose sender GUID was secret.
local wsec = { n = 0, normal = { 0, 0 }, combat = { 0, 0 }, inst = { 0, 0 }, guid = 0 }
GH.wsecStats = wsec
local function CountWhisper(_, text, author, ...)
	wsec.n = wsec.n + 1
	local where = wsec.normal
	if InCombatLockdown() then where = wsec.combat
	else
		local okI, inInst = pcall(IsInInstance)
		if okI and inInst == true then where = wsec.inst end
	end
	where[2] = where[2] + 1
	if Secret(text) or Secret(author) then where[1] = where[1] + 1 end
	local guid = select(10, ...) -- arg 12 of the event
	if Secret(guid) then wsec.guid = wsec.guid + 1 end
end
GH:On("wsec", "CHAT_MSG_WHISPER", CountWhisper)
Check("wsec", function()
	return ("%d:%d/%d,%d/%d,%d/%d,g%d"):format(wsec.n, wsec.normal[1], wsec.normal[2], wsec.combat[1], wsec.combat[2],
		wsec.inst[1], wsec.inst[2], wsec.guid)
end)

------------------------------------------------------------------------
-- 1.0.0-beta.2 probes (plans\next-beta-3 PLAN.md "Probes", tos-check.md: all read-only). None of them
-- sends, searches, opens or inspects anything; no name or chat text is printed or kept.
------------------------------------------------------------------------
local function Valid(event)
	if not (C_EventUtils and C_EventUtils.IsEventValid) then return "-" end
	local ok, v = Call(C_EventUtils.IsEventValid, event)
	return ok == true and yn(v) or ok
end
-- grecipe: guild recipe lookup functions exist (never called: a query would ask the server) + its event
Check("grecipe", function()
	return Has(C_GuildInfo, "QueryGuildMembersForRecipe") .. "," .. Exists(GetGuildRecipeMember) .. ","
		.. Valid("GUILD_RECIPE_KNOWN_BY_MEMBERS")
end)
-- lfgnames: the LFG list result functions; only if results are ALREADY there (no search is started),
-- ONE result's leader name is reported as name / secret / nil (the name itself never)
Check("lfgnames", function()
	local a = Has(C_LFGList, "GetSearchResults") .. Has(C_LFGList, "GetSearchResultInfo")
	local ok, n, list = Call(C_LFGList and C_LFGList.GetSearchResults)
	if ok ~= true then return a .. "," .. ok end
	local id = type(list) == "table" and list[1]
	if type(n) ~= "number" or n < 1 or id == nil then return a .. ",0" end
	local okI, info = pcall(C_LFGList.GetSearchResultInfo, id)
	if not okI then return a .. "," .. n .. ",!" end
	if Secret(info) then return a .. "," .. n .. ",secret" end
	local leader = type(info) == "table" and info.leaderName
	local kind = Secret(leader) and "secret" or (type(leader) == "string" and "name" or "nil")
	return a .. "," .. n .. "," .. kind
end)
-- gbui: GetNumGuildBankTabs (type:value), Blizzard's bank addon info, the bank-opened event (the
-- older `gbank` key stays as it was)
Check("gbui", function()
	local okN, n = Call(GetNumGuildBankTabs)
	local tabs = okN == true and (type(n) .. ":" .. tostring(type(n) == "number" and n or "-")) or okN
	local okA, name, _, _, loadable, reason = Call(C_AddOns and C_AddOns.GetAddOnInfo, "Blizzard_GuildBankUI")
	local addon = okA == true and (yn(type(name) == "string") .. (loadable and "L" or "") .. (reason and ("/" .. tostring(reason)) or "")) or okA
	return tabs .. "," .. addon .. "," .. Valid("GUILDBANKFRAME_OPENED")
end)
-- gchat: guild / officer chat lines seen this session and how many were secret (counts only;
-- no text, author or GUID is kept or compared). Line: gchat=guild seen:secret,officer seen:secret
local gchat = { g = { 0, 0 }, o = { 0, 0 } }
GH.gchatStats = gchat
local function CountGuildChat(event, text, author)
	local c = event == "CHAT_MSG_OFFICER" and gchat.o or gchat.g
	c[1] = c[1] + 1
	if Secret(text) or Secret(author) then c[2] = c[2] + 1 end
end
GH:On("gchat", "CHAT_MSG_GUILD", CountGuildChat)
GH:On("gchat", "CHAT_MSG_OFFICER", CountGuildChat)
Check("gchat", function()
	return ("%d:%d,%d:%d"):format(gchat.g[1], gchat.g[2], gchat.o[1], gchat.o[2])
end)
-- talents: own points per tree ("31/20/0"); only this character, nobody is inspected
Check("talents", function()
	local okN, n = Call(GetNumTalentTabs)
	if okN ~= true then return okN end
	if type(n) ~= "number" or n < 1 then return "0" end
	local pts = {}
	for i = 1, math.min(n, 5) do
		local ok, a, _, c, _, e = Call(GetTalentTabInfo, i)
		if ok ~= true then pts[#pts + 1] = ok
		else
			-- classic order: name, icon, points, file; newer: id, name, description, icon, points
			local p = type(a) == "string" and c or e
			pts[#pts + 1] = type(p) == "number" and tostring(p) or "?"
		end
	end
	return table.concat(pts, "/")
end)
-- logging: type of LoggingCombat, is that global still Blizzard's, and C_ChatInfo.IsLoggingCombat()
-- (a pure read). LoggingCombat itself is NEVER called (tos: not even without an argument).
Check("logging", function()
	local t = type(LoggingCombat)
	local sec = "-"
	if type(issecurevariable) == "function" then
		local ok, s = pcall(issecurevariable, "LoggingCombat")
		sec = ok and yn(s) or "!"
	end
	local okL, on = Call(C_ChatInfo and C_ChatInfo.IsLoggingCombat)
	return t .. "," .. sec .. "," .. (okL == true and yn(on) or okL)
end)
-- n6: the guild rank slash commands exist (promote/demote/remove) and the rank checks exist (only
-- type(): this test calls none of them; the name menu asks Can* when it is built)
Check("n6", function()
	local s = ""
	for _, k in ipairs({ "SLASH_GUILD_PROMOTE1", "SLASH_GUILD_DEMOTE1", "SLASH_GUILD_UNINVITE1" }) do
		s = s .. (type(_G[k]) == "string" and "y" or "-")
	end
	return s .. "," .. Exists(CanGuildPromote) .. Exists(CanGuildDemote) .. Exists(CanGuildRemove)
end)

------------------------------------------------------------------------
-- 1.0.1 probes (plans\next-batch-1.0.x PLAN.md sec. 5; tos-check.md: read-only; calx only type()s the
-- acting calendar functions; rraid never prints a zone or a name)
------------------------------------------------------------------------
-- lockx: saved instances "n" then per entry: our raid y/n, reset plain/secret, killed/bosses, 14th return y/n
Check("lockx", function()
	local okN, n = Call(GetNumSavedInstances)
	if okN ~= true then return okN end
	if type(n) ~= "number" then return "?" end
	local parts = { tostring(n) }
	for i = 1, math.min(n, 4) do
		local r = { pcall(GetSavedInstanceInfo, i) }
		if not r[1] then parts[#parts + 1] = "!"
		else
			local name, reset, numEnc, prog, inst = r[2], r[4], r[12], r[13], r[15]
			local ours = not Secret(name) and GH.RAID_BY_NAME and GH.RAID_BY_NAME[name] and "y" or "n"
			local rs = Secret(reset) and "s" or (type(reset) == "number" and "p" or "-")
			local kp = (type(prog) == "number" and not Secret(prog) and prog or "?") .. "/" .. (type(numEnc) == "number" and not Secret(numEnc) and numEnc or "?")
			parts[#parts + 1] = ours .. rs .. kp .. (inst ~= nil and "i" or "")
		end
	end
	return table.concat(parts, ",")
end)
-- attune: the Onyxia chain for our faction: last step done / steps
Check("attune", function()
	local done = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
	if type(done) ~= "function" then return "-" end
	local at = GH.OwnAttune and GH:OwnAttune()
	if not at then return "?" end
	local fac, step = at:match("^(%a)(%d+)$")
	return (fac or "?") .. (step or "?") .. "/" .. tostring(GH.ATTUNE and fac and #GH.ATTUNE[fac] or "?")
end)
-- dura: lowest durability % (10 % steps) and whether any slot answered secret
Check("dura", function()
	if type(GetInventoryItemDurability) ~= "function" then return "-" end
	local secret = false
	for slot = 1, 18 do
		local ok, cur, max = pcall(GetInventoryItemDurability, slot)
		if ok and (Secret(cur) or Secret(max)) then secret = true end
	end
	local d = GH.OwnDurability and GH:OwnDurability()
	return tostring(d or "?") .. (secret and ",s" or "")
end)
-- reag: class token, the class reagent's count (or "none"), item name loaded y/n
Check("reag", function()
	local ok, _, token = Call(UnitClass, "player")
	if ok ~= true then return ok end
	local id = GH.REAGENTS and GH.REAGENTS[token or ""]
	if not id then return tostring(token) .. ",none" end
	local n = GH.OwnReagents and GH:OwnReagents()
	local okN, name = Call(C_Item and C_Item.GetItemNameByID, id)
	return ("%s,%d=%s,%s"):format(tostring(token), id, tostring(n or "?"), okN == true and yn(type(name) == "string") or okN)
end)
-- calx: the next guild event's numbers only (calendarType, inviteType, inviteStatus; never the title)
-- and whether the answer functions exist (type() only: none of them is called here)
Check("calx", function()
	local C = C_Calendar
	local fns = Has(C, "OpenEvent") .. Has(C, "ContextMenuSelectEvent") .. Has(C, "ContextMenuEventSignUp")
		.. Has(C, "ContextMenuInviteAvailable") .. Has(C, "ContextMenuInviteTentative") .. Has(C, "ContextMenuInviteDecline")
		.. Has(C, "EventGetInvite") .. Has(C, "CloseEvent")
	local ev = GH.FindTonightEvent and select(1, GH:FindTonightEvent())
	if not ev then return fns .. ",none" end
	return ("%s,%s/%s/%s"):format(fns, tostring(ev.calendarType), tostring(ev.inviteType), tostring(ev.inviteStatus))
end)
-- rraid: in a raid, GetRaidRosterInfo(1)'s zone: plain / secret / nil (never printed)
Check("rraid", function()
	if not (IsInRaid and IsInRaid()) then return "n" end
	local r = { pcall(GetRaidRosterInfo, 1) }
	if not r[1] then return "!" end
	local zone = r[8]
	return Secret(zone) and "secret" or (type(zone) == "string" and "plain" or "nil")
end)
-- rez: the alive events are valid and UnitIsDeadOrGhost answers plainly
Check("rez", function()
	local okD, dead = Call(UnitIsDeadOrGhost, "player")
	local d = okD == true and (type(dead) == "boolean" and "p" or "?") or okD
	return Valid("PLAYER_ALIVE") .. Valid("PLAYER_UNGHOST") .. "," .. d
end)
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
	-- 0.4.0-b3: ask the game for a quest that isn't in the log (a harmless read), for `qtitle`
	if self.apiTestRunning == state and C_QuestLog and type(C_QuestLog.RequestLoadQuestByID) == "function" then
		waiting = waiting + 1
		self:On("apitest", "QUEST_DATA_LOAD_RESULT", function(_, questID, success)
			if state.qload or U.IsSecret(questID) or questID ~= QUESTS[2] then return end
			state.qload = (not U.IsSecret(success) and success) and "y" or "n"
			GH:Off("apitest", "QUEST_DATA_LOAD_RESULT")
			Done()
		end)
		pcall(C_QuestLog.RequestLoadQuestByID, QUESTS[2])
	end
	if C_Calendar and type(C_Calendar.OpenCalendar) == "function" then pcall(C_Calendar.OpenCalendar) end
	-- at the latest after LOG_WAIT seconds
	C_Timer.After(LOG_WAIT, function() Finish(state) end)
	if waiting == 0 then C_Timer.After(1, function() Finish(state) end) end
end
