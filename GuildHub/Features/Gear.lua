-- Guild Hub: gear viewer data, N3 missing-enchant marks and the officers' "Check enchants" run
-- (1.0.2, plans\next-batch-2-1.0.x X3, tos-check.md). Feature "gear", switchable; share item "gear".
-- tos: own gear only, sent only when a guildmate asks (BLOB, Blob.lua), as numbers only
-- (itemID:enchantID:suffixID per slot, never links, names or text); a secret slot is skipped;
-- copies are saved only for Guild Hub users (they come from the owner) and go with the member (90 days).
-- Missing-enchant results are shown only on the viewer's screen and never posted.
local _, ns = ...
local GH, L, U = ns.GH, ns.L, ns.Util

local KIND = "gear"
local MAX_BYTES = 600
local FRESH = 600            -- a copy got within 10 min is used without asking
local CHECK_GAP = 4          -- Check enchants: one request per 4 s
local CHECK_COOLDOWN = 300   -- 5 min after a run ends
local SLOT_FIRST, SLOT_LAST = 1, 19
GH.GEAR_LIMITS = { MAX_BYTES = MAX_BYTES, FRESH = FRESH, CHECK_GAP = CHECK_GAP, CHECK_COOLDOWN = CHECK_COOLDOWN }

-- Slots checked for N3 (D4): back, chest, wrists, hands, feet, main hand, off hand (shields only),
-- ranged (hunters only). Head, shoulders and legs are never flagged.
local ENCHANT_SLOTS = { [15] = "any", [5] = "any", [9] = "any", [10] = "any", [8] = "any", [16] = "any",
	[17] = "shield", [18] = "hunter" }
GH.GEAR_ENCHANT_SLOTS = ENCHANT_SLOTS
-- the panel's order: left column, right column, bottom row
GH.GEAR_LAYOUT = { left = { 1, 2, 3, 15, 5, 4, 19, 9 }, right = { 10, 6, 7, 8, 11, 12, 13, 14 }, bottom = { 16, 17, 18 } }

GH.gearStats = { secret = 0, sent = 0, got = 0, same = 0, no = 0, failed = 0, checks = 0 }
GH.gearNo = {}        -- [name] = true: answered "not shared" this session
GH.gearFail = {}      -- [name] = why: the last request failed (timeout / no answer)
GH.gearAsking = {}    -- [name] = true while a request waits

local function Plain(v) return v ~= nil and not U.IsSecret(v) end

------------------------------------------------------------------------
-- Sharing
------------------------------------------------------------------------
function GH:SharesGear()
	return self.db and self.db.profile.shareGear ~= false
end

-- HELLO / HB field "gr": 1 = gear off, 2 = gear shared (older clients send none: addonUsers[name].gr = false).
function GH:GearCap()
	if not self:FeatureOn("gear") then return 1 end
	return (self:SharesGear() and not self.cannotSend) and 2 or 1
end

