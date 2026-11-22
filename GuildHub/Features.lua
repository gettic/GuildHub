-- Guild Hub: the feature registry. Every part of the addon registers here once, at load time:
--
-- GH:RegisterFeature{
--   key = "prof", core = false,             -- core features can't be switched off
--   name = "OPT_FEAT_PROF",                 -- Locale key for Settings (switchable features)
--   defaults = { profile = {}, char = {} }, -- merged into the saved-data defaults (Store.lua)
--   enable = fn, disable = fn,              -- called at start-up (if on) and when switched
--   messages = { TYPE = { class = "live"|"normal"|"bulk", min = seconds, keep = true (held in
--                lockdown), latest = true (a newer one replaces a waiting one),
--                gate = fn(GH, data, target) -> ok (re-checked before the real send),
--                onSend = fn(GH, item) (it really left),
--                urgent = fn(data) -> true: skips the pacing wait and replaces a held one (POS 'off') } },
--   bundle = { field = { get = fn() -> value, clean = fn(v) -> v|nil, store = fn(name, v) } },
--   selftest = fn(api),                     -- adds checks to /ghub selftest
--   -- UI hook keys (reserved now, read by the shared UI parts from 0.4.0-beta.3 on):
--   nameMenu, hoverLines, rowBadges, minimapMenu, welcome, slash, search, toasts, shares = { ... }
-- }
--
-- A feature is on unless: the player switched it off (profile.features[key] == false), or an
-- officer switched it off for the guild (FOFF, below). Off = no events, no jobs, its messages are
-- neither sent nor handled. Nothing is deleted. Officer switches can only turn things OFF.
local _, ns = ...
local GH, U = ns.GH, ns.Util

GH.handlers = GH.handlers or {} -- message handlers (Comm.lua); this file adds FOFF and REC
GH.features = {}      -- [key] = feature table
GH.featureOrder = {}  -- keys in registration order
GH.msgTypes = {}      -- [TYPE] = { owner = key, class, min, keep, latest }

GH.HOOK_KEYS = { "nameMenu", "hoverLines", "rowBadges", "minimapMenu", "welcome", "slash", "search", "toasts", "shares",
	"myStatus", "news" } -- 1.0.0-beta.1: My status ticks {key, text, get, set, why}; news lines {order, fn(GH) -> text, onClick}

local CLASSES = { live = true, normal = true, bulk = true }

