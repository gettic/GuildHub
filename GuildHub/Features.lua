-- Guild Hub: the feature registry. Every part of the addon registers here once, at load time:
--
-- GH:RegisterFeature{
--   key = "prof", core = false,             -- core features can't be switched off
--   name = "OPT_FEAT_PROF",                 -- Locale key for Settings (switchable features)
--   defaults = { profile = {}, char = {} }, -- merged into the saved-data defaults (Store.lua)
--   enable = fn, disable = fn,              -- called at start-up (if on) and when switched
--   messages = { TYPE = { class = "live"|"normal"|"bulk", min = seconds, keep = true (held in
--                lockdown), latest = true (a newer one replaces a waiting one) } },
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

GH.HOOK_KEYS = { "nameMenu", "hoverLines", "rowBadges", "minimapMenu", "welcome", "slash", "search", "toasts", "shares" }

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

-- Our own whole bundle (nil if empty).
function GH:OwnBundle()
	local b, any = {}, false
	for field, def in pairs(BundleFields()) do
		local ok, v = pcall(def.get)
		if ok and v ~= nil then b[field] = v; any = true end
	end
	if not any then return nil end
	if #self:Serialize(b) > self.BUNDLE_MAX then return nil end
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
	local f = {}
	for k in pairs(self.bundleDirty) do f[k] = own[k] == nil and false or own[k] end
	self:SendMsg("REC", { f = f, h = self:BundleHash(own) })
end

-- Comm.lua: REC really went out.
function GH:OnRecSent()
	self.bundleDirty = {}
end

-- Received fields: unknown ones ignored, each cleaned, size capped. Stored in members[name].b.
function GH:ReadBundle(name, fields, whole)
	if type(fields) ~= "table" then return end
	local gdb = self:GetGuildDB()
	local m = gdb and gdb.members[name]
	if not m then return end
	local ok, ser = pcall(self.Serialize, self, fields)
	if not ok or #ser > self.BUNDLE_MAX then return end
	local defs = BundleFields()
	local b = whole and {} or (type(m.b) == "table" and m.b or {})
	for field, v in pairs(fields) do
		local def = type(field) == "string" and defs[field]
		if def then
			local clean = (v == false) and nil or (def.clean and def.clean(v))
			b[field] = clean
			if def.store then pcall(def.store, name, clean) end
		end
	end
	m.b = next(b) and b or nil
end

GH.handlers.REC = function(self, sender, data, distribution, isSelf)
	if isSelf or distribution ~= "GUILD" then return end
	self:ReadBundle(sender, data.f, false)
end
