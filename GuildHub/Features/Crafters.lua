-- Guild Hub: crafters without Guild Hub (M3) and "Could learn this" (A3) (1.0.2, plans\next-batch-2-1.0.x X4,
-- tos-check.md). Part of the "prof" feature (no messages of its own).
-- M3: "Ask guild list" on a recipe row = exactly ONE C_GuildInfo.QueryGuildMembersForRecipe(skillLine, recipe)
--     per click, >= 3 s apart, never in combat, no loop or retry; only plain numbers from our own recipe data.
--     No answer within 5 s, an error or a block: the button hides for the session. Result names are shown in
--     one popup only: never saved, sent, logged or whispered.
-- A3: one tooltip line on recipe items from data we already have (0 messages, nothing fetched on hover).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local GAP = 3
local WAIT = 5
local SHOW_MAX = 12
GH.M3_LIMITS = { GAP = GAP, WAIT = WAIT, SHOW_MAX = SHOW_MAX }
GH.m3 = { stats = { asked = 0, answered = 0, silent = 0, errors = 0 } }

local function Plain(v) return v ~= nil and not U.IsSecret(v) end
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local function Api()
	local G = C_GuildInfo
	return G and type(G.QueryGuildMembersForRecipe) == "function" and type(GetGuildRecipeInfoPostQuery) == "function"
		and type(GetGuildRecipeMember) == "function"
end

-- "y" answered / "n" a question got no answer (button hidden) / "never" not asked this session
function GH:GuildListAnswered()
	local m = self.m3
	if m.hidden then return "n" end
	if m.stats.answered > 0 then return "y" end
	return "never"
end

-- ok, why, seconds: hidden / share / combat / api / busy / wait
function GH:GuildListState()
	local m = self.m3
	if m.hidden then return false, "hidden" end
	if not self:FeatureOn("prof") then return false, "share" end
	local can, why = self:CanUse("prof")
	if not can then return false, why == "trial" and "trial" or "share" end
	if not Api() then return false, "api" end
	if InCombat() then return false, "combat" end
	if m.pending then return false, "busy" end
	local left = (m.at or -1000) + GAP - GetTime()
	if left > 0 then return false, "wait", math.ceil(left) end
	return true
end

local function Hide(reason)
	local m = GH.m3
	m.hidden, m.pending = reason or "silent", nil
	GH:Off("m3")
	GH:Msg(ns.L.GL_HIDDEN) -- once: the button is gone until a reload
	if GH.RefreshProfTab then GH:RefreshProfTab() end
end

