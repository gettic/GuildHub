-- Guild Hub: settings page (Options -> AddOns -> Guild Hub, or /ghub options).
local _, ns = ...
local GH, L = ns.GH, ns.L

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

function GH:OpenOptions()
	if InCombatLockdown() then return end
	LibStub("AceConfigDialog-3.0"):Open("GuildHub")
end