function GH:RegisterFeature(f)
	assert(type(f) == "table" and type(f.key) == "string", "RegisterFeature: needs a key")
	assert(not self.features[f.key], "RegisterFeature: key used twice: " .. f.key)
	for _, k in ipairs(self.HOOK_KEYS) do
		if f[k] ~= nil and type(f[k]) ~= "table" then error("RegisterFeature: " .. k .. " must be a table") end
	end
	self.features[f.key] = f
	self.featureOrder[#self.featureOrder + 1] = f.key
	for mtype, m in pairs(f.messages or {}) do
		assert(not self.msgTypes[mtype], "message type used twice: " .. mtype)
		self.msgTypes[mtype] = {
			owner = f.key, class = CLASSES[m.class] and m.class or "normal",
			min = m.min or 5, keep = m.keep and true or false, latest = m.latest and true or false,
			-- 0.4.0-b2: gate(GH, data, target) -> may it leave now? (checked when asked, again before the
			-- real send); onSend(GH, item) is told when it really leaves (POS: privacy counters)
			gate = type(m.gate) == "function" and m.gate or nil,
			onSend = type(m.onSend) == "function" and m.onSend or nil,
			urgent = type(m.urgent) == "function" and m.urgent or nil,
			-- R2: officer = true → sent on the OFFICER channel and accepted only from it (Comm.lua)
			officer = m.officer == true or nil,
		}
	end
	if self.started then self:ApplyFeatures() end -- registered late (tests): start it like the others
	return f
end

-- Defaults of every feature merged into the base defaults (Store.lua, before AceDB starts).
function GH:MergeFeatureDefaults(defaults)
	local function merge(dst, src)
		for k, v in pairs(src) do
			if type(v) == "table" and type(dst[k]) == "table" then merge(dst[k], v)
			elseif dst[k] == nil then dst[k] = v end
		end
	end
	for _, key in ipairs(self.featureOrder) do
		local d = self.features[key].defaults
		if type(d) == "table" then
			for scope, t in pairs(d) do
				defaults[scope] = defaults[scope] or {}
				merge(defaults[scope], t)
			end
		end
	end
	return defaults
end

------------------------------------------------------------------------
-- On / off
------------------------------------------------------------------------
-- The guild-wide switch, if it is still valid: set by someone who is an officer in OUR guild list now.
-- Returns the off table (or nil) and who set it.
function GH:GuildOff()
	local gdb = self.db and self:GetGuildDB()
	local fo = gdb and gdb.featOff
	if type(fo) ~= "table" or type(fo.off) ~= "table" or not fo.by then return nil end
	if self.rosterReady and not self:IsOfficer(fo.by) then return nil, fo.by, true end -- no longer an officer
	return fo.off, fo.by
end

function GH:FeatureOn(key)
	local f = self.features[key]
	if not f then return false end
	if f.core then return true end
	local p = self.db and self.db.profile
	if p and type(p.features) == "table" and p.features[key] == false then return false end
	local off = self:GuildOff()
	if off and off[key] then return false end
	return true
end

-- Message type allowed right now? (unknown types: yes, Comm decides)
function GH:TypeOn(mtype)
	local t = self.msgTypes[mtype]
	return not t or self:FeatureOn(t.owner)
end

local function Call(f, name)
	local fn = f[name]
	if type(fn) ~= "function" then return end
	local ok, err = xpcall(function() fn(GH, f) end, function(e)
		local h = geterrorhandler and geterrorhandler()
		if h then h(e) end
		return e
	end)
	return ok, err
end

-- Start-up: every feature that is on. Each runs once until it is switched off.
function GH:EnableFeatures()
	self.featureRunning = self.featureRunning or {}
	for _, key in ipairs(self.featureOrder) do
		local f = self.features[key]
		if self:FeatureOn(key) and not self.featureRunning[key] then
			self.featureRunning[key] = true
			Call(f, "enable")
		end
	end
end

-- After a switch changed (own setting, officer message, guild list): start or stop features.
function GH:ApplyFeatures()
	if not self.started then return end
	self.featureRunning = self.featureRunning or {}
	local changed = false
	for _, key in ipairs(self.featureOrder) do
		local f = self.features[key]
		local on = self:FeatureOn(key)
		if on and not self.featureRunning[key] then
			self.featureRunning[key] = true
			changed = true
			Call(f, "enable")
		elseif not on and self.featureRunning[key] then
			self.featureRunning[key] = nil
			changed = true
			self:Off(key)
			self:Cancel(key)
			Call(f, "disable")
		end
	end
	if changed and self.OnFeaturesChanged then self:OnFeaturesChanged() end
	return changed
end

-- Settings: own switch.
function GH:SetFeature(key, on)
	local f = self.features[key]
	if not f or f.core then return end
	if on then self.db.profile.features[key] = nil else self.db.profile.features[key] = false end
	self:ApplyFeatures()
end

-- All entries of one UI hook kind from features that are on, in registration order.
function GH:Hooks(kind)
	local r = {}
	for _, key in ipairs(self.featureOrder) do
		local list = self.features[key][kind]
		if type(list) == "table" and self:FeatureOn(key) then
			for _, e in ipairs(list) do r[#r + 1] = e end
		end
	end
	return r
end

------------------------------------------------------------------------
-- Fair trade (the user's rule, 2026-11-18: "if you don't share something you then can't use it at
-- all, so a fair trade: share and then you can use it too"). Each sharing item says what it
-- unlocks; whoever doesn't share it can't use the matching feature. Trial and Veteran accounts
-- can't send addon messages, so they count as sharing nothing. The status board stays open to all.
--   GH:RegisterShare{ key = "prof", order = 3, optKey = "shareProf" (Settings key), name, desc
--     (Locale keys), feature = "prof" (the feature it belongs to), get = fn(GH) -> bool, set = fn(GH, on) }
------------------------------------------------------------------------
GH.shareItems, GH.shareOrder = {}, {}

function GH:RegisterShare(s)
	assert(type(s) == "table" and type(s.key) == "string" and type(s.get) == "function" and type(s.set) == "function",
		"RegisterShare: needs key, get, set")
	assert(not self.shareItems[s.key], "share item used twice: " .. s.key)
	self.shareItems[s.key] = s
	local list = self.shareOrder
	list[#list + 1] = s.key
	table.sort(list, function(a, b) return (self.shareItems[a].order or 99) < (self.shareItems[b].order or 99) end)
	return s
end

-- The player's own setting for this item (true = shares it).
function GH:Shares(key)
	local s = self.shareItems[key]
	if not s then return false end
	local ok, v = pcall(s.get, self)
	return ok and v and true or false
end

-- May the player use what this item unlocks? Returns ok, why ("trial" / "feature" / "off").
function GH:CanUse(key)
	local s = self.shareItems[key]
	if not s then return true end
	if self.cannotSend then return false, "trial" end
	if s.feature and not self:FeatureOn(s.feature) then return false, "feature" end
	if not self:Shares(key) then return false, "off" end
	return true
end

-- The locked note: trial accounts get their own reason, everybody else the item's note.
function GH:LockedText(key, offText)
	local _, why = self:CanUse(key)
	if why == "trial" then return ns.L.FAIR_TRIAL end
	return offText
end

-- Turns an item on or off (Settings, the "Share" button on a locked note).
function GH:SetShare(key, on)
	local s = self.shareItems[key]
	if not s then return end
	s.set(self, on and true or false)
	self:OnShareChanged(key)
end

-- Everything that shows unlocked parts is drawn again.
function GH:OnShareChanged()
	if self.RefreshBoard then self:RefreshBoard() end
	if self.RefreshProfTab then self:RefreshProfTab() end
	if self.MapRedraw then self:MapRedraw() end
	if self.optionsChanged then self:optionsChanged() end
	if self.RefreshGuide then self:RefreshGuide() end
end

------------------------------------------------------------------------
-- FOFF: officers switch features off for the whole guild. Only OFF: a switch never turns
-- sharing on for anybody. Checked on receive AND every time it is used (GuildOff above), so a
-- demoted officer's switch stops counting and any current officer can replace it.
------------------------------------------------------------------------
function GH:SwitchableKeys()
	local r = {}
	for _, key in ipairs(self.featureOrder) do
		if not self.features[key].core then r[#r + 1] = key end
	end
	return r
end

-- Officer: turn a feature off (on = false) or allow it again (on = true) for the whole guild.
function GH:SetGuildFeature(key, on)
	local me = self:MyName()
	local gdb = self:GetGuildDB()
	local f = self.features[key]
	if not gdb or not f or f.core or not self:IsOfficer(me) then return false end
	local current = self:GuildOff() or {}
	local off = {}
	for k, v in pairs(current) do if v == true and self.features[k] and not self.features[k].core then off[k] = true end end
	off[key] = (not on) or nil
	gdb.featOff = { off = off, ts = math.max(U.Now(), (gdb.featOff.ts or 0) + 1), by = me }
	self:SendMsg("FOFF", gdb.featOff)
	self:ApplyFeatures()
	return true
end

-- Cleans a received or synced switch. Returns the clean table or nil.
function GH:CleanFeatOff(data, sender)
	if type(data) ~= "table" then return nil end
	local by = U.ValidName(data.by)
	local ts = U.ValidTime(data.ts)
	if not by or not ts or type(data.off) ~= "table" then return nil end
	if sender and sender ~= by then return nil end -- nobody sends a switch in someone else's name
	if not self:IsOfficer(by) then return nil end    -- officer now, in OUR guild list
	local off, n = {}, 0
	for k, v in pairs(data.off) do
		n = n + 1
		if n > 20 then break end
		local f = type(k) == "string" and self.features[k]
		if f and not f.core and v == true then off[k] = true end -- only OFF, only known, never core
	end
	return { off = off, ts = ts, by = by }
end

function GH:MergeFeatOff(data, sender)
	local gdb = self:GetGuildDB()
	if not gdb then return false end
	local clean = self:CleanFeatOff(data, sender)
	if not clean then
		self:Debug("ignored a feature switch (not an officer or bad data)")
		return false
	end
	if clean.ts <= (gdb.featOff.ts or 0) then return false end
	gdb.featOff = clean
	self:Debug("guild feature switch from %s", U.ShortName(clean.by))
	self:ApplyFeatures()
	return true
end

-- Someone logged in (HELLO, Sync.lua): if WE set the guild switch and it may be news to them, send
-- it again (FOFF is paced: at most every 10 s). Synced copies from others are not trusted, so the
-- officer who set it is the one who spreads it.
function GH:ResendOwnFeatOff(since)
	local gdb = self:GetGuildDB()
	local fo = gdb and gdb.featOff
	if not fo or fo.by ~= self:MyName() or (fo.ts or 0) <= (since or 0) then return end
	if not self:IsOfficer(fo.by) then return end
	self:SendMsg("FOFF", fo)
end

GH.handlers.FOFF = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	self:MergeFeatOff(data, sender)
end

------------------------------------------------------------------------
-- The bundle record: small per-player fields of later features, sent together.
-- HB carries the whole bundle only if HB still fits in one piece, else just its hash; REC carries
-- only the fields that changed (+ the hash); SYNC records carry each member's whole bundle.
-- No fields are registered in this version (the carrier is tested with a test-only field).
------------------------------------------------------------------------
GH.BUNDLE_MAX = 200 -- characters, serialized
GH.bundleDirty = {}

local function BundleFields()
	local r = {}
	for _, key in ipairs(GH.featureOrder) do
		local f = GH.features[key]
		if type(f.bundle) == "table" and GH:FeatureOn(key) then
			for field, def in pairs(f.bundle) do r[field] = def end
		end
	end
	return r
end
GH.BundleFields = BundleFields

-- Our own whole bundle (nil if empty). 1.0.1: if it is too big, the fields with the lowest `prio`
-- are left out one by one until it fits (fields without prio are kept longest), instead of sending
-- nothing at all. GH.bundleDropped = the fields left out last time (self-test).
function GH:OwnBundle()
	local b, any = {}, false
	local defs = BundleFields()
	for field, def in pairs(defs) do
		local ok, v = pcall(def.get)
		if ok and v ~= nil then b[field] = v; any = true end
	end
	self.bundleDropped = nil
	if not any then return nil end
	if #self:Serialize(b) <= self.BUNDLE_MAX then return b end
	local order = {}
	for field in pairs(b) do order[#order + 1] = field end
	table.sort(order, function(x, y)
		local px, py = tonumber(defs[x].prio) or 99, tonumber(defs[y].prio) or 99
		if px ~= py then return px < py end
		return x < y
	end)
	local dropped = {}
	for _, field in ipairs(order) do
		b[field] = nil
		dropped[#dropped + 1] = field
		if next(b) == nil then self.bundleDropped = dropped; return nil end
		if #self:Serialize(b) <= self.BUNDLE_MAX then break end
	end
	self.bundleDropped = dropped
	return b
end

function GH:BundleHash(b)
	if type(b) ~= "table" then return nil end
	return U.Checksum(self:Serialize(b))
end

-- A feature tells us one of its fields changed: REC with the changed fields (at most every 30 s).
function GH:BundleChanged(field)
	if not BundleFields()[field] then return end
	self.bundleDirty[field] = true
	local own = self:OwnBundle() or {}
	if self.bundleWholePending and next(own) then
		-- a whole REC is still waiting: this one replaces it (latest), so it must be whole too
		self:SendMsg("REC", { f = own, h = self:BundleHash(own), w = 1 })
		return
	end
	local f = {}
	for k in pairs(self.bundleDirty) do
		-- false = "drop this field" (`own[k] == nil and false or own[k]` would give nil and send nothing)
		if own[k] == nil then f[k] = false else f[k] = own[k] end
	end
	self:SendMsg("REC", { f = f, h = self:BundleHash(own) })
end

-- Comm.lua: REC really went out.
function GH:OnRecSent()
	self.bundleDirty = {}
	self.bundleWholePending = nil
end

-- 1.0.1: HELLO / HB had no room for the whole bundle and carried only its hash (bh), which nobody can
-- use. Then the whole bundle follows as one REC with w = 1 ("replace, don't merge"): after our HELLO,
-- and after an HB whose hash changed since the last whole one. REC is paced (30 s, latest wins), so
-- this adds at most one REC. Older clients read w = 1 as a normal REC (they merge the fields).
function GH:AfterSelfInfo(info, hello)
	if type(info) ~= "table" then return end
	self.bundleHashOnly = info.bh ~= nil -- remembered for BundleOnHello
	if not info.bh then return end
	if not hello and info.bh == self.bundleWholeHash then return end
	local own = self:OwnBundle()
	if not own then return end
	self.bundleWholeHash = info.bh
	self.bundleWholePending = true
	self:SendMsg("REC", { f = own, h = info.bh, w = 1 })
end

-- Someone else logged in (HELLO, Sync.lua). Nobody's SYNC carries the bundles of online members (1.0.1),
-- and ours never carries our own. So we send our whole REC when our HB has room only for the hash, or
-- when they are in our group (a raider who relogs gets the raid's info at once; others get it with our
-- next HB). Paced like every REC (30 s, latest wins): at most one REC per 30 s.
function GH:BundleOnHello(sender)
	local inGroup = sender and self.MapInMyGroup and self:MapInMyGroup(sender)
	if not self.bundleHashOnly and not inGroup then return end
	local own = self:OwnBundle()
	if not own then return end
	local h = self:BundleHash(own)
	self.bundleWholeHash = h
	self.bundleWholePending = true
	self:SendMsg("REC", { f = own, h = h, w = 1 })
end

-- Received fields: unknown ones ignored, each cleaned, size capped. Stored in members[name].b.
-- relayed = a copy from someone else's SYNC (the owner's own REC / HB / HELLO is "direct").
-- 1.0.1: direct data may create the member entry (the REC that answers our HELLO can arrive before
-- the SYNC that creates it), and a relayed copy never replaces what the owner sent us this session
-- (it may be older; session memory only, nothing saved).
GH.bundleDirect = {}
function GH:ReadBundle(name, fields, whole, relayed)
	if type(fields) ~= "table" then return end
	if relayed and self.bundleDirect[name] then return end
	local gdb = self:GetGuildDB()
	local m = gdb and gdb.members[name]
	if not m and not relayed and gdb and self:IsGuildMember(name) and name ~= self:MyName() then
		m = { ts = 0, lastSeen = U.Now() } -- the same shape MergeStatus makes; SYNC fills in the rest
		gdb.members[name] = m
	end
	if not m then return end
	local ok, ser = pcall(self.Serialize, self, fields)
	if not ok or #ser > self.BUNDLE_MAX then return end
	if not relayed then self.bundleDirect[name] = true end
	local defs = BundleFields()
	local b = whole and {} or (type(m.b) == "table" and m.b or {})
	for field, v in pairs(fields) do
		local def = type(field) == "string" and defs[field]
		if def then
			local clean -- false = the owner cleared the field (X7 scan: "x and nil or y" never gives nil)
			if v ~= false and def.clean then clean = def.clean(v) end
			b[field] = clean
			if def.store then pcall(def.store, name, clean) end
		end
	end
	m.b = next(b) and b or nil
end

GH.handlers.REC = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	if type(data) ~= "table" then return end
	self:ReadBundle(sender, data.f, data.w == 1)
end
