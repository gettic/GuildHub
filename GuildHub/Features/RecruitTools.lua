-- Guild Hub: Guild Recruiter, beta R3 (plans\guild-recruiter\PLAN.md groups B rest + C, tos-strict.md
-- rows 6, 9, 10, 15). Loaded after Features\RecruitOff.lua and before Features\Recruit.lua.
--  * Suggest to officers (members): a right-click on a player outside the guild, or a pick from
--    your own group on the Recruiting page. One addon whisper (RSUG) to ONE online officer with
--    Guild Hub: name, who suggested, a fixed class/role tag. No free text. 3 per day per account
--    (sender) and 3 per member per day (officer side). The officer's addon puts it on the
--    Suggestions list (officer data, RecruitOff.lua) and shows one quiet chat line. Nothing else.
--  * "Looking for guild" spotter (each player turns it on; off by default): a chat filter adds a
--    small marker to channel lines that ask for a guild. Saves nothing, sends nothing, no sound,
--    skips hidden (secret) values.
--  * Guild totals: joined in the last 30 days, still here, average online (the guild history's
--    online totals). Officers also see "X left on <date> and is back". Totals only: no per-person
--    counts or rankings.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

------------------------------------------------------------------------
-- Fixed caps (the self-test checks these values)
------------------------------------------------------------------------
local SUGGEST_PER_DAY = 3      -- per account (sender) and per member (officer side)
local SUGGEST_SAME_DAYS = 7    -- the same player once per 7 days (sender)
local GROUP_PICK_MAX = 4       -- names shown in "Suggest from your group"
local TOTAL_DAYS = 30          -- "joined in the last 30 days"
local REJOIN_DAYS = 30         -- rejoined notes for joins in the last 30 days
local REJOIN_MAX = 3

GH.RECRUIT_TOOL_CAPS = { SUGGEST_PER_DAY = SUGGEST_PER_DAY, SUGGEST_SAME_DAYS = SUGGEST_SAME_DAYS,
	TOTAL_DAYS = TOTAL_DAYS, REJOIN_DAYS = REJOIN_DAYS }
GH.sugStats = { sent = 0, got = 0, dropped = 0 }
GH.spotStats = { marked = 0, on = false }

local function Now() return U.Now() end
local function On() return GH:FeatureOn("recruit") end
local function HaveRoster() return type(GH.roster) == "table" and next(GH.roster) ~= nil end
local function IAmOfficer() return GH.RecruitIAmOfficer and GH.RecruitIAmOfficer() or false end
local function Key(name) return GH.RecruitNameKey(name) end

