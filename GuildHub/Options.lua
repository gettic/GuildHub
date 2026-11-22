-- Guild Hub: settings (Settings tab in the /ghub window, /ghub options, and Options -> AddOns -> Guild Hub).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local function CurrentRankName()
	local gdb = GH:GetGuildDB()
	local r = gdb and gdb.cfg.officerMaxRank or 1
	return GH:GetRankNames()[r] or tostring(r)
end

-- 0.4.0: one switch per switchable feature (own), the same for officers (whole guild), the guild
-- history line and its Clear button, all in the Features section (orders 19.6-19.99); the guild
-- switches only show for officers, with a line saying who switched what off.
local function GuildOffNote(key)
	local off, by, stale = GH:GuildOff()
	if stale and by then return "\n" .. L.OPT_FEAT_EXOFFICER:format(U.ShortName(by)) end
	if off and off[key] and by then return "\n|cffff8040" .. L.OPT_FEAT_BYGUILD:format(U.ShortName(by)) .. "|r" end
	return ""
end

local function AddFeatureOptions(args)
	args.featHeader = { type = "header", order = 19.6, name = L.OPT_FEAT_HDR }
	args.featInfo = { type = "description", order = 19.61, name = L.OPT_FEAT_INFO }
	-- who switched what off for the guild (any officer can undo it with the switches below)
	local function GuildNoteText()
		local off, by, stale = GH:GuildOff()
		if stale and by then return L.OPT_FEAT_EXOFFICER:format(U.ShortName(by)) end
		if not (off and by) then return "" end
		local names = {}
		for _, key in ipairs(GH:SwitchableKeys()) do
			if off[key] then
				local f = GH.features[key]
				names[#names + 1] = f.name and L[f.name] or key
			end
		end
		if #names == 0 then return "" end
		return "|cffff8040" .. table.concat(names, ", ") .. ": " .. L.OPT_FEAT_BYGUILD:format(U.ShortName(by)) .. "|r"
	end
	args.featGuildNote = {
		type = "description", order = 19.615, name = GuildNoteText,
		hidden = function() return GuildNoteText() == "" end,
	}
	for i, key in ipairs(GH:SwitchableKeys()) do
		local f = GH.features[key]
		local label = f.name and L[f.name] or key
		args["feat_" .. key] = {
			type = "toggle", order = 19.62 + i * 0.01, width = "full",
			name = label,
			desc = function() return (L[(f.name or "") .. "_DESC"] or "") .. GuildOffNote(key) end,
			get = function() return GH.db.profile.features[key] ~= false end,
			set = function(_, v) GH:SetFeature(key, v) end,
		}
		args["featGuild_" .. key] = {
			type = "toggle", order = 19.7 + i * 0.01, width = "full", -- in the Features section, officers only
			name = L.OPT_FEAT_GUILD .. ": " .. label, desc = L.OPT_FEAT_GUILD_DESC,
			get = function()
				local off = GH:GuildOff()
				return off and off[key] or false
			end,
			set = function(_, v) GH:SetGuildFeature(key, not v) end,
			hidden = function() return not IsInGuild() or not GH:IsOfficer(GH:MyName()) end,
		}
	end
	args.recKept = {
		type = "description", order = 19.8,
		name = function()
			local c = GH.RecorderCounts and GH:RecorderCounts()
			if not c then return "" end
			return L.OPT_REC_KEPT:format(c.first, c.hours, c.kills, c.log, c.motd)
		end,
		hidden = function() return not IsInGuild() end,
	}
	args.recClear = {
		type = "execute", order = 19.81,
		name = L.OPT_REC_CLEAR, desc = L.OPT_REC_CLEAR_DESC,
		confirm = true, confirmText = L.OPT_REC_CLEAR_CONFIRM,
		func = function() GH:ClearRecorders() end,
		hidden = function() return not IsInGuild() or not GH.ClearRecorders end,
	}
	-- Guild Recruiter: the join note
	args.recruitToasts = {
		type = "toggle", order = 19.85, width = "full",
		name = L.OPT_RECRUIT_TOASTS, desc = L.OPT_RECRUIT_TOASTS_DESC,
		get = function() return GH.db.profile.recruitToasts ~= false end,
		set = function(_, v) GH.db.profile.recruitToasts = v and true or false end,
		disabled = function() return not GH:FeatureOn("recruit") end,
		hidden = function() return not GH.features.recruit end,
	}
	-- Guild Recruiter R3: the "looking for guild" spotter (off by default, each player's own choice)
	args.recruitSpot = {
		type = "toggle", order = 19.86, width = "full",
		name = L.OPT_RECRUIT_SPOT, desc = L.OPT_RECRUIT_SPOT_DESC,
		get = function() return GH.db.profile.recruitSpot == true end,
		set = function(_, v)
			GH.db.profile.recruitSpot = v and true or false
			if GH.SpotterUpdate then GH:SpotterUpdate() end
		end,
		disabled = function() return not GH:FeatureOn("recruit") end,
		hidden = function() return not GH.features.recruit end,
	}
end

-- Features.lua calls this (through OnFeaturesChanged) so open settings show the new state.
function GH:optionsChanged()
	local reg = LibStub("AceConfigRegistry-3.0", true)
	if reg then reg:NotifyChange("GuildHub") end
end

local BuildOptionsBase

-- 0.4.0-b2: "What I share" (top of the page, orders 2-9): one line per sharing item from the fair
-- trade registry (Features.lua), each saying that off also hides what others share. Plus the
-- Map section (minimap dots).
local function AddShareOptions(args)
	args.shareHeader = { type = "header", order = 2, name = L.OPT_SHARE_HDR }
	args.shareInfo = {
		type = "description", order = 2.01,
		name = function()
			if GH.cannotSend then return "|cffff9933" .. L.FAIR_TRIAL .. "|r" end
			return L.OPT_SHARE_INFO
		end,
	}
	for i, key in ipairs(GH.shareOrder) do
		local s = GH.shareItems[key]
		args[s.optKey or ("share_" .. key)] = {
			type = "toggle", order = 2.1 + i * 0.01, width = "full",
			name = function() return (L[s.name] or key) .. L.OPT_SHARE_OFFNOTE end,
			desc = function()
				local d = L[s.desc] or ""
				if s.feature and not GH:FeatureOn(s.feature) then d = d .. "\n|cffff8040" .. L.OPT_SHARE_FEATOFF .. "|r" end
				return d
			end,
			get = function() return GH:Shares(key) end,
			set = function(_, v) GH:SetShare(key, v) end,
			disabled = function() return GH.cannotSend or (s.feature ~= nil and not GH:FeatureOn(s.feature)) end,
		}
	end
	args.mapHeader = { type = "header", order = 19.52, name = L.OPT_MAP_HDR }
	args.mapMinimap = {
		type = "toggle", order = 19.53, width = "full",
		name = L.OPT_MAP_MINIMAP, desc = L.OPT_MAP_MINIMAP_DESC,
		get = function() return GH.db.profile.mapMinimap end,
		set = function(_, v) GH.db.profile.mapMinimap = v and true or false; GH:MapRedraw() end,
		disabled = function() return not GH:FeatureOn("map") end,
	}
	-- 0.6.0 map extras
	args.mapHideAfk = {
		type = "toggle", order = 19.54, width = "full",
		name = L.OPT_MAP_AFK, desc = L.OPT_MAP_AFK_DESC,
		get = function() return GH.db.profile.mapHideAfk ~= false end,
		set = function(_, v)
			GH.db.profile.mapHideAfk = v and true or false
			if GH:PosAfkHidden() then GH:SendPosOff() else GH:PosTick() end
			GH:UpdateFindButton()
		end,
		disabled = function() return not GH:FeatureOn("map") end,
	}
	args.mapFindLines = {
		type = "toggle", order = 19.55, width = "full",
		name = L.OPT_MAP_FINDLINES, desc = L.OPT_MAP_FINDLINES_DESC,
		get = function() return GH.db.profile.mapFindLines ~= false end,
		set = function(_, v) GH.db.profile.mapFindLines = v and true or false end,
		disabled = function() return not GH:FeatureOn("map") end,
	}
end

-- 1.0.1 Raid section (Features\Raid.lua, Features\RaidNight.lua): own role(s), the per-field switches of
-- Raid info (tos: opt-out per field), Rez available (healing classes) and the "New in" card.
local RAID_FIELD_NAMES = { at = "OPT_RAID_F_AT", lk = "OPT_RAID_F_LK", rs = "OPT_RAID_F_RS", du = "OPT_RAID_F_DU", rg = "OPT_RAID_F_RG" }
local function AddRaidOptions(args)
	if not GH.features.raid then return end
	local off = function() return not GH:FeatureOn("raid") end
	args.raidHeader = { type = "header", order = 19.56, name = L.OPT_RAID_HDR }
	args.raidRole = {
		type = "multiselect", order = 19.561, width = "full",
		name = L.OPT_RAID_ROLE, desc = L.OPT_RAID_ROLE_DESC,
		values = { t = L.ROLE_T, h = L.ROLE_H, d = L.ROLE_D },
		get = function(_, k) return (GH:OwnRole() or ""):find(k, 1, true) ~= nil end,
		set = function(_, k) GH:ToggleRole(k) end,
		disabled = off,
	}
	for i, f in ipairs(GH.RAID_FIELDS) do
		args["raidField_" .. f] = {
			type = "toggle", order = 19.562 + i * 0.0001, width = "full",
			name = L[RAID_FIELD_NAMES[f]] or f, desc = L.OPT_RAID_FIELD_DESC,
			get = function() return GH:RaidFieldShared(f) end,
			set = function(_, v) GH:SetRaidField(f, v) end,
			disabled = function() return off() or not GH:SharesRaid() end,
		}
	end
	args.raidRez = {
		type = "toggle", order = 19.563, width = "full",
		name = L.TICK_REZ, desc = L.TICK_REZ_TIP,
		get = function() return GH:RezAvailable() end,
		set = function(_, v) GH.db.char.rezAvail = v and GH:CanRez() or nil end,
		disabled = off,
		hidden = function() return not GH:CanRez() end,
	}
	args.raidNewIn = {
		type = "toggle", order = 19.564, width = "full",
		name = L.OPT_NEWIN, desc = L.OPT_NEWIN_DESC,
		get = function() return GH.db.profile.newInCard ~= false end,
		set = function(_, v) GH.db.profile.newInCard = v and true or false end,
	}
end

local function BuildOptions()
	local t = BuildOptionsBase()
	AddShareOptions(t.args)
	AddRaidOptions(t.args)
	AddFeatureOptions(t.args)
	return t
end

BuildOptionsBase = function()
	return {
		type = "group",
		name = L.OPT_TITLE,
		args = {
			intro = { type = "description", order = 1, name = L.OPT_INTRO, fontSize = "medium" },
			-- the Getting started card again (UI\Guide.lua)
			guide = {
				type = "execute", order = 1.5,
				name = L.OPT_GUIDE, desc = L.OPT_GUIDE_DESC,
				func = function() GH:ShowGuide() end,
			},
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
			-- 1.0.0-beta.1 calm alerts (UI\Toasts.lua)
			toastBudget = {
				type = "toggle", order = 15.1, width = "full",
				name = L.OPT_TOAST_BUDGET, desc = L.OPT_TOAST_BUDGET_DESC,
				get = function() return GH.db.profile.toastBudget ~= false end,
				set = function(_, v) GH.db.profile.toastBudget = v and true or false end,
			},
			pauseAlerts = {
				type = "execute", order = 15.2,
				name = function() return GH:AlertsPausedLeft() > 0 and L.OPT_RESUME or L.OPT_PAUSE end,
				desc = L.OPT_PAUSE_DESC,
				func = function() GH:TogglePauseAlerts() end,
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
			profHeader = { type = "header", order = 19.2, name = L.OPT_PROF_HDR },
			profTooltip = {
				type = "toggle", order = 19.5, width = "full",
				name = L.OPT_PROFTIP, desc = L.OPT_PROFTIP_DESC,
				get = function() return GH.db.profile.profTooltip end,
				set = function(_, v) GH.db.profile.profTooltip = v end,
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
		local host = page.inset or page -- the same inset as the status list (MainFrame.lua)
		c.frame:SetParent(host)
		c.frame:ClearAllPoints()
		c.frame:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -4)
		c.frame:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -4, 4)
		c.frame:SetFrameLevel((host:GetFrameLevel() or 0) + 2)
		self.settingsContainer = c
	end
	local c = self.settingsContainer
	c.frame:Show()
	dialog:Open("GuildHub", c)
end

-- /ghub options and minimap right-click: the full window on the Settings tab.
function GH:OpenOptions()
	if self.miniFrame and self.miniFrame:IsShown() then self.miniFrame:Hide() end
	local f = self:CreateMainFrame()
	f:Show()
	self:ShowTab("settings")
end
