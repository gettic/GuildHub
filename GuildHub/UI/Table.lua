-- Guild Hub: a sortable table (1.0.1, plans\next-batch-1.0.x X1; the Boards tab's pages use it).
--   local t = W.Table(parent, { width = 840, rowH = 20, onSort = fn(key, rev), setupRow = fn(r), onEnter, onClick })
--   t:SetColumns({ { key, label, w, align = "LEFT"|"CENTER"|"RIGHT", sort = fn(row) -> value or nil,
--                    fill = fn(cell, row) (cell.fs text, cell.icons[1..2] textures, cell.marks[1..2]) }, ... })
--   t:SetRows(rows)  -- rows are plain tables; { header = text, count = n } rows are group headers
--   t:SetSort(key, rev) / t.sortKey, t.sortRev
-- Header buttons sort (click again = reverse). Rows: Blizzard's ScrollBox list (W.ScrollList), else our
-- own rows with the mouse wheel. Plain display frames only.
local _, ns = ...
local W = ns.Widgets

local MAX_COLS = 10
local HEAD_H = 20

-- Sorts rows by a column's sort value; rows without a value always go last; then by name.
function W.SortRows(rows, col, rev)
	if not col or type(col.sort) ~= "function" then return rows end
	local vals = {}
	for _, r in ipairs(rows) do
		local ok, v = pcall(col.sort, r)
		vals[r] = ok and v or nil
	end
	table.sort(rows, function(a, b)
		local va, vb = vals[a], vals[b]
		if va == nil and vb == nil then return (a.name or "") < (b.name or "") end
		if va == nil then return false end
		if vb == nil then return true end
		if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
		if va == vb then return (a.name or "") < (b.name or "") end
		if rev then return va > vb end
		return va < vb
	end)
	return rows
end

local function MakeCell(r, i)
	local c = { icons = {}, marks = {} }
	c.fs = W.Text(r, "GameFontHighlightSmall")
	c.fs:SetWordWrap(false)
	for k = 1, 2 do
		local tex = r:CreateTexture(nil, "ARTWORK")
		tex:SetSize(14, 14)
		tex:Hide()
		c.icons[k] = tex
		local m = W.Text(r, "GameFontNormalSmall")
		m:Hide()
		c.marks[k] = m
	end
	r.cells[i] = c
	return c
end

local function PlaceCells(t, r)
	local x = 4
	for i = 1, MAX_COLS do
		local col = t.columns[i]
		local c = r.cells[i] or MakeCell(r, i)
		if col then
			c.fs:ClearAllPoints()
			c.fs:SetPoint("LEFT", r, "LEFT", x, 0)
			c.fs:SetWidth(col.w - 6)
			c.fs:SetJustifyH(col.align or "LEFT")
			for k = 1, 2 do
				c.icons[k]:ClearAllPoints()
				c.icons[k]:SetPoint("LEFT", r, "LEFT", x + (k - 1) * 16, 0)
				c.marks[k]:ClearAllPoints()
				c.marks[k]:SetPoint("LEFT", r, "LEFT", x + (k - 1) * 16, 0)
			end
			x = x + col.w
		end
		c.x = x
	end
	r.layout = t.layoutId
end

local function SetupRow(t, r)
	r.ghTableRow = true
	r.cells = {}
	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	r.bg = bg
	r.hl = W.RowHighlight(r)
	r.header = W.Text(r, "GameFontNormal")
	r.header:SetPoint("LEFT", 8, 0)
	r.headerLine = W.HeaderLine(r, r.header)
	if r.RegisterForClicks then r:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
	r:SetScript("OnEnter", function(s)
		if s.data and not s.data.header and t.onEnter and not (InCombatLockdown and InCombatLockdown()) then t.onEnter(s, s.data) end
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnClick", function(s, button)
		if s.data and not s.data.header and t.onClick then t.onClick(s, s.data, button) end
	end)
	if t.setupRow then t.setupRow(r) end
end

local function FillRow(t, r, d)
	if not r.ghTableRow then SetupRow(t, r) end
	if r.layout ~= t.layoutId then PlaceCells(t, r) end
	r.data = d
	local isHeader = d.header ~= nil
	r.header:SetShown(isHeader)
	if r.headerLine then r.headerLine:SetShown(isHeader) end
	r.hl:SetShown(not isHeader)
	for i = 1, MAX_COLS do
		local c = r.cells[i]
		local col = not isHeader and t.columns[i]
		c.fs:SetShown(col and true or false)
		for k = 1, 2 do c.icons[k]:Hide(); c.marks[k]:Hide() end
		if col then
			c.fs:SetText("")
			c.fs:SetTextColor(1, 1, 1)
			if type(col.fill) == "function" then pcall(col.fill, c, d) end
		end
	end
	if isHeader then
		r.header:SetText(d.count and ("%s (%d)"):format(d.header, d.count) or d.header)
		r.bg:SetColorTexture(0, 0, 0, 0)
	else
		r.bg:SetColorTexture(1, 1, 1, d.isSelf and 0.07 or 0.03)
	end
end

function W.Table(parent, spec)
	local t = { columns = {}, rows = {}, layoutId = 0, rowH = spec.rowH or 20, width = spec.width or 600,
		onSort = spec.onSort, setupRow = spec.setupRow, onEnter = spec.onEnter, onClick = spec.onClick }
	local frame = CreateFrame("Frame", nil, parent)
	t.frame = frame
	-- header buttons
	local head = CreateFrame("Frame", nil, frame)
	head:SetPoint("TOPLEFT", 0, 0)
	head:SetPoint("TOPRIGHT", 0, 0)
	head:SetHeight(HEAD_H)
	t.head = head
	t.headButtons = {}
	for i = 1, MAX_COLS do
		local b = CreateFrame("Button", nil, head)
		b:SetHeight(HEAD_H)
		local fs = W.Text(b, "GameFontNormalSmall")
		fs:SetPoint("LEFT", 4, 0)
		fs:SetPoint("RIGHT", -12, 0)
		fs:SetWordWrap(false)
		b.label = fs
		local arrow = W.Text(b, "GameFontNormalSmall")
		arrow:SetPoint("LEFT", fs, "LEFT", 0, 0)
		b.arrow = arrow
		local hl = W.RowHighlight(b)
		hl:SetAlpha(0.5)
		b:SetScript("OnClick", function(s)
			local col = s.col
			if not col or type(col.sort) ~= "function" then return end
			if t.sortKey == col.key then t.sortRev = not t.sortRev else t.sortKey, t.sortRev = col.key, false end
			if t.onSort then t.onSort(t.sortKey, t.sortRev) end
			t:Refresh()
		end)
		b:Hide()
		t.headButtons[i] = b
	end
	local line = W.Divider(frame, t.width)
	line:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, 0)
	-- the rows
	local area = CreateFrame("Frame", nil, frame)
	area:SetPoint("TOPLEFT", 0, -(HEAD_H + 4))
	area:SetPoint("BOTTOMRIGHT", 0, 0)
	t.area = area
	local box, bar = W.ScrollList(area, t.rowH, function(r, d) FillRow(t, r, d) end)
	if box then
		box:SetPoint("TOPLEFT", 0, 0)
		box:SetPoint("BOTTOMLEFT", 0, 0)
		box:SetWidth(t.width)
		bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
		bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
		t.scrollBox, t.scrollBar = box, bar
	else
		t.plainRows, t.offset = {}, 0
		area:EnableMouseWheel(true)
		area:SetScript("OnMouseWheel", function(_, delta)
			local max = math.max(0, #t.rows - #t.plainRows)
			t.offset = math.max(0, math.min(max, t.offset - delta * 3))
			t:DrawPlain()
		end)
	end
	t.empty = W.Text(area, "GameFontDisable")
	t.empty:SetPoint("TOP", 0, -40)
	t.empty:SetWidth(t.width - 40)
	t.empty:Hide()

	function t:SetColumns(cols)
		self.columns = {}
		for i = 1, math.min(#cols, MAX_COLS) do self.columns[i] = cols[i] end
		self.layoutId = self.layoutId + 1
		local x = 0
		for i, b in ipairs(self.headButtons) do
			local col = self.columns[i]
			b.col = col
			b:SetShown(col ~= nil)
			if col then
				b:ClearAllPoints()
				b:SetPoint("LEFT", self.head, "LEFT", x, 0)
				b:SetWidth(col.w)
				b.label:SetText(col.label or "")
				b.label:SetJustifyH(col.align or "LEFT")
				b:EnableMouse(type(col.sort) == "function")
				x = x + col.w
			end
		end
	end

	function t:Column(key)
		for _, c in ipairs(self.columns) do if c.key == key then return c end end
		return nil
	end

	function t:SetSort(key, rev)
		self.sortKey, self.sortRev = key, rev and true or false
	end

	-- rows: plain list (sorted here) or grouped rows with headers (kept as given: sorted = false)
	function t:SetRows(rows, keepOrder, keepPlace)
		self.rawRows = rows
		self.keepOrder = keepOrder
		self:Refresh(keepPlace)
	end

	function t:Refresh(keepPlace)
		local rows = self.rawRows or {}
		if not self.keepOrder then W.SortRows(rows, self:Column(self.sortKey), self.sortRev) end
		self.rows = rows
		for _, b in ipairs(self.headButtons) do
			local on = b.col and b.col.key == self.sortKey and type(b.col.sort) == "function"
			local text = b.col and b.col.label or ""
			b.label:SetText(on and (text .. (self.sortRev and " v" or " ^")) or text)
			local c = on and W.COLOR.highlight or W.COLOR.normal
			b.label:SetTextColor(c[1], c[2], c[3])
		end
		if self.scrollBox then
			W.SetListData(self.scrollBox, rows, keepPlace)
		else
			if not keepPlace then self.offset = 0 end
			self:DrawPlain()
		end
	end

	function t:DrawPlain()
		if not self.plainRows then return end
		local h = self.area:GetHeight()
		local n = math.max(1, math.floor(((type(h) == "number" and h > 0) and h or (spec.height or 300)) / self.rowH))
		for i = #self.plainRows + 1, n do
			local r = CreateFrame("Button", nil, self.area)
			r:SetSize(self.width, self.rowH - 2)
			r:SetPoint("TOPLEFT", 0, -(i - 1) * self.rowH)
			self.plainRows[i] = r
		end
		for i, r in ipairs(self.plainRows) do
			local d = i <= n and self.rows[self.offset + i]
			r:SetShown(d and true or false)
			if d then FillRow(self, r, d) end
		end
	end

	function t:SetEmpty(text)
		self.empty:SetText(text or "")
		self.empty:SetShown(text ~= nil and text ~= "")
	end

	-- self-test / tester: the parts
	function t:Parts()
		return { head = self.head, box = self.scrollBox or self.area, bar = self.scrollBar, empty = self.empty }
	end

	return t
end

-- Shared cell helpers
function W.CellText(c, text, color)
	c.fs:SetText(text or "")
	if color then c.fs:SetTextColor(color[1], color[2], color[3]) end
end

-- Up to two role icons (t/h/d) in a cell.
function W.CellRoles(c, roles)
	if type(roles) ~= "string" or roles == "" then return end
	for k = 1, math.min(2, #roles) do
		W.SetRoleIcon(c.icons[k], c.marks[k], roles:sub(k, k))
	end
end