local function OnAnswer()
	local m = GH.m3
	local p = m.pending
	if not p then return end
	local ok, line, recipe, n = pcall(GetGuildRecipeInfoPostQuery)
	if not ok then Hide("error") return end
	if not (Plain(line) and Plain(recipe) and Plain(n)) or recipe ~= p.recipe then return end -- not our question
	m.pending = nil
	m.stats.answered = m.stats.answered + 1
	GH:Off("m3")
	local names = {}
	for i = 1, math.min(tonumber(n) or 0, 200) do
		local okM, display, full, class, online = pcall(GetGuildRecipeMember, i)
		local name = okM and Plain(full) and type(full) == "string" and full or (okM and Plain(display) and display) or nil
		if name and name ~= GH:MyName() then
			local key = (GH.roster[name] and name) or U.FullName(name)
			local gdb = GH:GetGuildDB()
			local mem = gdb and gdb.members[key]
			names[#names + 1] = {
				name = key, class = Plain(class) and class or nil, online = Plain(online) and online == true,
				hub = (GH.addonUsers[key] ~= nil) or (type(mem) == "table" and mem.version ~= nil),
			}
		end
	end
	table.sort(names, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	if GH.ShowGuildListResult then GH:ShowGuildListResult(p, names) end
end

-- One question for one recipe (the click). line / recipe come from our own recipe rows (plain numbers).
function GH:AskGuildList(line, recipe, rname)
	local ok = self:GuildListState()
	if not ok then return false end
	if type(line) ~= "number" or type(recipe) ~= "number" or U.IsSecret(line) or U.IsSecret(recipe) then return false end
	local m = self.m3
	m.at = GetTime()
	m.pending = { line = line, recipe = recipe, rname = rname, t = m.at }
	m.stats.asked = m.stats.asked + 1
	self:On("m3", "GUILD_RECIPE_KNOWN_BY_MEMBERS", OnAnswer)
	self:On("m3", "ADDON_ACTION_BLOCKED", function() if GH.m3.pending then Hide("blocked") end end)
	local okQ = pcall(C_GuildInfo.QueryGuildMembersForRecipe, line, recipe)
	if not okQ then
		m.stats.errors = m.stats.errors + 1
		Hide("error")
		return false
	end
	self:ScheduleTimer(function()
		local p = GH.m3.pending
		if p and p.t == m.at then
			GH.m3.stats.silent = GH.m3.stats.silent + 1
			Hide("silent")
		end
	end, WAIT)
	if self.RefreshProfTab then self:RefreshProfTab() end
	return true
end

------------------------------------------------------------------------
-- A3: "Could learn this" on recipe item tooltips
------------------------------------------------------------------------
local skillPattern
local function SkillPattern()
	if skillPattern ~= nil then return skillPattern end
	local f = type(ITEM_MIN_SKILL) == "string" and ITEM_MIN_SKILL or "Requires %s (%d)"
	f = f:gsub("%%%d?%$?s", "\001"):gsub("%%%d?%$?d", "\002")
	f = f:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
	skillPattern = "^" .. f:gsub("\001", "(.+)"):gsub("\002", "(%%d+)") .. "$"
	return skillPattern
end
GH.SkillPattern = SkillPattern

-- Profession name (as the game writes it) -> skill line
local function LineByName(name)
	if type(name) ~= "string" then return nil end
	local low = name:lower()
	for line in pairs(GH.PROFS) do
		if GH:ProfName(line):lower() == low then return line end
		local T = C_TradeSkillUI
		if T and T.GetTradeSkillDisplayName then
			local ok, n = pcall(T.GetTradeSkillDisplayName, line)
			if ok and Plain(n) and type(n) == "string" and n:lower() == low then return line end
		end
	end
	return nil
end

-- From the tooltip's own lines: skill line + required skill, or nil.
function GH:RecipeRequirement(lines)
	if type(lines) ~= "table" then return nil end
	local pat = SkillPattern()
	for _, ln in ipairs(lines) do
		local text = type(ln) == "table" and ln.leftText
		if type(text) == "string" and not U.IsSecret(text) then
			local prof, n = text:match(pat)
			local line = LineByName(prof)
			if line and tonumber(n) then return line, tonumber(n) end
		end
	end
	return nil
end

-- "Recipe: Flask of X" -> "flask of x" (what the recipe teaches; the index is keyed by that name)
local function TaughtName(itemName)
	if type(itemName) ~= "string" then return nil end
	local s = itemName:match("^[^:]+:%s*(.+)$") or itemName
	return s:lower()
end

-- Names of guildmates who could learn it (cached data only). Returns list (sorted), or nil.
function GH:CouldLearn(line, need, itemName)
	if not self:CanUse("prof") then return nil end
	local gdb = self:GetGuildDB()
	if not gdb then return nil end
	local idx = self:ProfIndex()
	local knows = {}
	for _, id in ipairs(idx.byName[TaughtName(itemName) or ""] or {}) do
		for _, c in ipairs(idx.byRecipe[id] or {}) do knows[c.name] = true end
	end
	local out = {}
	for name, m in pairs(gdb.members) do
		local prof = type(m) == "table" and type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof
		local e = prof and not prof.off and prof.p[line]
		if e and (e.r or 0) >= need and self:IsGuildMember(name) and not (self.IsMyChar and self:IsMyChar(name)) and not knows[name] then
			out[#out + 1] = { name = name, online = self:IsOnline(name) }
		end
	end
	table.sort(out, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return out
end

function GH:CouldLearnText(list)
	if not list or #list == 0 then return nil end
	local names = {}
	for i = 1, math.min(2, #list) do names[i] = U.ShortName(list[i].name) end
	local more = #list > 2 and L.TIP_MORE:format(#list - 2) or ""
	return L.TIP_LEARN:format(table.concat(names, ", ") .. more)
end

-- The tooltip line for one item's tooltip data (Professions.lua InitProfTooltip calls it from the ONE
-- TooltipDataProcessor post-call; never in combat). nil = no line.
function GH:LearnTooltipLine(data)
	if type(data) ~= "table" or InCombat() then return nil end
	local id = data.id
	if type(id) ~= "number" or U.IsSecret(id) then return nil end
	local get = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
	if type(get) ~= "function" then return nil end
	local _, _, _, _, _, classID = get(id)
	if classID ~= 9 then return nil end -- recipes only
	local line, need = self:RecipeRequirement(data.lines)
	if not line then return nil end
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
	if U.IsSecret(name) then return nil end
	return self:CouldLearnText(self:CouldLearn(line, need, name))
end