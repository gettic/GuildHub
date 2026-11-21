-- Guild Hub: professions (step 3). Logic only, no frames (UI\ProfessionsTab.lua draws it).
-- Own data: skill from GetProfessions/GetProfessionInfo; recipes only when the player opens a profession
-- window (the game gives the list only then; Guild Hub never opens a window itself).
-- Messages:
--   PROF  (GUILD, at most 1 per 60 s): summary per profession { r skill, m max, s spec, n count, h hash }
--         + small "new recipes" delta (a) + rare recipes for the feed (fe); off = sharing turned off.
--   RREQ / RLIST (WHISPER): full recipe lists, pulled only after the Professions tab, the search or an item
--         tooltip was first used; one request at a time; answers paced to LIST_RATE bytes/s per sender,
--         with a pause after a failed send or while messages are blocked; nothing inside instances.
-- Players who leave the guild: their professions and feed lines are deleted (after 2 guild-list reads).
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local tconcat, tsort, floor = table.concat, table.sort, math.floor

local LIST_RATE = 200         -- bytes per second for our RLIST answers (tos check: cap ~300)
local LIST_PAUSE = 30         -- seconds without RLIST after a failed send
local REQ_GAP = 3             -- seconds between two requests
local REQ_TIMEOUT = 30        -- a request nobody answers is dropped after this
local SRC_BACKOFF = 120       -- seconds before asking a source again that didn't answer
local REQ_KEYS = 4            -- lists per request
local QUEUE_MAX = 40          -- RLIST answers waiting
local CHUNK = 150              -- list characters per RLIST piece (one addon message, sent LIST_RATE-paced)
local PARTS_TIMEOUT = 120      -- seconds a half-received list is kept
local MAX_PROFS = 10
local MAX_IDS = 800
local MAX_LIST_CHARS = 6000
local MAX_ID = 10000000
local MAX_SKILL = 450
local MAX_DELTA = 40          -- recipes in one PROF delta
local FEED_MAX = 200
local FEED_SHOWN = 8
local GONE_SECONDS = 60       -- a player missing from the guild list this long is gone
GH.PROF_LIST_RATE = LIST_RATE

-- Skill lines (TradeSkillLineID). kind: craft / gather / fish / second (Cooking, First Aid).
local PROFS = {
	[171] = { key = "alch", kind = "craft" }, [164] = { key = "bs", kind = "craft" },
	[333] = { key = "ench", kind = "craft" }, [202] = { key = "eng", kind = "craft" },
	[165] = { key = "lw", kind = "craft" }, [197] = { key = "tail", kind = "craft" },
	[755] = { key = "jc", kind = "craft" }, [773] = { key = "insc", kind = "craft" },
	[182] = { key = "herb", kind = "gather" }, [186] = { key = "mine", kind = "gather" },
	[393] = { key = "skin", kind = "gather" }, [356] = { key = "fish", kind = "fish" },
	[185] = { key = "cook", kind = "second" }, [129] = { key = "aid", kind = "second" },
	[794] = { key = "arch", kind = "gather" },
}
-- Enum.Profession -> skill line (GetBaseProfessionInfo gives the enum too)
local ENUM_TO_LINE = { [0] = 129, 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393, 755, 773, 794 }
-- display order and the filter dropdown ("gather" = herbalism, mining, skinning, fishing)
local ORDER = { 171, 164, 333, 202, 165, 197, 755, 773, 185, 129, 182, 186, 393, 356, 794 }
GH.PROF_FILTERS = { "all", "alch", "bs", "ench", "eng", "lw", "tail", "cook", "aid", "gather" }
-- specialisation spells (checked with IsPlayerSpell; numbers are sent, so append only)
local SPECS = {
	[9787] = 164, [9788] = 164, [17039] = 164, [17040] = 164, [17041] = 164, -- Weaponsmith, Armorsmith, Sword/Hammer/Axe
	[20219] = 202, [20222] = 202,                                            -- Gnomish, Goblin
	[10656] = 165, [10658] = 165, [10660] = 165,                             -- Dragonscale, Elemental, Tribal
}
GH.PROFS, GH.PROF_ORDER, GH.PROF_SPECS = PROFS, ORDER, SPECS

GH.profSrc = {}       -- [name] = who told us their newest hashes (owner or a sync responder)
GH.profBackoff = {}   -- [source] = GetTime() until which we don't ask them
GH.rlistQueue = {}
GH.profMiss = {}      -- [source .. name .. line] = GetTime() until which that source is not asked for that list (it had none)
GH.rlistParts = {}    -- [sender .. name .. line] = pieces of a list being received
GH.profBase = {}      -- [skillLine] = { h, l } our list as last seen in our own PROF echo
GH.ownLists = {}      -- [hash] = encoded list (our recent lists, for the delta)

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function ToB36(n)
	if n == 0 then return "0" end
	local s = ""
	while n > 0 do
		local d = n % 36
		s = B36:sub(d + 1, d + 1) .. s
		n = floor(n / 36)
	end
	return s
end

