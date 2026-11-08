-- Guild Hub: the addon object, start-up, timers and the /ghub command.
local ADDON_NAME, ns = ...
local L, U = ns.L, ns.Util

local GH = LibStub("AceAddon-3.0"):NewAddon("GuildHub",
	"AceEvent-3.0", "AceTimer-3.0", "AceConsole-3.0", "AceComm-3.0", "AceSerializer-3.0")
ns.GH = GH
_G.GuildHub = GH -- for /dump GuildHub and for other modules; holds no secrets

GH.VERSION  = (C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "0.0.0"
GH.PROTO    = 1          -- protocol number in every message; raise only for incompatible changes
GH.PREFIX   = "GuildHub" -- addon message prefix (max 16 characters)

GH.HEARTBEAT_SECONDS = 300   -- "I'm here" every 5 minutes
GH.ROSTER_SECONDS    = 60    -- ask the server for a fresh guild list
GH.PRUNE_DAYS        = 90    -- forget members not seen for this long

------------------------------------------------------------------------
-- Output (every line starts with "Guild Hub:" so nothing looks like a Blizzard message)
------------------------------------------------------------------------
function GH:Msg(text, ...)
	if select("#", ...) > 0 then text = text:format(...) end
	DEFAULT_CHAT_FRAME:AddMessage(L.PREFIX .. text)
end

function GH:Debug(text, ...)
	if not (self.db and self.db.profile.debug) then return end
	if select("#", ...) > 0 then text = text:format(...) end
	DEFAULT_CHAT_FRAME:AddMessage(L.DEBUG_PREFIX .. text)
end

-- Our key, the same form others see us as: "Name-Realm". On WoW Forever, UnitName gives only
-- "Mira" while the game (chat, guild list) uses "Mira Ashford", which GetUnitName(.., true) returns.
function GH:MyName()
	if not self.myName then
		local name = GetUnitName and GetUnitName("player", true)
		if type(name) ~= "string" or U.IsSecret(name) or name == "" then
			name = UnitName("player")
		end
		self.myName = U.FullName(name)
	end
	return self.myName
end

------------------------------------------------------------------------
-- Start-up
------------------------------------------------------------------------
function GH:OnInitialize()
	self:InitStore()      -- Store.lua
	self:InitOptions()    -- Options.lua
	self:RegisterChatCommand("ghub", "OnSlash")
end

function GH:OnEnable()
	self:InitComm()       -- Comm.lua
	self:InitRoster()     -- Roster.lua
	self:RegisterEvent("PLAYER_GUILD_UPDATE", "OnGuildChanged")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
	self:RegisterEvent("PLAYER_LEVEL_UP", "OnLevelUp")
	self:RegisterEvent("PLAYER_LOGOUT", "OnLogout")

	self:CheckTrialAccount()
	self:InitMinimapButton() -- UI\MainFrame.lua
	self:InitInviteWatch()   -- UI\StatusTab.lua
	-- give the game a few seconds to load the guild before we talk
	self:ScheduleTimer("Startup", 5)
end

function GH:Startup()
	if not IsInGuild() then
		self:Debug("not in a guild yet, waiting")
		return
	end
	if self.started then return end
	self.started = true

	self:MigrateOwnKey()  -- Store.lua
	self:RequestRoster()
	self:Prune()
	self:ScheduleRepeatingTimer("RequestRoster", self.ROSTER_SECONDS)
	self:ScheduleRepeatingTimer("SendHeartbeat", self.HEARTBEAT_SECONDS)
	self:ScheduleRepeatingTimer("Prune", 86400)
	self:InitStatus()     -- Status.lua: activity checks and the 1-hour clear

	-- HELLO goes out once the guild list has loaded (Roster.lua calls OnRosterReady),
	-- or after 15 s at the latest.
	self.helloPending = true
	self:ScheduleTimer(function() if GH.helloPending then GH:SendHello() end end, 15)
end

function GH:OnRosterReady()
	if self.helloPending then
		self:SendHello()
	end
end

function GH:OnGuildChanged()
	if IsInGuild() and not self.started then
		self:ScheduleTimer("Startup", 2)
	end
end

function GH:OnEnteringWorld(_, isLogin, isReload)
	if isLogin or isReload then return end
	-- Coming out of an instance without a sync yet: ask again (sync answers are skipped in instances).
	if self.started and not self.syncedThisSession and not IsInInstance() then
		self:SendHello()
	end
end

function GH:OnLevelUp()
	-- tell the guild a bit later (level is read after the event settles)
	self:ScheduleTimer("SendHeartbeat", 3)
end

function GH:OnLogout()
	local gdb = self:GetGuildDB()
	if gdb then gdb.lastOnline = U.Now() end
end

------------------------------------------------------------------------
-- /ghub
------------------------------------------------------------------------
function GH:OnSlash(input)
	local cmd, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "" then
		self:ToggleMainFrame()
	elseif cmd == "status" then
		self:PrintStatus()
	elseif cmd == "debug" then
		self.db.profile.debug = not self.db.profile.debug
		self:Msg(self.db.profile.debug and L.DEBUG_ON or L.DEBUG_OFF)
	elseif cmd == "test" and rest == "big" then
		self:SendBigTest()
	elseif cmd == "test" and rest == "activity" then
		self:TestActivity()
	elseif cmd == "test" and rest == "expire" then
		self:TestExpire()
	elseif cmd == "options" or cmd == "config" or cmd == "settings" then
		self:OpenOptions()
	else
		self:Msg(L.HELP_HEADER)
		DEFAULT_CHAT_FRAME:AddMessage(L.HELP_OPEN)
		DEFAULT_CHAT_FRAME:AddMessage(L.HELP_STATUS)
		DEFAULT_CHAT_FRAME:AddMessage(L.HELP_DEBUG)
		DEFAULT_CHAT_FRAME:AddMessage(L.HELP_TEST)
		DEFAULT_CHAT_FRAME:AddMessage(L.HELP_TEST2)
		DEFAULT_CHAT_FRAME:AddMessage(L.HELP_OPTIONS)
	end
end

function GH:PrintStatus()
	if not IsInGuild() then return self:Msg(L.NOT_IN_GUILD) end
	local gdb = self:GetGuildDB()
	if not gdb or not self.rosterReady then return self:Msg(L.ROSTER_WAIT) end

	local now = U.Now()
	local list = {}
	for name, m in pairs(gdb.members) do
		if self.roster[name] and m.version then
			list[#list + 1] = name
		end
	end
	table.sort(list, function(a, b)
		local oa, ob = self:IsAddonUserOnline(a), self:IsAddonUserOnline(b)
		if oa ~= ob then return oa end
		return a < b
	end)

	local onlineWithAddon = 0
	for _, name in ipairs(list) do
		if self:IsAddonUserOnline(name) then onlineWithAddon = onlineWithAddon + 1 end
	end
	self:Msg(L.STATUS_HEADER, self.rosterOnline or 0, onlineWithAddon)

	local shown = 0
	for _, name in ipairs(list) do
		shown = shown + 1
		if shown > 40 then
			DEFAULT_CHAT_FRAME:AddMessage(L.STATUS_MORE:format(#list - 40))
			break
		end
		local m = gdb.members[name]
		local where = self:IsAddonUserOnline(name) and L.STATUS_ONLINE
			or L.STATUS_LASTSEEN:format(U.Ago(now - (m.lastSeen or 0)))
		DEFAULT_CHAT_FRAME:AddMessage(L.STATUS_LINE:format(
			U.ClassColored(name, m.class), m.version or "?", tostring(m.level or "?"), where))
	end
	if #list <= 1 then
		DEFAULT_CHAT_FRAME:AddMessage(L.STATUS_NONE)
	end
end