------------------------------------------------------------------------
-- Suggest to officers: the sender side
------------------------------------------------------------------------
-- Per-account caps: sug = {ts...} (24 h), sugTo = {[name] = ts} (7 days). Damaged = "just used".
function GH:SuggestCaps()
	local c = self.RecruitCaps()
	local now = Now()
	if c.sug ~= nil and type(c.sug) ~= "table" then
		c.sug = {}
		for _ = 1, SUGGEST_PER_DAY do c.sug[#c.sug + 1] = now end
	end
	c.sug = c.sug or {}
	for i = #c.sug, 1, -1 do
		local t = c.sug[i]
		if type(t) ~= "number" or t ~= t or t > now then c.sug[i] = now
		elseif t < now - 86400 then table.remove(c.sug, i) end
	end
	if c.sugTo ~= nil and type(c.sugTo) ~= "table" then c.sugTo = {} end
	c.sugTo = c.sugTo or {}
	for n, t in pairs(c.sugTo) do
		if type(n) ~= "string" then c.sugTo[n] = nil
		elseif type(t) ~= "number" or t ~= t or t > now then c.sugTo[n] = now
		elseif t < now - SUGGEST_SAME_DAYS * 86400 then c.sugTo[n] = nil end
	end
	return c
end

-- ONE online officer with Guild Hub (the first by name), or nil.
function GH:SuggestOfficer()
	local me, list = self:MyName(), {}
	for name in pairs(self.addonUsers or {}) do
		if name ~= me and self:IsOfficer(name) and self:IsAddonUserOnline(name) then list[#list + 1] = name end
	end
	table.sort(list)
	return list[1]
end

-- Why we can't suggest this player now (nil = we can).
function GH:SuggestBlock(name)
	if not On() then return L.AD_FEATURE_OFF end
	if not IsInGuild() or not HaveRoster() then return L.NOT_IN_GUILD end
	local n = Key(name)
	if not n then return L.INV_BAD_NAME end
	if n == self:MyName() or self:IsGuildMember(n) then return L.INV_IN_GUILD end
	if IAmOfficer() then return L.SUG_OFFICER end
	if InCombatLockdown() then return L.MAC_COMBAT end
	if IsInInstance() then return L.SUG_INSTANCE end
	local c = self:SuggestCaps()
	if c.sugTo[n] then return L.SUG_SAME end
	if #c.sug >= SUGGEST_PER_DAY then return L.SUG_DAY:format(SUGGEST_PER_DAY) end
	if not self:SuggestOfficer() then return L.SUG_NO_OFFICER end
	return nil
end

-- The fixed tag from a unit we can see (class word and group role). Hidden values are skipped.
function GH:SuggestTag(unit)
	if type(unit) ~= "string" or type(UnitClass) ~= "function" then return nil, nil end
	if type(UnitExists) == "function" then
		local okE, ex = pcall(UnitExists, unit)
		if not okE or U.IsSecret(ex) or not ex then return nil, nil end
	end
	local k, ro
	local okC, _, cls = pcall(UnitClass, unit)
	if okC and not U.IsSecret(cls) and GH.RECRUIT_CLASS_OK[cls] then k = cls end
	if type(UnitGroupRolesAssigned) == "function" then
		local okR, role = pcall(UnitGroupRolesAssigned, unit)
		if okR and not U.IsSecret(role) then
			ro = (role == "TANK" and "t") or (role == "HEALER" and "h") or (role == "DAMAGER" and "d") or nil
		end
	end
	return k, ro
end

-- The click. One RSUG to one officer, or a line saying why not.
function GH:SuggestToOfficers(name, class, role)
	local why = self:SuggestBlock(name)
	if why then self:Msg(why) return false end
	local n = Key(name)
	local officer = self:SuggestOfficer()
	local c, now = self:SuggestCaps(), Now()
	c.sug[#c.sug + 1] = now -- counted before the send
	c.sugTo[n] = now
	self.sugStats.sent = self.sugStats.sent + 1
	self:SendMsg("RSUG", { n = n, k = GH.RECRUIT_CLASS_OK[class] and class or nil,
		ro = GH.RECRUIT_ROLE_OK[role] and role or nil, ts = now }, officer)
	self:Msg(L.SUG_SENT, U.ShortName(n), U.ShortName(officer))
	if self.DrawRecruitPage then self:DrawRecruitPage() end
	return true
end

-- Name menu part for members (called by RecruitOff.lua's RecruitMenu for outsiders).
function GH:SuggestMenu(root, n, ctx)
	if root.CreateDivider then root:CreateDivider() end
	if root.CreateTitle then root:CreateTitle(L.MENU_TITLE) end
	local k, ro = self:SuggestTag(type(ctx) == "table" and ctx.unit or nil)
	local b = root:CreateButton(L.MENU_SUGGEST, function() GH:SuggestToOfficers(n, k, ro) end)
	local why = self:SuggestBlock(n)
	if why and b then
		if b.SetEnabled then pcall(b.SetEnabled, b, false) end
		if b.SetTooltip then pcall(b.SetTooltip, b, function(tip) tip:AddLine(why, 1, 0.5, 0.25, true) end) end
	end
	return 1
end

-- "Suggest from your group": players in OUR group who aren't in the guild (at most 4).
-- { { name = key, k = class, ro = role } }
function GH:GroupPickNames()
	local out = {}
	if type(GetNumGroupMembers) ~= "function" then return out end
	local okN, num = pcall(GetNumGroupMembers)
	if not okN or U.IsSecret(num) or type(num) ~= "number" or num < 2 then return out end
	local raid = type(IsInRaid) == "function" and IsInRaid()
	local me = self:MyName()
	for i = 1, raid and math.min(num, 40) or 4 do
		local unit = (raid and "raid" or "party") .. i
		local full
		if type(GetUnitName) == "function" then
			local ok, v = pcall(GetUnitName, unit, true)
			if ok and type(v) == "string" and not U.IsSecret(v) then full = v end
		end
		local n = full and Key(full)
		if n and n ~= me and not self:IsGuildMember(n) then
			local k, ro = self:SuggestTag(unit)
			out[#out + 1] = { name = n, k = k, ro = ro }
			if #out >= GROUP_PICK_MAX then break end
		end
	end
	return out
end

------------------------------------------------------------------------
-- Suggest to officers: the officer side (RSUG)
------------------------------------------------------------------------
-- gdb.recruit.sugIn = {[member] = {ts...}}: suggestions received per member, last 24 h.
local function SugIn(sender)
	local r = GH.RecruitData and GH.RecruitData()
	if not r then return nil end
	if type(r.sugIn) ~= "table" then r.sugIn = {} end
	local now = Now()
	for who, list in pairs(r.sugIn) do
		if type(who) ~= "string" or type(list) ~= "table" then r.sugIn[who] = nil
		else
			for i = #list, 1, -1 do
				local t = list[i]
				if type(t) ~= "number" or t ~= t or t > now then list[i] = now
				elseif t < now - 86400 then table.remove(list, i) end
			end
			if #list == 0 then r.sugIn[who] = nil end
		end
	end
	if sender then
		r.sugIn[sender] = r.sugIn[sender] or {}
		return r.sugIn[sender]
	end
	return nil
end
GH.RecruitSugIn = SugIn

local function Drop(self, why)
	self.sugStats.dropped = self.sugStats.dropped + 1
	self:Debug("suggestion dropped: %s", why)
end

local function HandleSug(self, sender, data, distribution, isSelf)
	if isSelf then return end
	if distribution ~= "WHISPER" then return Drop(self, "not a whisper") end
	if not On() or not IAmOfficer() then return Drop(self, "not an officer") end
	if not self:IsGuildMember(sender) or type(data) ~= "table" then return Drop(self, "sender") end
	if self.IsIgnored and self:IsIgnored(sender) then return Drop(self, "ignored") end
	local n = Key(data.n)
	if not n or n == sender or self:IsGuildMember(n) then return Drop(self, "name") end
	local list = SugIn(sender)
	if not list or #list >= SUGGEST_PER_DAY then return Drop(self, "3 per day") end
	list[#list + 1] = Now()
	if self:IsDontInvite(n) then return Drop(self, "don't invite") end
	local off = self:RecruitOff(true)
	if not off or off.pros[n] then return Drop(self, "already a prospect") end
	local k = GH.RECRUIT_CLASS_OK[data.k] and data.k or nil
	local ro = GH.RECRUIT_ROLE_OK[data.ro] and data.ro or nil
	self:AddSuggestion(n, sender, k, ro)
	self.sugStats.got = self.sugStats.got + 1
	self:Msg(L.SUG_IN, U.ShortName(sender), U.ShortName(n), self:SuggestTagText(k, ro))
end

-- "Priest, healer" / "" (fixed words only)
function GH:SuggestTagText(k, ro)
	local parts = {}
	if k then
		local t = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE[k]
		parts[#parts + 1] = t or (k:sub(1, 1) .. k:sub(2):lower())
	end
	if ro then parts[#parts + 1] = L["SUG_ROLE_" .. ro:upper()] end
	if #parts == 0 then return "" end
	return " (" .. table.concat(parts, ", ") .. ")"
end

local function SugGate(gh, _, target)
	return gh:FeatureOn("recruit") and type(target) == "string" and gh:IsOfficer(target) and not IAmOfficer()
end
if GH.RECRUIT_OFF_MESSAGES then
	GH.RECRUIT_OFF_MESSAGES.RSUG = { class = "normal", min = 0, gate = SugGate }
end
GH.handlers.RSUG = HandleSug

------------------------------------------------------------------------
-- "Looking for guild" spotter (off by default; marks only)
------------------------------------------------------------------------
-- Lines from guild recruiters are not marked (they offer a guild, they don't ask for one).
local OFFERS = { "recruit", "lfm", "join us", "we are", "we're", "our guild", "is looking for", "are looking for",
	"looking for more", "looking for members", "looking for players", "looking for people", "lf members",
	"lf players", "lf raiders", "looking for raiders", "<", "whisper me for", "/w me for", "pst for" }
local ASKS = { "looking for a guild", "looking for guild", " lf guild", " lfguild", " lf a guild", "need a guild",
	"need guild", "seeking a guild", "seeking guild", "searching for a guild", "searching for guild",
	"want to join a guild", "wanna join a guild", "looking to join a guild", "any guild", "guild for me",
	"guild to join", "guild that takes", "guild that would take", "need a new guild", "looking for a new guild" }

function GH:SpotterLooksForGuild(msg)
	if type(msg) ~= "string" or U.IsSecret(msg) then return false end
	local low = " " .. (U.CleanText(msg, 400) or ""):lower() .. " "
	if not low:find("guild", 1, true) then return false end
	-- "any guilds recruiting?" asks, although it says "recruiting"
	local asksAny = low:find("any guilds? recruit") ~= nil
	if not asksAny then
		for _, w in ipairs(OFFERS) do if low:find(w, 1, true) then return false end end
	end
	if asksAny then return true end
	for _, w in ipairs(ASKS) do if low:find(w, 1, true) then return true end end
	return false
end

local lastLine
local function SpotFilter(_, _, msg, author, ...)
	if not GH.spotStats.on or not On() then return false end
	if type(msg) ~= "string" or type(author) ~= "string" or U.IsSecret(msg) or U.IsSecret(author) then return false end
	local who = U.FullName(author)
	if who and (who == GH:MyName() or GH:IsGuildMember(who)) then return false end
	if not GH:SpotterLooksForGuild(msg) then return false end
	local lineID = select(9, ...) -- arg 11 of the chat event
	if U.IsSecret(lineID) then lineID = nil end -- a hidden value is never compared or kept
	if lineID == nil or lineID ~= lastLine then
		lastLine = lineID
		GH.spotStats.marked = GH.spotStats.marked + 1 -- memory only (self-test)
	end
	return false, L.SPOT_MARK .. msg, author, ...
end
GH.RecruitSpotFilter = SpotFilter

-- Forever 1.60.1: ChatFrameUtil.Add/RemoveMessageEventFilter (Blizzard_ChatFrameBase\Shared\
-- ChatFrameFilters.lua; the ApiTest probe `menu=` checks it). Missing = the spotter stays off.
local function FilterApi()
	if ChatFrameUtil and type(ChatFrameUtil.AddMessageEventFilter) == "function" then
		return ChatFrameUtil.AddMessageEventFilter, ChatFrameUtil.RemoveMessageEventFilter
	end
	return nil, nil
end

-- On only while the feature is on and the player's own setting is on.
function GH:SpotterUpdate()
	local want = On() and self.db and self.db.profile.recruitSpot == true
	if want == self.spotStats.on then return end
	local add, remove = FilterApi()
	if want then
		if type(add) ~= "function" then return end
		local ok = pcall(add, "CHAT_MSG_CHANNEL", SpotFilter)
		self.spotStats.on = ok
	else
		self.spotStats.on = false
		if type(remove) == "function" then pcall(remove, "CHAT_MSG_CHANNEL", SpotFilter) end
	end
end

------------------------------------------------------------------------
-- Guild totals (everyone) and the rejoined note (officers)
------------------------------------------------------------------------
local function Rec()
	local gdb = GH:GetGuildDB()
	return gdb and type(gdb.rec) == "table" and gdb.rec or nil
end

-- { joined, stay, avg, peak } (nil = unknown). Totals only; nothing per person leaves this function.
function GH:RecruitTotals()
	local r = Rec()
	local res = {}
	if not r or not self:FeatureOn("rec") then return res end
	local from = Now() - TOTAL_DAYS * 86400
	local names = {}
	if type(r.log) == "table" then
		for _, e in ipairs(r.log) do
			if type(e) == "table" and e.ty == "join" and type(e.t) == "number" and e.t >= from and type(e.p1) == "string" then
				names[e.p1] = true
			end
		end
	end
	if next(names) == nil and type(r.joins) == "table" then
		for n, t in pairs(r.joins) do if type(t) == "number" and t >= from then names[n] = true end end
	end
	local joined, stay = 0, 0
	for n in pairs(names) do
		joined = joined + 1
		if self:IsGuildMember(n) then stay = stay + 1 end
	end
	if HaveRoster() then res.joined, res.stay = joined, stay end
	local hours = type(r.hours) == "table" and type(r.hours.all) == "table" and r.hours.all
	if hours then
		local n, sum, peak = 0, 0, 0
		for _, s in pairs(hours) do
			if type(s) == "table" and type(s.n) == "number" and type(s.sum) == "number" then
				n, sum = n + s.n, sum + s.sum
				if type(s.max) == "number" and s.max > peak then peak = s.max end
			end
		end
		if n > 0 then res.avg, res.peak = sum / n, peak end
	end
	return res
end

-- Officers only: members back in the guild after leaving: { { name, left, back } }, newest first.
function GH:RecruitRejoins()
	local out = {}
	local r = Rec()
	if not IAmOfficer() or not r or not self:FeatureOn("rec") or type(r.log) ~= "table" then return out end
	local from = Now() - REJOIN_DAYS * 86400
	local joins, lefts = {}, {}
	for _, e in ipairs(r.log) do
		if type(e) == "table" and type(e.t) == "number" then
			local who = (e.ty == "join" and e.p1) or (e.ty == "quit" and e.p1) or (e.ty == "remove" and e.p2) or nil
			if type(who) == "string" and who ~= "?" then
				if e.ty == "join" then
					if e.t >= from and (not joins[who] or e.t > joins[who]) then joins[who] = e.t end
				else
					lefts[who] = lefts[who] or {}
					table.insert(lefts[who], e.t)
				end
			end
		end
	end
	for who, back in pairs(joins) do
		if self:IsGuildMember(who) and lefts[who] then
			local left
			for _, t in ipairs(lefts[who]) do if t < back and (not left or t > left) then left = t end end
			if left then out[#out + 1] = { name = who, left = left, back = back } end
		end
	end
	table.sort(out, function(a, b) return a.back > b.back end)
	while #out > REJOIN_MAX do table.remove(out) end
	return out
end

------------------------------------------------------------------------
-- Hooks (from Features\Recruit.lua) and the self-test part
------------------------------------------------------------------------
function GH:RecruitToolsEnable() self:SpotterUpdate() end
function GH:RecruitToolsDisable() self:SpotterUpdate() end

local EXPECT = { SUGGEST_PER_DAY = 3, SUGGEST_SAME_DAYS = 7, TOTAL_DAYS = 30, REJOIN_DAYS = 30 }
function GH:RecruitToolsSelfTest(api)
	api.Count()
	for k, v in pairs(EXPECT) do
		if self.RECRUIT_TOOL_CAPS[k] ~= v then api.Problem("RECRUIT", "sugcaps", k .. " is " .. tostring(self.RECRUIT_TOOL_CAPS[k])) end
	end
	api.Count()
	local m = self.msgTypes.RSUG
	if not (m and m.gate and not m.officer) then api.Problem("RECRUIT", "suggest", "RSUG is not a gated whisper type") end
	api.Count()
	local c = self:SuggestCaps()
	if #c.sug > SUGGEST_PER_DAY then api.Problem("RECRUIT", "suggest", "more than 3 suggestions in a day") end
	-- the spotter: off unless the player turned it on; it never saves anything
	api.Count()
	local want = On() and self.db.profile.recruitSpot == true
	if self.spotStats.on and not want then api.Problem("RECRUIT", "spotter", "marking while switched off") end
	for k in pairs(self.db.profile) do
		if type(k) == "string" and k:find("^spot") then api.Problem("RECRUIT", "spotter", "saved data: " .. k) end
	end
	-- the spotter's words, on fixed lines
	api.Count()
	if not self:SpotterLooksForGuild("anyone know a good guild? looking for a guild, lvl 40 priest")
		or self:SpotterLooksForGuild("<Iron Wolves> is recruiting! looking for members, /w me")
		or self:SpotterLooksForGuild("lf healer for deadmines") then
		api.Problem("RECRUIT", "spotter", "the guild-ask words don't match")
	end
	local t = self:RecruitTotals()
	api.Info(("recruit tools sug=%d/%d sent=%d got=%d dropped=%d spot=%s marked=%d joined30=%s stay=%s avg=%s"):format(
		#c.sug, SUGGEST_PER_DAY, self.sugStats.sent, self.sugStats.got, self.sugStats.dropped,
		self.spotStats.on and "on" or "off", self.spotStats.marked, tostring(t.joined or "-"), tostring(t.stay or "-"),
		t.avg and ("%.1f"):format(t.avg) or "-"))
end