-- Sorted list of recipe IDs -> "gap,gap,..." in base 36 (first = the ID itself).
function GH:EncodeRecipes(ids)
	local list, seen = {}, {}
	for _, id in ipairs(ids or {}) do
		if type(id) == "number" and id > 0 and id <= MAX_ID and id == floor(id) and not seen[id] then
			seen[id] = true
			list[#list + 1] = id
		end
	end
	tsort(list)
	local parts, prev = {}, 0
	for i, id in ipairs(list) do
		parts[i] = ToB36(id - prev)
		prev = id
	end
	return tconcat(parts, ","), #list
end

-- Back to a sorted list; nil if anything is wrong (wrong letters, too long, too many, not rising).
function GH:DecodeRecipes(s)
	if type(s) ~= "string" or U.IsSecret(s) then return nil end
	if s == "" then return {} end
	if #s > MAX_LIST_CHARS or s:find("[^0-9a-z,]") then return nil end
	local ids, prev = {}, 0
	for part in (s .. ","):gmatch("([^,]*),") do
		local d = tonumber(part, 36)
		if not d or d <= 0 then return nil end
		prev = prev + d
		if prev > MAX_ID then return nil end
		ids[#ids + 1] = prev
		if #ids > MAX_IDS then return nil end
	end
	return ids
end

function GH:RecipeHash(enc) return U.Checksum(enc or "") end

local function Online(name) return GH:IsAddonUserOnline(name) end
-- GetProfessions returns prof1, prof2, archaeology, fishing, cooking with nil holes: collect the numbers
local function ProfIndices()
	local t, r = { GetProfessions() }, {}
	for i = 1, 6 do if type(t[i]) == "number" then r[#r + 1] = t[i] end end
	return r
end
function GH:ProfName(line)
	local p = PROFS[line]
	return p and L.PROF[p.key] or tostring(line)
end
function GH:SpecName(spell)
	if not spell or not SPECS[spell] then return nil end
	local n = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spell)
	if type(n) == "string" and not U.IsSecret(n) then return n end
	return L.SPEC[spell]
end
function GH:SharesProfessions() return self.db.profile.shareProf ~= false end

local function MemberProf(name)
	local gdb = GH:GetGuildDB()
	local m = gdb and gdb.members[name]
	return m and type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof or nil, m
end

------------------------------------------------------------------------
-- Own professions
------------------------------------------------------------------------
function GH:OwnProf()
	local gdb = self:GetGuildDB()
	local me = self:MyName()
	if not gdb or not me then return nil end
	local m = gdb.members[me]
	if type(m) ~= "table" then
		m = { ts = U.Now(), lastSeen = U.Now() }
		gdb.members[me] = m
	end
	if type(m.prof) ~= "table" or type(m.prof.p) ~= "table" then m.prof = { ts = 0, p = {} } end
	return m.prof
end

local function Changed(own)
	own.ts = math.max(U.Now(), (own.ts or 0) + 1)
	GH.profDirty = true
	GH:QueueOwnProf()
	GH:RefreshProfTab()
	if GH.RefreshGuide then GH:RefreshGuide() end -- Getting started: a window was scanned
end

-- Skill levels (no window needed). Called at start-up and on SKILL_LINES_CHANGED.
function GH:ReadOwnSkills()
	if not (GetProfessions and GetProfessionInfo) then return end
	local own = self:OwnProf()
	if not own then return end
	local seen, any, changed = {}, false, false
	for _, idx in ipairs(ProfIndices()) do
		if type(idx) == "number" and not U.IsSecret(idx) then
			local _, _, rank, max, _, _, line = GetProfessionInfo(idx)
			if PROFS[line] and U.ValidNumber(rank, 0, MAX_SKILL) and U.ValidNumber(max, 0, MAX_SKILL) then
				any = true
				seen[line] = true
				local e = own.p[line]
				if not e then
					e = { n = 0, h = self:RecipeHash(""), l = "" }
					own.p[line] = e
					changed = true
				end
				-- skill: tell others when it rose by 5, reached the cap, or the cap changed
				if e.r ~= rank or e.m ~= max then
					if not e.r or math.abs(rank - (e.sentR or 0)) >= 5 or rank == max or e.m ~= max then
						changed = true
						e.sentR = rank
					end
					e.r, e.m = rank, max
				end
			end
		end
	end
	-- specialisations
	if IsPlayerSpell then
		for spell, line in pairs(SPECS) do
			local e = own.p[line]
			if e and IsPlayerSpell(spell) and e.s ~= spell then e.s = spell; changed = true end
		end
	end
	-- unlearned professions go (First Aid has no entry in GetProfessions: kept)
	if any then
		for line in pairs(own.p) do
			if not seen[line] and line ~= 129 then own.p[line] = nil; changed = true end
		end
	end
	if changed then Changed(own) end
end

-- The open profession window (never another player's, a guild's or an NPC's list).
function GH:ScanOpenWindow()
	local T = C_TradeSkillUI
	if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo and T.GetBaseProfessionInfo) then return end
	if InCombatLockdown() then self.profScanAfterCombat = true return end
	for _, f in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
		if T[f] and T[f]() then return end
	end
	local info = T.GetBaseProfessionInfo()
	if type(info) ~= "table" then return end
	local line = info.professionID
	if U.IsSecret(line) then return end
	if not PROFS[line] then line = ENUM_TO_LINE[info.profession] end
	if not PROFS[line] then return end
	local all = T.GetAllRecipeIDs()
	if type(all) ~= "table" or #all == 0 then return end
	local learned = {}
	for _, id in ipairs(all) do
		if type(id) == "number" and not U.IsSecret(id) then
			local r = T.GetRecipeInfo(id)
			if type(r) == "table" and r.learned == true and not r.isDummyRecipe then learned[#learned + 1] = id end
		end
	end
	local own = self:OwnProf()
	if not own then return end
	local enc, n = self:EncodeRecipes(learned)
	local h = self:RecipeHash(enc)
	local e = own.p[line] or {}
	own.p[line] = e
	local changed = e.h ~= h
	e.l, e.n, e.h, e.scanned = enc, n, h, U.Now()
	self.ownLists[h] = enc
	local rank, max = U.ValidNumber(info.skillLevel, 0, MAX_SKILL), U.ValidNumber(info.maxSkillLevel, 0, MAX_SKILL)
	if rank and (e.r ~= rank or e.m ~= max) then e.r, e.m, changed = rank, max or e.m, true end
	if changed then Changed(own) end
	self:Debug("scanned %s: %d recipes", self:ProfName(line), n)
end

-- Learned a recipe: added at once (no window needed when the game tells us the profession).
function GH:OnRecipeLearned(recipeID)
	if type(recipeID) ~= "number" or U.IsSecret(recipeID) then return end
	local T = C_TradeSkillUI
	local line
	if T and T.GetTradeSkillLineForRecipe then
		local ok, a, _, c = pcall(T.GetTradeSkillLineForRecipe, recipeID)
		if ok then line = (PROFS[c] and c) or (PROFS[a] and a) or nil end
	end
	if not line and T and T.GetBaseProfessionInfo then
		local info = T.GetBaseProfessionInfo()
		line = type(info) == "table" and (PROFS[info.professionID] and info.professionID or ENUM_TO_LINE[info.profession]) or nil
	end
	local own = self:OwnProf()
	if not (own and line and PROFS[line]) then return end
	local e = own.p[line]
	if not e then
		e = { n = 0, l = "" }
		own.p[line] = e
	end
	local ids = self:DecodeRecipes(e.l) or {}
	for _, id in ipairs(ids) do if id == recipeID then return end end
	ids[#ids + 1] = recipeID
	local enc, n = self:EncodeRecipes(ids)
	e.l, e.n, e.h = enc, n, self:RecipeHash(enc)
	self.ownLists[e.h] = enc
	if self:IsRareRecipe(recipeID, line, self.atTrainer) then
		self.ownRare = self.ownRare or {}
		self.ownRare[#self.ownRare + 1] = recipeID
		self:AddFeed(self:MyName(), recipeID, line, U.Now())
	end
	Changed(own)
end

-- Rare (feed): makes a blue/purple item, or learned away from a trainer (a recipe drop, vendor or
-- quest), not Cooking or First Aid.
function GH:IsRareRecipe(recipeID, line, atTrainer)
	local T = C_TradeSkillUI
	if T and T.GetRecipeOutputItemData and C_Item and C_Item.GetItemQualityByID then
		local ok, out = pcall(T.GetRecipeOutputItemData, recipeID)
		local item = ok and type(out) == "table" and out.itemID or nil
		local q = item and C_Item.GetItemQualityByID(item)
		if type(q) == "number" and not U.IsSecret(q) and q >= 3 then return true end
	end
	if line == 185 or line == 129 then return false end
	return not atTrainer
end

------------------------------------------------------------------------
-- Sending our summary
------------------------------------------------------------------------
-- The summary of one profession entry (what PROF and SYNC carry).
local function Summary(e)
	return { r = e.r, m = e.m, s = e.s, n = e.n or 0, h = e.h or GH:RecipeHash("") }
end

function GH:OwnProfPayload()
	local own = self:OwnProf()
	if not own then return nil end
	if not self:SharesProfessions() then return { ts = own.offTs or own.ts, off = 1 } end
	local p, a = {}, nil
	for line, e in pairs(own.p) do
		p[line] = Summary(e)
		-- delta: only the recipes added since the list the guild saw in our last PROF
		local base = self.profBase[line]
		if base and base.h ~= e.h and e.l then
			local old, new = self:DecodeRecipes(base.l), self:DecodeRecipes(e.l)
			if old and new and #new > #old and #new - #old <= MAX_DELTA then
				local have, add, ok = {}, {}, true
				for _, id in ipairs(old) do have[id] = true end
				local cnt = 0
				for _, id in ipairs(new) do if have[id] then cnt = cnt + 1 else add[#add + 1] = id end end
				if cnt ~= #old then ok = false end -- something was removed: no delta, they fetch it
				if ok then
					a = a or {}
					a[line] = { f = base.h, l = (self:EncodeRecipes(add)) }
				end
			end
		end
	end
	local fe = self.ownRare
	return { ts = own.ts, p = p, a = a, fe = fe and #fe > 0 and fe or nil }
end

-- What a SYNC record carries for one member (summaries only, never lists). nil = nothing.
function GH:ProfSyncPayload(name, m)
	local prof = type(m) == "table" and type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof
	if not prof or not U.ValidTime(prof.ts) then return nil end
	if name == self:MyName() then
		if not self:SharesProfessions() then return { ts = prof.offTs or prof.ts, off = 1 } end
	elseif prof.off then
		return { ts = prof.ts, off = 1 }
	end
	local p = {}
	for line, e in pairs(prof.p) do p[line] = Summary(e) end
	return { ts = prof.ts, p = p }
end

-- Asks for a PROF send; Comm.lua's 60-s pacing keeps only the newest.
function GH:QueueOwnProf()
	if not self.profReady then return end
	local data = self:OwnProfPayload()
	if data then self:SendMsg("PROF", data) end
end

function GH:SetShareProfessions(on)
	on = on and true or false
	self.db.profile.shareProf = on
	local own = self:OwnProf()
	if own then
		own.ts = math.max(U.Now(), (own.ts or 0) + 1)
		if not on then own.offTs = own.ts end
	end
	if self.profReady then
		local data = self:OwnProfPayload()
		if data then self:SendMsg("PROF", data) end
	end
end

-- Fair trade (Features.lua): no professions shared = no directory, recipe search, crafted-by tooltip
-- line or rare-recipe feed, and no recipe lists fetched.
GH:RegisterShare({
	key = "prof", order = 3, optKey = "shareProf", feature = "prof",
	name = "OPT_SHAREPROF", desc = "OPT_SHAREPROF_DESC",
	get = function(gh) return gh:SharesProfessions() end,
	set = function(gh, on) gh:SetShareProfessions(on) end,
})

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
local function CleanEntry(e)
	if type(e) ~= "table" then return nil end
	local r = U.ValidNumber(e.r, 0, MAX_SKILL)
	local n = U.ValidNumber(e.n, 0, MAX_IDS)
	local h = U.ValidNumber(e.h, 0, 2147483647)
	if not (n and h) then return nil end
	local s = e.s
	if not (type(s) == "number" and SPECS[s]) then s = nil end
	return { r = r, m = U.ValidNumber(e.m, 0, MAX_SKILL), s = s, n = n, h = h }
end

-- Merge a summary (from PROF or SYNC). delta = PROF's `a`. Returns true if anything changed.
function GH:MergeProf(name, data, src, delta)
	if type(data) ~= "table" or name == self:MyName() then return false end
	local ts = U.ValidTime(data.ts)
	if not ts then return false end
	local gdb = self:GetGuildDB()
	if not gdb then return false end
	local m = gdb.members[name]
	if type(m) ~= "table" then
		m = { ts = 0, lastSeen = U.Now() }
		gdb.members[name] = m
	end
	local old = type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof or nil
	if old and (old.ts or 0) >= ts then return false end
	if data.off then
		m.prof = { ts = ts, p = {}, off = true } -- they stopped sharing: their data is dropped
		self.profDirty = true
		return true
	end
	if type(data.p) ~= "table" then return false end
	local p, count = {}, 0
	for line, e in pairs(data.p) do
		count = count + 1
		if count > MAX_PROFS then break end
		local c = PROFS[line] and CleanEntry(e)
		if c then
			local prev = old and old.p[line]
			if c.n == 0 then
				c.l = ""
			elseif prev and prev.h == c.h and prev.l then
				c.l = prev.l
			else
				local d = type(delta) == "table" and delta[line]
				if prev and prev.l and type(d) == "table" and d.f == prev.h then
					local a, b = self:DecodeRecipes(prev.l), self:DecodeRecipes(d.l)
					if a and b then
						for _, id in ipairs(b) do a[#a + 1] = id end
						local enc = self:EncodeRecipes(a)
						if self:RecipeHash(enc) == c.h then c.l = enc end
					end
				end
				if not c.l then
					c.l = prev and prev.l or nil -- the old list still helps the search until the new one comes
					c.old = true
				end
			end
			p[line] = c
		end
	end
	m.prof = { ts = ts, p = p }
	if src then self.profSrc[name] = src end
	self.profDirty = true
	return true
end

GH.handlers.PROF = function(self, sender, data, distribution, isSelf)
	if distribution ~= "GUILD" then return end
	if isSelf then
		-- our own echo: the guild now has this list (base for the next delta)
		if type(data.p) == "table" then
			for line, e in pairs(data.p) do
				local enc = type(e) == "table" and self.ownLists[e.h]
				if enc then self.profBase[line] = { h = e.h, l = enc } end
			end
		end
		self.ownRare = nil
		return
	end
	if self:MergeProf(sender, data, sender, data.a) then
		if type(data.fe) == "table" then
			local line1 = type(data.p) == "table" and next(data.p) or nil
			for i, id in ipairs(data.fe) do
				if i > 5 then break end
				id = U.ValidNumber(id, 1, MAX_ID)
				if id then self:AddFeed(sender, id, self:FeedLine(sender, id) or line1, U.ValidTime(data.ts)) end
			end
		end
		self:RefreshProfTab()
	end
end

-- Which of their professions has this recipe (for the feed's profession name).
function GH:FeedLine(name, id)
	local prof = MemberProf(name)
	if not prof then return nil end
	for line, e in pairs(prof.p) do
		local ids = e.l and self:DecodeRecipes(e.l)
		if ids then for _, x in ipairs(ids) do if x == id then return line end end end
	end
	return nil
end

function GH:AddFeed(who, recipeID, line, ts)
	local gdb = self:GetGuildDB()
	if not gdb then return end
	for _, e in ipairs(gdb.feed) do
		if e.who == who and e.r == recipeID then return end
	end
	table.insert(gdb.feed, 1, { ts = ts or U.Now(), who = who, r = recipeID, k = line })
	tsort(gdb.feed, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
	while #gdb.feed > FEED_MAX do table.remove(gdb.feed) end
end

------------------------------------------------------------------------
-- Pulling recipe lists (only after first use) and answering others
------------------------------------------------------------------------
-- The tab, the search or an item tooltip calls this: from now on missing lists are fetched.
function GH:WantRecipeLists()
	if self.profWanted or not self:CanUse("prof") then return end -- fair trade: not sharing = no lists
	self.profWanted = true
	self:Debug("recipe lists: fetching what is missing")
end

local function CanTalk()
	return not (GH:InLockdown() or IsInInstance() or GH.cannotSend)
end

-- One step every few seconds: send the next request if none is open.
function GH:ProfFetchTick()
	local now = GetTime()
	local req = self.profReq
	if req then
		if now - req.t < REQ_TIMEOUT then return end
		-- nothing came back: ask someone else for a while (a partial answer is fine)
		if not req.got then self.profBackoff[req.to] = now + SRC_BACKOFF end
		self.profReq = nil
	end
	if not (self.profWanted and CanTalk() and self:CanUse("prof")) then return end
	if now - (self.profReqLast or -1000) < REQ_GAP then return end
	local gdb = self:GetGuildDB()
	if not gdb then return end
	local me = self:MyName()
	local bySrc = {}
	-- who else could have a list: Guild Hub users online now (sorted, so every client asks alike)
	local others = {}
	for u in pairs(self.addonUsers) do
		if u ~= me and Online(u) then others[#others + 1] = u end
	end
	table.sort(others)
	for name, m in pairs(gdb.members) do
		local prof = name ~= me and type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof
		if prof and self:IsGuildMember(name) then
			for line, e in pairs(prof.p) do
				if (e.old or not e.l) and (e.n or 0) > 0 then
					local src
					local function Usable(cand)
						return cand and cand ~= me and Online(cand) and (self.profBackoff[cand] or 0) < now
							and (self.profMiss[cand .. "\001" .. name .. "\001" .. line] or 0) < now
					end
					-- the owner first, then whoever sent us their summary, then any other user
					if Usable(name) then src = name
					elseif Usable(self.profSrc[name]) then src = self.profSrc[name]
					else
						for _, cand in ipairs(others) do
							if cand ~= name and Usable(cand) then src = cand break end
						end
					end
					if src then
						bySrc[src] = bySrc[src] or {}
						local list = bySrc[src]
						if #list < REQ_KEYS then list[#list + 1] = { n = name, k = line, h = e.h } end
					end
				end
			end
		end
	end
	local best, bestList
	for src, list in pairs(bySrc) do
		if not best or #list > #bestList or (#list == #bestList and src < best) then best, bestList = src, list end
	end
	if not best then return end
	self.profReq = { to = best, t = now, keys = {} }
	for _, w in ipairs(bestList) do self.profReq.keys[w.n .. "\001" .. w.k] = true end
	self.profReqLast = now
	self:SendMsg("RREQ", { w = bestList }, best)
end

GH.handlers.RREQ = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" or type(data.w) ~= "table" then return end
	if IsInInstance() then return end
	local me = self:MyName()
	local queued = 0
	for _, q in ipairs(self.rlistQueue) do if q.to == sender then queued = queued + 1 end end
	for i, w in ipairs(data.w) do
		if i > REQ_KEYS or #self.rlistQueue >= QUEUE_MAX or queued >= 8 then break end
		local name = type(w) == "table" and U.ValidName(w.n)
		local line = name and w.k
		if name and PROFS[line] and name ~= sender then
			local prof = MemberProf(name)
			local e = prof and prof.p[line]
			local dup = false
			for _, q in ipairs(self.rlistQueue) do
				if q.to == sender and q.d.n == name and q.d.k == line then dup = true end
			end
			if not dup then
				if e and e.l and not e.old and e.h == w.h and not prof.off and (name ~= me or self:SharesProfessions()) then
					self.rlistQueue[#self.rlistQueue + 1] = { to = sender, d = { n = name, k = line, h = e.h, ts = prof.ts, l = e.l } }
				else
					-- we do not have (or do not share) that list: a short "no", so they ask someone else at once
					self.rlistQueue[#self.rlistQueue + 1] = { to = sender, d = { n = name, k = line, no = 1 } }
				end
				queued = queued + 1
			end
		end
	end
end

-- Sends queued answers, at most LIST_RATE bytes per second on average.
function GH:RListTick()
	local now = GetTime()
	if #self.rlistQueue == 0 or now < (self.rlistNext or 0) then return end
	if not CanTalk() then
		self.rlistNext = now + 10
		return
	end
	local q = self.rlistQueue[1]
	if not self:IsOnline(q.to) then table.remove(self.rlistQueue, 1) return end
	if q.d.no then
		table.remove(self.rlistQueue, 1)
		local size = #self:Serialize(q.d) + 12
		self.rlistNext = now + size / LIST_RATE
		self:SendMsg("RLIST", q.d, q.to, "BULK")
		return
	end
	-- one piece of at most CHUNK list characters per message, so the rate holds piece by piece
	local l = q.d.l
	local count = math.max(1, math.ceil(#l / CHUNK))
	q.i = (q.i or 0) + 1
	local d = { n = q.d.n, k = q.d.k, h = q.d.h, ts = q.d.ts, i = q.i, c = count, l = l:sub((q.i - 1) * CHUNK + 1, q.i * CHUNK) }
	if q.i >= count then table.remove(self.rlistQueue, 1) end
	local size = #self:Serialize(d) + 12
	self.rlistNext = now + size / LIST_RATE
	self:SendMsg("RLIST", d, q.to, "BULK")
end

-- Comm.lua: a send that failed. RLIST waits a while (throttle or blocked messages).
function GH:OnProfSendFailed(info)
	if info and info.mtype == "RLIST" then
		self.rlistNext = GetTime() + LIST_PAUSE
	elseif info and info.mtype == "RREQ" and self.profReq then
		self.profBackoff[self.profReq.to] = GetTime() + SRC_BACKOFF
		self.profReq = nil
	end
end

GH.handlers.RLIST = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "WHISPER" then return end
	local name = U.ValidName(data.n)
	local line = data.k
	if not (name and PROFS[line]) or name == self:MyName() then return end
	local req = self.profReq
	local key = name .. "\001" .. line
	if data.no then
		-- they have no such list: ask someone else (for a while)
		self.profMiss[sender .. "\001" .. key] = GetTime() + SRC_BACKOFF
		if req and req.to == sender then
			req.keys[key] = nil
			if next(req.keys) == nil then self.profReq = nil end
		end
		return
	end
	local h = U.ValidNumber(data.h, 0, 2147483647)
	local count = data.c == nil and 1 or U.ValidNumber(data.c, 1, math.ceil(MAX_LIST_CHARS / CHUNK) + 1)
	local i = data.i == nil and 1 or U.ValidNumber(data.i, 1, count or 1)
	if not (h and count and i and type(data.l) == "string" and #data.l <= MAX_LIST_CHARS) then return end
	if req and req.to == sender then
		req.got = true
		req.t = GetTime() -- pieces still coming in: the request is alive
	end
	-- put the pieces together (a new hash or piece 1 starts over)
	local now = GetTime()
	for k, b in pairs(self.rlistParts) do
		if now - b.t > PARTS_TIMEOUT then self.rlistParts[k] = nil end
	end
	local pk = sender .. "\001" .. key
	local b = self.rlistParts[pk]
	if i == 1 then
		b = { h = h, c = count, got = {}, n = 0, t = now }
		self.rlistParts[pk] = b
	elseif not b or b.h ~= h or b.c ~= count then
		return -- a piece of a list we did not see start (whispers arrive in order)
	end
	if not b.got[i] then b.got[i], b.n = data.l, b.n + 1 end
	b.t = now
	if b.n < b.c then return end
	self.rlistParts[pk] = nil
	local whole = table.concat(b.got, "", 1, b.c)
	if req and req.to == sender then
		req.keys[key] = nil
		if next(req.keys) == nil then self.profReq = nil end
	end
	local prof = MemberProf(name)
	local e = prof and prof.p[line]
	if not (e and e.h == h) then return end
	local ids = self:DecodeRecipes(whole)
	if not ids then return end
	local enc = self:EncodeRecipes(ids)
	if self:RecipeHash(enc) ~= h then return end
	e.l, e.old = enc, nil
	self.profDirty = true
	self:RefreshProfTab()
end

------------------------------------------------------------------------
-- Guild list: players who left lose their professions and feed lines
------------------------------------------------------------------------
function GH:ProfRosterCheck(roster)
	local gdb = self:GetGuildDB()
	if not gdb or type(roster) ~= "table" or next(roster) == nil then return end
	local now = U.Now()
	local gone = {}
	for name, m in pairs(gdb.members) do
		if roster[name] then
			m.profGone = nil
		elseif m.prof or m.profGone then
			m.profGone = m.profGone or now
			if now - m.profGone >= GONE_SECONDS then
				m.prof = nil
				gone[name] = true
			end
		end
	end
	if next(gone) then
		for i = #gdb.feed, 1, -1 do
			if gone[gdb.feed[i].who] then table.remove(gdb.feed, i) end
		end
		for name in pairs(gone) do self.profSrc[name] = nil end
		self.profDirty = true
		self:RefreshProfTab()
	end
end

------------------------------------------------------------------------
-- Index, rows for the tab, tooltips
------------------------------------------------------------------------
local nameCache = {}
function GH:RecipeName(id)
	local c = nameCache[id]
	if c == nil and C_Spell and C_Spell.GetSpellName then -- only names are cached: a miss is asked again later
		local n = C_Spell.GetSpellName(id)
		if type(n) == "string" and not U.IsSecret(n) then
			c = n
			nameCache[id] = n
		end
	end
	return c
end

-- recipe ID -> { { name, line, rank } ... }, plus lower-case name -> { recipe IDs }.
function GH:ProfIndex()
	if self.profIndex and not self.profDirty then return self.profIndex end
	local idx = { byRecipe = {}, byName = {}, recipes = 0 }
	local gdb = self:GetGuildDB()
	local me = self:MyName()
	if gdb then
		for name, m in pairs(gdb.members) do
			local prof = type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof
			if prof and (name == me or self:IsGuildMember(name)) then
				for line, e in pairs(prof.p) do
					for _, id in ipairs(e.l and self:DecodeRecipes(e.l) or {}) do
						local list = idx.byRecipe[id]
						if not list then
							list = {}
							idx.byRecipe[id] = list
							idx.recipes = idx.recipes + 1
						end
						list[#list + 1] = { name = name, line = line, rank = e.r or 0 }
					end
				end
			end
		end
	end
	for id in pairs(idx.byRecipe) do
		local n = self:RecipeName(id)
		if n then
			local key = n:lower()
			idx.byName[key] = idx.byName[key] or {}
			table.insert(idx.byName[key], id)
		end
	end
	self.profIndex, self.profDirty = idx, false
	return idx
end

local function FilterOK(filter, line)
	if not filter or filter == "all" then return true end
	local p = PROFS[line]
	if not p then return false end
	if filter == "gather" then return p.kind == "gather" or p.kind == "fish" end
	return p.key == filter
end

-- "self" (this character) / "alt" (another of your characters, Alts.lua) / nil
function GH:MineKind(name)
	if name == self:MyName() then return "self" end
	if self.IsMyAlt and self:IsMyAlt(name) then return "alt" end
	return nil
end

-- Crafters of one recipe: guildmates first (online, then skill), your own characters last.
-- ask = an online guildmate you can send a request to (never yourself or your alts).
function GH:Crafters(list)
	local r = {}
	for _, c in ipairs(list or {}) do
		local mine = self:MineKind(c.name)
		local on = Online(c.name)
		r[#r + 1] = { name = c.name, line = c.line, rank = c.rank, online = on, mine = mine, ask = on and not mine }
	end
	tsort(r, function(a, b)
		if (a.mine ~= nil) ~= (b.mine ~= nil) then return b.mine ~= nil end
		if a.online ~= b.online then return a.online end
		if a.rank ~= b.rank then return a.rank > b.rank end
		return a.name < b.name
	end)
	return r
end

-- Directory rows: header per profession, then members by skill.
-- opts = { filter, online = true (online only), search (name filter, lower case) }
function GH:BuildProfRows(opts)
	opts = opts or {}
	local gdb = self:GetGuildDB()
	local rows, crafters = {}, 0
	if not gdb or not self:CanUse("prof") then return rows, 0 end -- fair trade
	local me = self:MyName()
	local groups = {}
	for name, m in pairs(gdb.members) do
		local prof = type(m.prof) == "table" and type(m.prof.p) == "table" and m.prof
		local isSelf = name == me
		if prof and (isSelf or self:IsGuildMember(name)) then
			local on = isSelf or Online(name)
			if not opts.online or on then
				local any = false
				for line, e in pairs(prof.p) do
					if FilterOK(opts.filter, line) then
						groups[line] = groups[line] or {}
						local r = self.roster[name]
						table.insert(groups[line], {
							name = name, class = m.class or (r and r.class), line = line, rank = e.r, max = e.m,
							spec = self:SpecName(e.s), recipes = e.n or 0, online = on, isSelf = isSelf,
							mine = self:MineKind(name),
							lastSeen = m.lastSeen, old = e.old,
						})
						any = true
					end
				end
				if any then crafters = crafters + 1 end
			end
		end
	end
	for _, line in ipairs(ORDER) do
		local g = groups[line]
		if g then
			tsort(g, function(a, b)
				if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) > (b.rank or 0) end
				if a.online ~= b.online then return a.online end
				return a.name < b.name
			end)
			rows[#rows + 1] = { header = line, count = #g }
			for _, r in ipairs(g) do rows[#rows + 1] = r end
		end
	end
	return rows, crafters
end

-- Search rows: one per matching recipe. query = 2+ letters.
function GH:BuildRecipeRows(opts)
	opts = opts or {}
	local q = type(opts.search) == "string" and opts.search:lower() or ""
	local rows = {}
	if #q < 2 or not self:CanUse("prof") then return rows end -- fair trade
	local idx = self:ProfIndex()
	for id, list in pairs(idx.byRecipe) do
		local name = self:RecipeName(id)
		if name and name:lower():find(q, 1, true) then
			local cs = self:Crafters(list)
			local keep, line, on = {}, nil, 0
			for _, c in ipairs(cs) do
				if FilterOK(opts.filter, c.line) and (not opts.online or c.online) then
					keep[#keep + 1] = c
					line = line or c.line
					if c.ask then on = on + 1 end -- your own characters don't count
				end
			end
			if #keep > 0 then
				rows[#rows + 1] = { recipe = id, rname = name, line = line, crafters = keep, onlineCount = on }
			end
		end
		if #rows >= 200 then break end
	end
	tsort(rows, function(a, b) return a.rname < b.rname end)
	return rows
end

-- "Professions: Tailoring 300, Alchemy 285" for the status board tooltip.
function GH:ProfLine(name)
	if not self:CanUse("prof") then return nil end -- fair trade
	local prof = MemberProf(name)
	if not prof or next(prof.p) == nil then return nil end
	local parts = {}
	for _, line in ipairs(ORDER) do
		local e = prof.p[line]
		if e then parts[#parts + 1] = self:ProfName(line) .. (e.r and (" " .. e.r) or "") end
	end
	return L.PROF_LINE:format(tconcat(parts, ", "))
end

-- Item tooltip: one added line "Guild Hub: crafted by ...". Never in combat; never replaces anything.
function GH:TooltipCrafters(itemName)
	if type(itemName) ~= "string" or U.IsSecret(itemName) or itemName == "" then return nil end
	if not self:CanUse("prof") then return nil end -- fair trade: no crafted-by line
	local idx = self:ProfIndex()
	local ids = idx.byName[itemName:lower()]
	if not ids then return nil end
	-- only a known craft starts the list fetching (not every item someone hovers; tos check)
	self:WantRecipeLists()
	local seen, all = {}, {}
	for _, id in ipairs(ids) do
		for _, c in ipairs(self:Crafters(idx.byRecipe[id])) do
			if not seen[c.name] then seen[c.name] = true; all[#all + 1] = c end
		end
	end
	if #all == 0 then return nil end
	-- guildmates first; your own characters (Alts.lua) at the end of the same line, never as someone to ask
	local others, mine = {}, {}
	for _, c in ipairs(all) do
		if c.mine then mine[#mine + 1] = self:MineLabel(c) else others[#others + 1] = c end
	end
	local own = #mine > 0 and tconcat(mine, ", ") or nil
	if #others == 0 then return own and L.TIP_ONLY_YOU:format(own) or nil end
	local names = {}
	for i = 1, math.min(3, #others) do
		local c = others[i]
		local s = U.ShortName(c.name)
		names[i] = c.online and ("|cff40ff40" .. s .. "|r") or s
	end
	local more = #others > 3 and L.TIP_MORE:format(#others - 3) or ""
	return L.TIP_CRAFTERS:format(tconcat(names, ", ") .. more) .. (own and L.TIP_YOURS:format(own) or "")
end

-- "this character" / "Mira (alt)" for a crafter row with c.mine set.
function GH:MineLabel(c)
	if c.mine == "self" then return L.ALT_THIS end
	return L.ALT_TAG:format(U.ShortName(c.name))
end

function GH:InitProfTooltip()
	if self.profTooltipHooked then return end
	local TDP = TooltipDataProcessor
	local kind = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
	if not (TDP and TDP.AddTooltipPostCall and kind) then return end
	self.profTooltipHooked = true
	TDP.AddTooltipPostCall(kind, function(tt, data)
		if not GH.db.profile.profTooltip or InCombatLockdown() or not GH.profStarted then return end
		if type(tt) ~= "table" or not tt.AddLine or type(data) ~= "table" then return end
		local ok, line = pcall(function()
			local id = data.id
			if type(id) ~= "number" or U.IsSecret(id) then return nil end
			local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
			return GH:TooltipCrafters(name)
		end)
		if ok and line then tt:AddLine(line, 0.55, 0.8, 1) end
	end)
end

------------------------------------------------------------------------
-- Request craft: fills the chat box (the player presses Enter); never for offline crafters.
------------------------------------------------------------------------
function GH:RequestText(recipeID)
	local name = self:RecipeName(recipeID) or "?"
	local link
	local T = C_TradeSkillUI
	if T and T.GetRecipeOutputItemData then
		local ok, out = pcall(T.GetRecipeOutputItemData, recipeID)
		if ok and type(out) == "table" and type(out.hyperlink) == "string" and not U.IsSecret(out.hyperlink) then link = out.hyperlink end
	end
	local text = L.REQ_TEXT:format(link or name)
	if self.db.profile.profMats then text = text .. " " .. L.REQ_MATS end
	return text
end

function GH:RequestCraft(recipeID, crafter)
	if type(crafter) ~= "string" or crafter == self:MyName() then return false end
	if self.IsMyChar and self:IsMyChar(crafter) then return false end -- never whisper your own alt
	if not self:IsOnline(crafter) then return false end
	local text = "/w " .. U.WhisperName(crafter) .. " " .. self:RequestText(recipeID)
	local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
	if not open then return false end
	return (pcall(open, text))
end

------------------------------------------------------------------------
-- Start-up and events
------------------------------------------------------------------------
function GH:RefreshProfTab()
	if self.DrawProfessionsTab and self.profTab and self.profTab.page and self.profTab.page:IsShown() then
		if self.profTimer then return end
		self.profTimer = self:ScheduleTimer(function()
			GH.profTimer = nil
			GH:DrawProfessionsTab()
		end, 0.3)
	end
end

-- Professions on the registry: switchable (Settings > Features, or an officer for the guild).
-- Off = no events, no jobs, no PROF/RREQ/RLIST sent or handled, no tooltip line, no tab.
GH:RegisterFeature({
	key = "prof", name = "OPT_FEAT_PROF",
	messages = {
		PROF  = { class = "normal", min = 60, keep = true, latest = true }, -- tos check: at most one per minute
		RREQ  = { class = "normal", min = 3 },  -- recipe list request (per target)
		RLIST = { class = "bulk", min = 0 },    -- recipe list answers: paced here (bytes per second)
	},
	enable = function() GH:InitProfessions() end,
	disable = function()
		GH.profStarted = nil
		GH.rlistQueue, GH.profReq = {}, nil
		if GH.RefreshProfTab then GH:RefreshProfTab() end
	end,
})

function GH:InitProfessions()
	if self.profStarted then return end
	self.profStarted = true
	local pendingScan, pendingSkills
	local function OnProfEvent(event, a1)
		if event == "TRAINER_SHOW" then GH.atTrainer = true
		elseif event == "TRAINER_CLOSED" then GH.atTrainer = false
		elseif event == "NEW_RECIPE_LEARNED" then GH:OnRecipeLearned(a1)
		elseif event == "SKILL_LINES_CHANGED" then
			if not pendingSkills then
				pendingSkills = true
				GH:ScheduleTimer(function() pendingSkills = false; GH:ReadOwnSkills() end, 2)
			end
		elseif event == "PLAYER_REGEN_ENABLED" then
			if GH.profScanAfterCombat then GH.profScanAfterCombat = nil; GH:ScanOpenWindow() end
		elseif not pendingScan then -- TRADE_SKILL_SHOW / LIST_UPDATE
			pendingScan = true
			GH:ScheduleTimer(function() pendingScan = false; if GH.profStarted then GH:ScanOpenWindow() end end, 1)
		end
	end
	for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED",
		"TRAINER_SHOW", "TRAINER_CLOSED", "PLAYER_REGEN_ENABLED" }) do
		self:On("prof", e, OnProfEvent)
	end
	self:ReadOwnSkills()
	self:InitProfTooltip()
	self:Every("prof", "fetch", 3, function() GH:ProfFetchTick() end)
	self:Every("prof", "rlist", 0.5, function() GH:RListTick() end)
	-- our summary 20 s after HELLO (then on changes, at most once per 60 s)
	self:ScheduleTimer(function()
		if not GH.profStarted then return end
		GH.profReady = true
		GH:ReadOwnSkills()
		GH:QueueOwnProf()
	end, 20)
end

-- The feed's newest lines (for the tab).
function GH:FeedLines(max)
	local gdb = self:GetGuildDB()
	local r = {}
	if not gdb or not self:CanUse("prof") then return r end -- fair trade: no rare-recipe feed
	for _, e in ipairs(gdb.feed) do
		if type(e) == "table" and e.r and e.who then
			r[#r + 1] = e
			if #r >= (max or FEED_SHOWN) then break end
		end
	end
	return r
end

-- /ghub test prof: what this client gives (counts and IDs only, no names).
function GH:TestProf()
	local yes = function(v) return v and L.YES or L.NO end
	local parts = {}
	if GetProfessions and GetProfessionInfo then
		for _, idx in ipairs(ProfIndices()) do
			if type(idx) == "number" then
				local _, _, rank, max, _, _, line = GetProfessionInfo(idx)
				parts[#parts + 1] = ("%s=%s/%s"):format(tostring(line), tostring(rank), tostring(max))
			end
		end
	end
	local T = C_TradeSkillUI
	local win, learned, total, out, sched, src = "-", 0, 0, "-", "-", "-"
	if T and T.GetBaseProfessionInfo then
		local info = T.GetBaseProfessionInfo()
		if type(info) == "table" then win = ("%s/enum %s"):format(tostring(info.professionID), tostring(info.profession)) end
		local all = T.GetAllRecipeIDs and T.GetAllRecipeIDs() or {}
		total = #all
		for _, id in ipairs(all) do
			local r = T.GetRecipeInfo(id)
			if type(r) == "table" and r.learned then
				learned = learned + 1
				if src == "-" then src = tostring(r.sourceType) end
			end
		end
		local first = all[1]
		if first then
			local ok, o = pcall(T.GetRecipeOutputItemData, first)
			out = yes(ok and type(o) == "table" and o.itemID)
			local ok2, s = pcall(T.GetRecipeSchematic, first, false)
			sched = yes(ok2 and type(s) == "table" and s.reagentSlotSchematics and #s.reagentSlotSchematics > 0)
		end
	end
	local specs = {}
	if IsPlayerSpell then for spell in pairs(SPECS) do if IsPlayerSpell(spell) then specs[#specs + 1] = spell end end end
	self:Msg(L.TEST_PROF, tconcat(parts, " "), win, learned, total, out, sched, src,
		#specs > 0 and tconcat(specs, ",") or "-", yes(TooltipDataProcessor), yes(C_Spell and C_Spell.GetSpellName))
end
