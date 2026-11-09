-- Guild Hub: settings (Settings tab in the /ghub window, /ghub options, and Options -> AddOns -> Guild Hub).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local function CurrentRankName()
	local gdb = GH:GetGuildDB()
	local r = gdb and gdb.cfg.officerMaxRank or 1
	return GH:GetRankNames()[r] or tostring(r)
end

local function BuildOptions()
	return {
		type = "group",
		name = L.OPT_TITLE,
		args = {
			intro = { type = "description", order = 1, name = L.OPT_INTRO, fontSize = "medium" },
			debug = {
				type = "toggle", order = 10, width = "full",
				name = L.OPT_DEBUG, desc = L.OPT_DEBUG_DESC,
				get = function() return GH.db.profile.debug end,
				set = function(_, v) GH.db.profile.debug = v end,
			},
			boardHeader = { type = "header", order = 11, name = L.OPT_BOARD_HDR },
			autoActivity = {
				type = "toggle", order = 12, width = "full",
				name = L.OPT_AUTOACT, desc = L.OPT_AUTOACT_DESC,
				get = function() return GH.db.profile.autoActivity end,
				set = function(_, v) GH:SetAutoActivity(v); GH:RefreshBoard() end,
			},
			autoActivityInfo = { type = "description", order = 13, name = L.OPT_AUTOACT_DESC },
			alertLfg = {
				type = "toggle", order = 14, width = "full",
				name = L.OPT_ALERT_LFG, desc = L.OPT_ALERT_LFG_DESC,
				get = function() return GH.db.profile.alerts.lfg end,
				set = function(_, v) GH.db.profile.alerts.lfg = v end,
			},
			alertHelp = {
				type = "toggle", order = 15, width = "full",
				name = L.OPT_ALERT_HELP, desc = L.OPT_ALERT_HELP_DESC,
				get = function() return GH.db.profile.alerts.help end,
				set = function(_, v) GH.db.profile.alerts.help = v end,
			},
			muted = {
				type = "multiselect", order = 16, width = "full",
				name = L.OPT_MUTED, desc = L.OPT_MUTED_DESC,
				values = function()
					local v = {}
					for name in pairs(GH.db.profile.alerts.muted) do v[name] = U.ShortName(name) end
					return v
				end,
				get = function(_, key) return GH.db.profile.alerts.muted[key] == true end,
				set = function(_, key, on)
					if not on then GH.db.profile.alerts.muted[key] = nil end
					GH:RefreshBoard()
				end,
				hidden = function() return next(GH.db.profile.alerts.muted) == nil end,
			},
			mutedNone = {
				type = "description", order = 17, name = L.OPT_MUTED_NONE,
				hidden = function() return next(GH.db.profile.alerts.muted) ~= nil end,
			},
			shareGroup = {
				type = "toggle", order = 17.5, width = "full",
				name = L.OPT_SHAREGROUP, desc = L.OPT_SHAREGROUP_DESC,
				get = function() return GH:SharesGroup() end,
				set = function(_, v) GH:SetShareGroup(v) end,
			},
			showNoAddon = {
				type = "toggle", order = 18, width = "full", name = L.OPT_NOADDON,
				get = function() return GH.db.profile.showNoAddon end,
				set = function(_, v) GH.db.profile.showNoAddon = v; GH:RefreshBoard() end,
			},
			minimapHide = {
				type = "toggle", order = 19, width = "full", name = L.OPT_MINIMAP,
				get = function() return GH.db.profile.minimap.hide end,
				set = function(_, v) GH.db.profile.minimap.hide = v; GH:UpdateMinimapButton() end,
			},
			officerHeader = { type = "header", order = 20, name = L.OPT_OFFICER_HDR },
			officerInfo = {
				type = "description", order = 21,
				name = function()
					if GH:IsGuildMaster(GH:MyName()) then return L.OPT_OFFICER_DESC end
					return L.OPT_NOT_GM:format(CurrentRankName())
				end,
			},
			officerRank = {
				type = "select", order = 22, width = "double",
				name = L.OPT_OFFICER, desc = L.OPT_OFFICER_DESC,
				values = function() return GH:GetRankNames() end,
				get = function()
					local gdb = GH:GetGuildDB()
					return gdb and gdb.cfg.officerMaxRank or 1
				end,
				set = function(_, v) GH:SetOfficerRank(v) end,
				disabled = function() return not GH:IsGuildMaster(GH:MyName()) end,
				hidden = function() return not IsInGuild() end,
			},
		},
	}
end

function GH:InitOptions()
	LibStub("AceConfig-3.0"):RegisterOptionsTable("GuildHub", BuildOptions)
	local ok, _, categoryID = pcall(LibStub("AceConfigDialog-3.0").AddToBlizOptions,
		LibStub("AceConfigDialog-3.0"), "GuildHub", L.OPT_TITLE)
	if ok then self.optionsCategoryID = categoryID end
end

------------------------------------------------------------------------
-- Settings tab in the /ghub window: the same options table, drawn by AceConfigDialog into
-- our own small AceGUI container (not SimpleGroup/InlineGroup, so AceConfigDialog adds its
-- own scroll frame). Only plain frames: fine in combat.
------------------------------------------------------------------------
local PAGE_TYPE, PAGE_VERSION = "GuildHubSettingsPage", 1

local function RegisterPageType(AceGUI)
	if (AceGUI:GetWidgetVersion(PAGE_TYPE) or 0) >= PAGE_VERSION then return end
	AceGUI:RegisterWidgetType(PAGE_TYPE, function()
		local frame = CreateFrame("Frame")
		frame:Hide()
		local content = CreateFrame("Frame", nil, frame)
		content:SetPoint("TOPLEFT", 10, -8)
		content:SetPoint("BOTTOMRIGHT", -6, 6)
		local widget = { frame = frame, content = content, type = PAGE_TYPE }
		widget.OnAcquire = function() end
		widget.OnWidthSet = function(self, w)
			local c = math.max(0, w - 16)
			self.content:SetWidth(c)
			self.content.width = c
		end
		widget.OnHeightSet = function(self, h)
			local c = math.max(0, h - 14)
			self.content:SetHeight(c)
			self.content.height = c
		end
		return AceGUI:RegisterAsContainer(widget)
	end, PAGE_VERSION)
end

-- Called each time the Settings tab is shown: build the container once, then (re)fill it so
-- values changed elsewhere (a mute from a note, the minimap button) show up to date.
function GH:ShowSettingsTab(page)
	local AceGUI = LibStub("AceGUI-3.0", true)
	local dialog = LibStub("AceConfigDialog-3.0", true)
	if not (AceGUI and dialog and page) then return end
	if not self.settingsContainer then
		RegisterPageType(AceGUI)
		local c = AceGUI:Create(PAGE_TYPE)
		c.frame:SetParent(page)
		c.frame:ClearAllPoints()
		c.frame:SetAllPoints(page)
		c.frame:SetFrameLevel((page:GetFrameLevel() or 0) + 1)
		self.settingsContainer = c
	end
	local c = self.settingsContainer
	c.frame:Show()
	dialog:Open("GuildHub", c)
end

-- /ghub options and minimap right-click: the full window on the Settings tab.
function GH:OpenOptions()
	if self.db.profile.mini then self:SetMiniMode(false) end
	local f = self:CreateMainFrame()
	f:Show()
	self:ShowTab("settings")
end