------------------------------------------------------------------------
-- Own gear (read live, never saved)
------------------------------------------------------------------------
-- "item:id:ench:g1:g2:g3:g4:suffix:..." -> id, ench, suffix (numbers) or nil
function GH.ParseItemLink(link)
	if type(link) ~= "string" or U.IsSecret(link) then return nil end
	local s = link:match("item:([%-%d:]+)")
	if not s then return nil end
	local f = {}
	for v in (s .. ":"):gmatch("([^:]*):") do f[#f + 1] = v end
	local id = tonumber(f[1] or "")
	if not id or id <= 0 or id > 9999999 then return nil end
	local ench = tonumber(f[2] or "") or 0
	local suf = tonumber(f[7] or "") or 0
	if ench < 0 or ench > 999999 then ench = 0 end
	if suf < -999999 or suf > 999999 then suf = 0 end
	return id, ench, suf
end

-- {[slot] = {id, e, x}}; secret or missing slots left out.
function GH:OwnGear()
	local s = {}
	if type(GetInventoryItemLink) ~= "function" then return s end
	for slot = SLOT_FIRST, SLOT_LAST do
		local ok, link = pcall(GetInventoryItemLink, "player", slot)
		if ok and link ~= nil then
			if U.IsSecret(link) then
				self.gearStats.secret = self.gearStats.secret + 1 -- tos: skip, never work around
			else
				local id, e, x = GH.ParseItemLink(link)
				if id then s[slot] = { id = id, e = e, x = x } end
			end
		end
	end
	return s
end

local function B36(n)
	if n == 0 then return "" end
	local neg = n < 0
	n = math.abs(n)
	local digits, r = "0123456789abcdefghijklmnopqrstuvwxyz", ""
	while n > 0 do
		local d = n % 36
		r = digits:sub(d + 1, d + 1) .. r
		n = (n - d) / 36
	end
	return (neg and "-" or "") .. r
end
local function FromB36(s)
	if s == "" then return 0 end
	local neg = s:sub(1, 1) == "-"
	if neg then s = s:sub(2) end
	if not s:match("^[0-9a-z]+$") or #s > 6 then return nil end
	local n = tonumber(s, 36)
	return n and (neg and -n or n) or nil
end

-- The BLOB payload: "slot.id.ench.suffix;..." in base 36 (numbers only).
function GH:EncodeGear(s)
	local parts = {}
	for slot = SLOT_FIRST, SLOT_LAST do
		local g = s[slot]
		if g then parts[#parts + 1] = ("%d.%s.%s.%s"):format(slot, B36(g.id), B36(g.e or 0), B36(g.x or 0)) end
	end
	return table.concat(parts, ";")
end

-- Received payload -> {[slot] = {id, e, x}} or nil (anything odd = the whole copy is dropped).
function GH:DecodeGear(data)
	if type(data) ~= "string" or #data > MAX_BYTES then return nil end
	local s, n = {}, 0
	if data == "" then return s end
	for entry in (data .. ";"):gmatch("([^;]*);") do
		local slot, a, b, c = entry:match("^(%d+)%.([%-0-9a-z]*)%.([%-0-9a-z]*)%.([%-0-9a-z]*)$")
		slot = tonumber(slot or "")
		local id, e, x = a and FromB36(a), b and FromB36(b), c and FromB36(c)
		if not (slot and slot >= SLOT_FIRST and slot <= SLOT_LAST and id and id > 0 and id <= 9999999
			and e and e >= 0 and e <= 999999 and x and x >= -999999 and x <= 999999) or s[slot] then
			return nil
		end
		s[slot] = { id = id, e = e, x = x }
		n = n + 1
	end
	return s, n
end

------------------------------------------------------------------------
-- Saved copies: members[name].gear = { ts, h, s = {[slot] = "id:ench:suffix"} }
------------------------------------------------------------------------
local function SlotString(g) return ("%d:%d:%d"):format(g.id, g.e or 0, g.x or 0) end
local function FromSlotString(v)
	if type(v) ~= "string" or #v > 24 then return nil end
	local id, e, x = v:match("^(%d+):(%d+):(%-?%d+)$")
	id, e, x = tonumber(id or ""), tonumber(e or ""), tonumber(x or "")
	if not (id and id > 0 and id <= 9999999 and e and e <= 999999 and x and x >= -999999 and x <= 999999) then return nil end
	return { id = id, e = e, x = x }
end

-- A saved copy, cleaned (bad slots dropped, a broken copy removed). Returns copy {ts, h, s} or nil.
function GH:GearCopy(name)
	local gdb = self:GetGuildDB()
	local m = gdb and gdb.members[name]
	if type(m) ~= "table" or m.gear == nil then return nil end
	local g = m.gear
	if type(g) ~= "table" or type(g.s) ~= "table" or not U.ValidNumber(g.ts, 0, 4102444800) then
		m.gear = nil
		return nil
	end
	local s = {}
	for slot, v in pairs(g.s) do
		local t = type(slot) == "number" and slot >= SLOT_FIRST and slot <= SLOT_LAST and FromSlotString(v)
		if t then s[slot] = t else g.s[slot] = nil end
	end
	return { ts = g.ts, h = g.h, s = s }
end

-- The owner stopped sharing gear (HELLO/HB gr = 1 or a "no" answer): their saved copy is removed for good
-- (tos: their choice counts while they are offline too). Returns true when one was removed.
function GH:DropGearCopy(name)
	local gdb = self:GetGuildDB()
	local m = gdb and type(name) == "string" and gdb.members[name]
	if type(m) ~= "table" or m.gear == nil then return false end
	m.gear = nil
	if self.RefreshGearPanel then self:RefreshGearPanel(name) end
	if self.RefreshBoardsTab then self:RefreshBoardsTab() end
	return true
end

local function StoreCopy(gh, name, s, h)
	local gdb = gh:GetGuildDB()
	if not gdb or not gh:IsGuildMember(name) then return false end
	local m = gdb.members[name]
	if type(m) ~= "table" then
		m = { ts = 0, lastSeen = U.Now() }
		gdb.members[name] = m
	end
	local out = {}
	for slot, g in pairs(s) do out[slot] = SlotString(g) end
	m.gear = { ts = U.Now(), h = h, s = out }
	return true
end

------------------------------------------------------------------------
-- Missing enchants (N3)
------------------------------------------------------------------------
local function ItemClass(id)
	local fn = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
	if type(fn) ~= "function" then return nil end
	local ok, _, _, _, _, _, classID, subID = pcall(fn, id)
	if not ok or not Plain(classID) then return nil end
	return classID, subID
end

-- Is this slot (with this item) one we check? class = the owner's class token.
function GH:GearSlotChecked(slot, g, class)
	local rule = ENCHANT_SLOTS[slot]
	if not rule or not g then return false end
	if rule == "any" then return true end
	local classID, subID = ItemClass(g.id)
	if rule == "shield" then return classID == 4 and subID == 6 end -- Armor / Shields
	if rule == "hunter" then return class == "HUNTER" and classID == 2 end -- a weapon (bow, gun, crossbow)
	return false
end

-- slots = {[slot] = {id, e, x}} -> list of slots without an enchant (sorted), checked count
function GH:GearMissing(slots, class)
	local miss, checked = {}, 0
	for slot in pairs(ENCHANT_SLOTS) do
		local g = slots[slot]
		if self:GearSlotChecked(slot, g, class) then
			checked = checked + 1
			if (g.e or 0) == 0 then miss[#miss + 1] = slot end
		end
	end
	table.sort(miss)
	return miss, checked
end

function GH:GearSlotName(slot) return L.GEAR_SLOT[slot] or tostring(slot) end

function GH:GearMissingText(miss)
	local names = {}
	for i, slot in ipairs(miss) do names[i] = self:GearSlotName(slot) end
	return table.concat(names, ", ")
end

------------------------------------------------------------------------
-- What the panel / board / hover card show for one name
------------------------------------------------------------------------
local function ClassOf(gh, name)
	local r = gh.roster[name]
	if r and r.class then return r.class end
	local gdb = gh:GetGuildDB()
	local m = gdb and gdb.members[name]
	return m and m.class or nil
end

-- state: self / locked / feature / older / notshared / fresh / asking / saved / noanswer / none / busy
-- Never asks by itself; ask = true lets the panel queue ONE request (tos: on a click).
function GH:GearView(name, ask)
	local v = { name = name, class = ClassOf(self, name) }
	if not self:FeatureOn("gear") then v.state = "feature" return v end
	if name == self:MyName() then
		v.state, v.s, v.ts = "self", self:OwnGear(), U.Now()
		v.miss = self:GearMissing(v.s, v.class)
		return v
	end
	local can, why = self:CanUse("gear")
	if not can then v.state = why == "trial" and "trial" or "locked" return v end
	local copy = self:GearCopy(name)
	if copy then v.s, v.ts, v.h = copy.s, copy.ts, copy.h; v.miss = self:GearMissing(copy.s, v.class) end
	local u = self.addonUsers[name]
	local online = self:IsAddonUserOnline(name)
	if online and u and u.gr == false then v.state = "older" return v end -- heard their HB: no gear field
	if online and (u and u.gr == 1 or self.gearNo[name]) then
		v.state = "notshared"
		v.s, v.miss = nil, nil -- their own choice now: no old copy shown
		return v
	end
	if copy and U.Now() - copy.ts < FRESH then v.state = "fresh" return v end
	if self.gearAsking[name] or self:BlobWaiting(KIND, name) then v.state = "asking" return v end
	-- known only from someone else's sync list (Sync.lua): no gear field yet = not asked until their own
	-- HELLO / HB says whether they share gear
	if online and (not u or u.gr == nil) then v.state = copy and "saved" or "unknown" return v end
	if online and ask then
		local ok = self:BlobRequest(KIND, name, copy and copy.h)
		if ok then
			self.gearAsking[name] = true
			self.gearFail[name] = nil
			v.state = "asking"
			return v
		end
		v.state = copy and "saved" or "busy"
		return v
	end
	if online and self.gearFail[name] then v.state = "noanswer" return v end
	v.state = copy and "saved" or "none"
	return v
end

-- Enchants column / hover line, from what we already have (never asks). Returns kind, n, slots text.
-- kind: "missing" / "ok" / "none" (no copy or older Guild Hub) / "notshared"
function GH:GearEnchantInfo(name)
	if not self:FeatureOn("gear") then return nil end
	if name ~= self:MyName() and not self:CanUse("gear") then return nil end
	local v = self:GearView(name, false)
	if v.state == "notshared" then return "notshared" end
	if not v.s or not v.miss then return "none" end
	if #v.miss > 0 then return "missing", #v.miss, self:GearMissingText(v.miss), v.ts end
	return "ok", 0, nil, v.ts
end

------------------------------------------------------------------------
-- BLOB kind "gear"
------------------------------------------------------------------------
local function Changed(name)
	if GH.RefreshGearPanel then GH:RefreshGearPanel(name) end
	if GH.RefreshBoardsTab then GH:RefreshBoardsTab() end
end

GH:BlobKind(KIND, {
	feature = "gear", maxBytes = MAX_BYTES,
	canAsk = function(gh) return gh:CanUse("gear") end,
	build = function(gh)
		if not (gh:FeatureOn("gear") and gh:SharesGear()) or gh.cannotSend then return nil end
		local data = gh:EncodeGear(gh:OwnGear())
		gh.gearStats.sent = gh.gearStats.sent + 1
		return data ~= "" and data or nil
	end,
	accept = function(gh, owner, data, h, same)
		gh.gearAsking[owner] = nil
		gh.gearFail[owner] = nil
		gh.gearNo[owner] = nil
		if same then
			local gdb = gh:GetGuildDB()
			local m = gdb and gdb.members[owner]
			if type(m) == "table" and type(m.gear) == "table" and m.gear.h == h then m.gear.ts = U.Now() end
			gh.gearStats.same = gh.gearStats.same + 1
		else
			local s = gh:DecodeGear(data)
			if not s then gh.gearFail[owner] = "bad" Changed(owner) return end
			StoreCopy(gh, owner, s, h)
			gh.gearStats.got = gh.gearStats.got + 1
		end
		Changed(owner)
	end,
	fail = function(gh, owner, why)
		gh.gearAsking[owner] = nil
		if why == "no" then
			gh.gearNo[owner] = true
			gh:DropGearCopy(owner)
			gh.gearStats.no = gh.gearStats.no + 1
		else
			gh.gearFail[owner] = why or "timeout"
			gh.gearStats.failed = gh.gearStats.failed + 1
		end
		Changed(owner)
	end,
})

------------------------------------------------------------------------
-- Officers: Check enchants (D5; tos: one click = one run, 1 request per 4 s, online raid members with
-- Guild Hub only, copies younger than 10 min skipped; stops on combat / instance / lockdown; no repeat;
-- 5 min cooldown; results only on this screen)
------------------------------------------------------------------------
GH.gearCheck = nil -- { list, i, done, started, last, stopped }

local function RaidNames(gh)
	local out = {}
	if not (IsInRaid and IsInRaid()) then return out end
	local me = gh:MyName()
	for name in pairs(gh.myGroup or {}) do
		if name ~= me then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

-- ok, why, seconds: officer / raid / combat / instance / lockdown / running / cooldown / share
function GH:CheckEnchantsState()
	if not self:FeatureOn("gear") then return false, "feature" end
	if not (self.rosterReady and self:IsOfficer(self:MyName())) then return false, "officer" end
	if self.gearCheck and self.gearCheck.running then return false, "running" end
	if not self:CanUse("gear") then return false, "share" end
	if not (IsInRaid and IsInRaid()) then return false, "raid" end
	if InCombatLockdown and InCombatLockdown() then return false, "combat" end
	if IsInInstance() then return false, "instance" end
	if self:InLockdown() then return false, "lockdown" end
	local left = (self.gearCheckEnd or -1000) + CHECK_COOLDOWN - GetTime()
	if self.gearCheckEnd and left > 0 then return false, "cooldown", math.ceil(left) end
	return true
end

function GH:CheckEnchantsStart()
	if not self:CheckEnchantsState() then return false end
	local list = {}
	for _, name in ipairs(RaidNames(self)) do
		local u = self.addonUsers[name]
		local copy = self:GearCopy(name)
		if self:IsAddonUserOnline(name) and u and u.gr == 2 and not (copy and U.Now() - copy.ts < FRESH) then
			list[#list + 1] = name
		end
	end
	self.gearCheck = { list = list, i = 0, running = true, started = GetTime(), last = -1000, total = #list }
	self.gearStats.checks = self.gearStats.checks + 1
	self:Every("gear", "check", 1, function() GH:CheckEnchantsTick() end)
	if #list == 0 then self:CheckEnchantsStop("done") end
	Changed()
	return true
end

function GH:CheckEnchantsStop(why)
	local c = self.gearCheck
	if not c or not c.running then return end
	c.running = false
	c.stopped = why or "stopped"
	self.gearCheckEnd = GetTime()
	self:Cancel("gear", "check")
	-- requests of this run still waiting are dropped
	local names = {}
	for _, n in ipairs(c.list) do names[n] = true end
	self:BlobDropQueued(function(q) return q.k == KIND and names[q.o] end)
	for n in pairs(names) do self.gearAsking[n] = nil end
	Changed()
end

function GH:CheckEnchantsTick()
	local c = self.gearCheck
	if not c or not c.running then return end
	if InCombatLockdown and InCombatLockdown() then return self:CheckEnchantsStop("combat") end
	if IsInInstance() then return self:CheckEnchantsStop("instance") end
	if self:InLockdown() then return self:CheckEnchantsStop("lockdown") end
	local now = GetTime()
	if c.i >= #c.list then
		if not self.blobReq and #self.blobQueue == 0 then self:CheckEnchantsStop("done") end
		return
	end
	if now - c.last < CHECK_GAP or self.blobReq or #self.blobQueue > 0 then return end
	c.i = c.i + 1
	c.last = now
	local name = c.list[c.i]
	local copy = self:GearCopy(name)
	if self:BlobRequest(KIND, name, copy and copy.h) then self.gearAsking[name] = true end
	Changed()
end

-- "Checking 12 / 31" / nil
function GH:CheckEnchantsProgress()
	local c = self.gearCheck
	if not c then return nil end
	return c.i, c.total, c.running, c.stopped
end

------------------------------------------------------------------------
-- Settings-only data repair (Store RepairSaved)
------------------------------------------------------------------------
function GH:RepairGearSaved(db)
	local fixed = {}
	local p = db and db.profile
	if type(p) == "table" then
		for _, k in ipairs({ "shareGear", "gearTooltip", "gearMarks", "recipeLearnLine", "gearNewSeen" }) do
			local v = rawget(p, k)
			-- AceDB copies plain defaults into the profile: put the default back (gearNewSeen has none)
			if v ~= nil and type(v) ~= "boolean" then p[k] = (k ~= "gearNewSeen") or nil; fixed[#fixed + 1] = k end
		end
	end
	return fixed
end

------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------
local function HoverLine(gh, name)
	if not gh.db.profile.gearTooltip or name == gh:MyName() then return nil end
	local kind, n, slots = gh:GearEnchantInfo(name)
	if kind == "missing" then return L.GEAR_HOVER_MISSING:format(n, slots), 1, 0.55, 0.15 end
	if kind == "ok" then return L.GEAR_HOVER_OK, 0.6, 0.9, 0.6 end
	return nil
end

GH:RegisterFeature({
	key = "gear", name = "OPT_FEAT_GEAR",
	defaults = { profile = { shareGear = true, gearTooltip = true, gearMarks = true, recipeLearnLine = true } },
	messages = {
		BREQ = { class = "normal", min = 3 }, -- one request at a time (Blob.lua paces it too)
		BLST = { class = "bulk", min = 0 },                  -- answers: paced by Blob.lua (bytes per second)
	},
	enable = function()
		GH:BlobStart("gear")
	end,
	disable = function()
		GH:BlobReset()
		if GH.gearCheck then GH.gearCheck.running = false end
		GH.gearAsking = {}
		if GH.HideGearPanel then GH:HideGearPanel() end
	end,
	nameMenu = {
		{ kind = "top", order = 10, fn = function(gh, name)
			return { { key = "gear", text = L.MENU_GEAR, run = function() gh:ShowGearPanel(name) end } }
		end },
	},
	hoverLines = { { fn = HoverLine } },
	selftest = function(api) if GH.GearSelfTest then GH:GearSelfTest(api) end end,
})

-- Fair trade: no gear shared = no one's gear shown to you.
GH:RegisterShare({
	key = "gear", order = 6, optKey = "shareGear", feature = "gear",
	name = "OPT_SHAREGEAR", desc = "OPT_SHAREGEAR_DESC",
	get = function(gh) return gh:SharesGear() end,
	set = function(gh, on)
		gh.db.profile.shareGear = on and true or false
		if gh.RefreshGearPanel then gh:RefreshGearPanel() end
		if gh.RefreshBoardsTab then gh:RefreshBoardsTab() end
	end,
})

-- /ghub selftest: payload round trip, numbers only, size, the info line.
function GH:GearSelfTest(api)
	api.Count()
	local own = self:OwnGear()
	local data = self:EncodeGear(own)
	if #data > MAX_BYTES then api.Problem("GEAR", "size", ("own gear %d B > %d"):format(#data, MAX_BYTES)) end
	if not data:match("^[0-9a-z.;%-]*$") then api.Problem("GEAR", "numbers", "payload is not numbers only (base 36)") end
	local back = self:DecodeGear(data)
	if not back then api.Problem("GEAR", "decode", "own payload does not read back") end
	local worst = {}
	for slot = SLOT_FIRST, SLOT_LAST do worst[slot] = { id = 9999999, e = 999999, x = -999999 } end
	local w = self:EncodeGear(worst)
	if #w > MAX_BYTES or not self:DecodeGear(w) then api.Problem("GEAR", "worst", ("worst case %d B"):format(#w)) end
	local n, cached = 0, 0
	for _ in pairs(own) do n = n + 1 end
	local gdb = self:GetGuildDB()
	for _, m in pairs(gdb and gdb.members or {}) do if type(m) == "table" and m.gear then cached = cached + 1 end end
	local miss = self:GearMissing(own, select(2, UnitClass("player")))
	local st = self.blobStats
	api.Info(("gear slots=%d bytes=%d worst=%d cached=%d missing=%d secret=%d blob open=%s queue=%d out=%d asked=%d got=%d same=%d no=%d timeouts=%d bad=%d share=%s"):format(
		n, #data, #w, cached, #miss, self.gearStats.secret, self.blobReq and "y" or "n", #self.blobQueue, #self.blobOut,
		st.asked, st.got, st.same, st.no, st.timeouts, st.bad, self:SharesGear() and "y" or "n"))
end
