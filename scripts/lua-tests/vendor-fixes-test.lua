local passed, failures = 0, 0

unpack = unpack or table.unpack
strfind = string.find
strmatch = string.match
strlower = string.lower
strsplit = function(sep, value)
	local result = {}
	local pattern = "([^"..sep.."]*)"..sep.."?"
	for part in string.gmatch(value..sep, pattern) do
		table.insert(result, part)
	end
	return unpack(result)
end
gsub = string.gsub
format = string.format
tinsert = table.insert
tremove = table.remove
min = math.min
max = math.max
floor = math.floor
wipe = function(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
	return tbl
end

local function test(name, func)
	local ok, err = pcall(func)
	if ok then
		passed = passed + 1
		print("PASS: "..name)
	else
		failures = failures + 1
		print("FAIL: "..name.." -> "..tostring(err))
	end
end

local function loadSource(source, name, addonTable, exposePrivate)
	if exposePrivate then
		source = source.."\nREMAINING_FIX_PRIVATE = private\n"
	end
	local chunk, err = load(source, name)
	assert(chunk, err)
	REMAINING_FIX_PRIVATE = nil
	chunk(nil, addonTable)
	return REMAINING_FIX_PRIVATE
end

local function newPublisher()
	local publisher = {}
	function publisher:MapToValue()
		return self
	end
	function publisher:CallFunction(callback)
		self.callback = callback
		return self
	end
	function publisher:Stored()
		return self
	end
	return publisher
end

local function newEnumType()
	local enumType = {}
	local placeholder = {}
	local parents = setmetatable({}, { __mode = "k" })
	local function isAncestor(value, possibleAncestor)
		local current = value
		while parents[current] do
			current = parents[current]
			if rawequal(current, possibleAncestor) then
				return true
			end
		end
		return false
	end
	local function enumEquals(left, right)
		return rawequal(left, right) or isAncestor(left, right) or isAncestor(right, left)
	end
	local enumMt = { __eq = enumEquals }
	local function convert(tbl, parent)
		setmetatable(tbl, enumMt)
		if parent then
			parents[tbl] = parent
		end
		for key, value in pairs(tbl) do
			if rawequal(value, placeholder) then
				local leaf = setmetatable({}, enumMt)
				parents[leaf] = tbl
				tbl[key] = leaf
			else
				convert(value, tbl)
			end
		end
		return tbl
	end
	function enumType.NewValue()
		return placeholder
	end
	function enumType.NewNested(_, values)
		return convert(values)
	end
	return enumType
end


-- ============================================================================
-- Vendor item info refresh
-- ============================================================================

local function loadVendorContext()
	local queryPublisher = newPublisher()
	local itemInfoPublisher = newPublisher()
	local timers = {}
	local timerNow = 0
	local itemInfo = {
		GetPublisher = function() return itemInfoPublisher end,
		GetTexture = function() return nil end,
	}
	local delayTimer = {}
	function delayTimer.New(_, callback)
		local timer = { pending = false, deadline = nil }
		function timer:RunForFrames(frames)
			if self.pending then
				return
			end
			self.pending = true
			self.deadline = timerNow + frames / 60
		end
		function timer:RunForTime(seconds)
			if self.pending then
				return
			end
			self.pending = true
			self.deadline = timerNow + seconds
		end
		function timer:Cancel()
			self.pending = false
			self.deadline = nil
		end
		function timer:Fire()
			if not self.pending then
				return
			end
			self.pending = false
			self.deadline = nil
			callback()
		end
		function timer:Advance(now)
			if self.pending and self.deadline <= now then
				self:Fire()
			end
		end
		table.insert(timers, timer)
		return timer
	end
	local function advanceTimers(seconds)
		timerNow = timerNow + seconds
		for _, timer in ipairs(timers) do
			timer:Advance(timerNow)
		end
	end
	local vendorLookupCount = 0
	local vendor = {
		GetFirstIndex = function(itemString)
			vendorLookupCount = vendorLookupCount + 1
			return itemString == "i:100" and 1 or nil
		end,
	}
	local class
	local uiElements = {}
	function uiElements.Define()
		class = { __private = {}, __protected = {} }
		return class
	end
	local serviceModules = {
		["Item.ItemInfo"] = itemInfo,
		["UI.Theme"] = {
			GetItemIconLink = function(texture) return tostring(texture) end,
			GetColor = function() return { ColorText = function(_, value) return value end } end,
		},
		["Vendor"] = vendor,
	}
	local directModules = {
		["Vendor.VendorUIUtils"] = { GetAltCostText = function() return "" end },
		["Util.UIElements"] = uiElements,
		["Util.UIUtils"] = { GetDisplayItemName = function() return nil end },
	}
	local serviceProxy = {}
	function serviceProxy:Include(name)
		return assert(serviceModules[name], name)
	end
	local wowProxy = {}
	function wowProxy:IncludeClassType(name)
		assert(name == "DelayTimer")
		return delayTimer
	end
	local lib = {
		Locale = { GetTable = function() return setmetatable({}, { __index = function(_, key) return key end }) end },
	}
	function lib:Include(name)
		return assert(directModules[name], name)
	end
	function lib:From(name)
		if name == "LibTSMService" then
			return serviceProxy
		elseif name == "LibTSMWoW" then
			return wowProxy
		end
		error(name)
	end
	loadSource(REMAINING_VENDOR_SRC, "VendorBuyScrollTable.lua", { LibTSMUI = lib }, false)
	return class, queryPublisher, itemInfoPublisher, timers, advanceTimers, function() return vendorLookupCount end
end

local function newVendorInstance(class, queryPublisher)
	local query = { releaseCount = 0 }
	function query:ResetFilters() return self end
	function query:NotEqual() return self end
	function query:ResetOrderBy() return self end
	function query:OrderBy() return self end
	function query:Publisher() return queryPublisher end
	function query:Release() self.releaseCount = self.releaseCount + 1 end
	local instance = {
		__super = {
			__init = function() end,
			Release = function() end,
		},
		_settings = { vendor = { sortCol = "item", sortAscending = true } },
		_settingsKey = "vendor",
		cancellables = {},
		draws = 0,
	}
	function instance:__closure(name)
		return function(...)
			return assert(class.__private[name], name)(self, ...)
		end
	end
	class.__init(instance)
	-- A real initial query update populates the visible vendor membership cache.
	-- The test's draw method is intentionally replaced, so seed that postcondition.
	instance._itemStringSet = instance._itemStringSet or {}
	instance._itemStringSet["i:100"] = true
	function instance:_DrawSortFlag() end
	function instance:AddCancellable(value)
		table.insert(self.cancellables, value)
	end
	function instance:_HandleQueryUpdate()
		self.draws = self.draws + 1
	end
	class.SetQuery(instance, query)
	return instance, query
end

test("vendor item info refresh runs after the current publisher dispatch", function()
	local class, queryPublisher, itemInfoPublisher, timers = loadVendorContext()
	local instance = newVendorInstance(class, queryPublisher)
	assert(type(itemInfoPublisher.callback) == "function", "vendor table did not subscribe to ItemInfo updates")
	itemInfoPublisher.callback("i:200")
	assert(instance.draws == 0, "unrelated item update redrew the vendor table")
	local dispatching = true
	function instance:_HandleQueryUpdate()
		assert(not dispatching, "vendor redraw re-entered ItemInfo publisher dispatch")
		self.draws = self.draws + 1
	end
	local ok, err = pcall(itemInfoPublisher.callback, "i:100")
	dispatching = false
	assert(ok, err)
	assert(instance.draws == 0, "current vendor item redrew synchronously")
	assert(#timers == 1, "vendor refresh timer was not created")
	timers[1]:Fire()
	assert(instance.draws == 1, "deferred vendor redraw did not run")
end)

test("vendor release cancels a pending item info refresh", function()
	local class, queryPublisher, itemInfoPublisher, timers = loadVendorContext()
	local instance, query = newVendorInstance(class, queryPublisher)
	itemInfoPublisher.callback("i:100")
	class.Release(instance)
	assert(query.releaseCount == 1, "vendor query was not released exactly once")
	assert(#timers == 1, "vendor refresh timer was not created")
	timers[1]:Fire()
	assert(instance.draws == 0, "released vendor table was redrawn by a pending timer")
end)

test("vendor item info bursts are batched beyond a single frame", function()
	local class, queryPublisher, itemInfoPublisher, _, advanceTimers = loadVendorContext()
	local instance = newVendorInstance(class, queryPublisher)
	itemInfoPublisher.callback("i:100")
	advanceTimers(0.02)
	assert(instance.draws == 0, "vendor table redrew after a single frame")
	itemInfoPublisher.callback("i:100")
	advanceTimers(0.1)
	itemInfoPublisher.callback("i:100")
	advanceTimers(0.1)
	assert(instance.draws == 0, "multi-frame item info burst caused repeated redraws")
	advanceTimers(0.1)
	assert(instance.draws == 1, "batched vendor redraw did not run")
end)

test("global item info backlog performs no vendor DB lookup for unrelated items", function()
	local class, queryPublisher, itemInfoPublisher, _, _, getVendorLookupCount = loadVendorContext()
	newVendorInstance(class, queryPublisher)
	for i = 1, 4000 do
		itemInfoPublisher.callback("i:"..(1000 + i))
	end
	assert(getVendorLookupCount() == 0, "unrelated global updates caused "..getVendorLookupCount().." vendor DB queries")
end)

test("Merchant adapter preserves the synchronous native item name", function()
	local merchant = {}
	local clientInfo = { FEATURES = { C_MERCHANTFRAME = 1 } }
	function clientInfo.HasFeature() return false end
	local lib = {}
	function lib:Init(name)
		assert(name == "API.Merchant")
		return merchant
	end
	function lib:Include(name)
		assert(name == "Util.ClientInfo")
		return clientInfo
	end
	GetMerchantItemInfo = function(index)
		assert(index == 1)
		return "Instant Vendor Name", "InstantTexture", 125, 5, -1
	end
	loadSource(REMAINING_MERCHANT_SRC, "Merchant.lua", { LibTSMWoW = lib }, false)
	local price, stackSize, numAvailable, name, texture = merchant.GetItemInfo(1)
	assert(price == 125 and stackSize == 5 and numAvailable == -1, "existing Merchant values changed")
	assert(name == "Instant Vendor Name", "native merchant name was discarded")
	assert(texture == "InstantTexture", "native merchant texture was discarded")
end)

test("BuyScanner carries the native merchant name into its database row", function()
	local scanner = {}
	local onModuleLoad = nil
	function scanner:OnModuleLoad(func) onModuleLoad = func end
	local insertedRow = nil
	local fields = {}
	local db = {}
	function db:TruncateAndBulkInsertStart() end
	function db:BulkInsertNewRow(...)
		insertedRow = {}
		for index, field in ipairs(fields) do
			insertedRow[field] = select(index, ...)
		end
	end
	function db:BulkInsertEnd() end
	function db:NewQuery() error("query not expected in scanner population test") end
	local schema = {}
	local function addField(_, name) tinsert(fields, name) return schema end
	function schema:AddUniqueNumberField(name) return addField(self, name) end
	function schema:AddStringField(name) return addField(self, name) end
	function schema:AddSmartMapField(name) return addField(self, name) end
	function schema:AddNumberField(name) return addField(self, name) end
	function schema:AddStringListField(name) return addField(self, name) end
	function schema:AddNumberListField(name) return addField(self, name) end
	function schema:Commit() return db end
	local database = { NewSchema = function(name) assert(name == "VENDOR_ITEMS") return schema end }
	local itemString = {
		Get = function(value) return value end,
		GetBaseMap = function() return {} end,
	}
	local merchant = {
		GetNumItems = function() return 1 end,
		GetItemLink = function() return "i:100" end,
		GetItemInfo = function() return 125, 5, -1, "Instant Vendor Name", "InstantTexture" end,
		GetNumCostItems = function() return 0 end,
	}
	local delayTimer = { New = function() return { RunForFrames = function() end, RunForTime = function() end, Cancel = function() end } end }
	local defaultUI = { RegisterMerchantVisibleCallback = function() end }
	local event = { Register = function() end }
	local utilProxy = { Include = function(_, name)
		local modules = {
			["Lua.Vararg"] = {},
			["BaseType.TempTable"] = {},
			["Database"] = database,
			["Util.Log"] = { Err = function() end },
		}
		return assert(modules[name], name)
	end }
	local typesProxy = { Include = function(_, name) assert(name == "Item.ItemString") return itemString end }
	local wowProxy = {}
	function wowProxy:Include(name)
		local modules = {
			["API.Container"] = {}, ["API.Currency"] = {}, ["API.Merchant"] = merchant,
			["Service.Event"] = event, ["UI.DefaultUI"] = defaultUI,
		}
		return assert(modules[name], name)
	end
	function wowProxy:IncludeClassType(name) assert(name == "DelayTimer") return delayTimer end
	local lib = {}
	function lib:Init(name) assert(name == "Vendor.BuyScanner") return scanner end
	function lib:From(name)
		if name == "LibTSMUtil" then return utilProxy end
		if name == "LibTSMTypes" then return typesProxy end
		if name == "LibTSMWoW" then return wowProxy end
		error(name)
	end
	local private = loadSource(REMAINING_BUY_SCANNER_SRC, "BuyScanner.lua", { LibTSMService = lib }, true)
	assert(onModuleLoad, "BuyScanner module load callback missing")
	onModuleLoad()
	private.UpdateMerchantDB()
	assert(insertedRow, "vendor row was not inserted")
	assert(insertedRow.merchantName == "Instant Vendor Name", "BuyScanner discarded the native merchant name")
end)

test("cold vendor first draw uses the native name while ItemInfo is empty", function()
	local class = select(1, loadVendorContext())
	local fields = {
		stackSize = 1,
		itemString = "i:100",
		numAvailable = -1,
		itemLevel = -1,
		index = 1,
		baseItemString = "i:100",
		merchantName = "Instant Vendor Name",
	}
	local row = {}
	function row:GetFields(...)
		local values = {}
		for i = 1, select("#", ...) do
			values[i] = fields[select(i, ...)]
		end
		return unpack(values, 1, select("#", ...))
	end
	function row:GetField(name) return fields[name] end
	local yielded = false
	local query = {}
	function query:Iterator()
		return function()
			if yielded then return end
			yielded = true
			return 1, row
		end
	end
	local instance = {
		_query = query,
		_itemStringSet = {},
		_data = { qty = {}, item = {}, item_tooltip = {}, ilvl = {}, cost = {}, cost_tooltip = {} },
		_createGroupsData = {},
	}
	function instance:_SetNumRows(value) self.numRows = value end
	function instance:Draw() self.draws = (self.draws or 0) + 1 end
	class.__private._HandleQueryUpdate(instance)
	assert(instance.numRows == 1 and instance.draws == 1, "vendor first draw did not complete")
	assert(strfind(instance._data.item[1], "Instant Vendor Name", 1, true), "cold vendor first draw showed a placeholder: "..tostring(instance._data.item[1]))
end)

test("every ItemInfo give-up implementation clears the server request marker", function()
	local functionStart = 1
	local pendingCount = 0
	while true do
		local blockStart = string.find(REMAINING_ITEMINFO_SRC, "function private.ProcessPendingItemInfo", functionStart, true)
		if not blockStart then break end
		local blockEnd = assert(string.find(REMAINING_ITEMINFO_SRC, "function private.ProcessItemInfo", blockStart, true))
		local block = string.sub(REMAINING_ITEMINFO_SRC, blockStart, blockEnd - 1)
		local giveUpEnd = assert(string.find(block, "elseif name and name", 1, true))
		local giveUpBlock = string.sub(block, 1, giveUpEnd - 1)
		assert(string.find(giveUpBlock, "private.serverRequested[itemString] = nil", 1, true), "definition "..(pendingCount + 1).." leaves a stale serverRequested marker")
		pendingCount = pendingCount + 1
		functionStart = blockEnd
	end
	assert(pendingCount > 0, "ProcessPendingItemInfo definition missing")
end)

test("Classic ItemInfo work budget does not exceed the tooltip request capacity", function()
	local interval = tonumber(string.match(REMAINING_ITEMINFO_SRC, "local CLASSIC_ITEM_INFO_INTERVAL = ([%d%.]+)"))
	local maxPerTick = tonumber(string.match(REMAINING_ITEMINFO_SRC, "local CLASSIC_MAX_REQUESTED_ITEM_INFO = ([%d%.]+)"))
	local serverCapacity = tonumber(string.match(REMAINING_ITEM_API_SRC, "local MAX_CACHE_REQUESTS_PER_SEC = ([%d%.]+)"))
	assert(interval, "Classic ItemInfo interval is not explicit")
	assert(maxPerTick, "Classic ItemInfo tick budget is not explicit")
	assert(serverCapacity, "tooltip request capacity is missing")
	assert(maxPerTick / interval <= serverCapacity, format("ItemInfo attempts/s %.1f exceed tooltip capacity/s %.1f", maxPerTick / interval, serverCapacity))
end)


-- ============================================================================
-- Item tooltip hyperlink safety
-- ============================================================================

local function loadTooltipContext()
	local tooltip = {}
	local names = { ["i:200"] = "Resolved Item" }
	local itemInfo = { linkInputs = {} }
	function itemInfo.GetName(item)
		return names[item]
	end
	function itemInfo.GetLink(item)
		table.insert(itemInfo.linkInputs, item)
		if item == "i:200" then
			return "|cff00ff00|Hitem:200:0:0:0:0:0:0:0|h[Resolved Item]|h|r"
		elseif item == "i:100" then
			return "unknown-link"
		else
			return "rewritten-link"
		end
	end
	local includes = {
		["Lua.String"] = { SplitIterator = function() return function() return nil end end },
		["Crafting.CraftString"] = {},
		["Item.ItemString"] = {
			IsItem = function(value) return type(value) == "string" and strfind(value, "^i:") ~= nil end,
			IsPet = function() return false end,
		},
		["Crafting.RecipeString"] = {},
		["Util.ClientInfo"] = {
			FEATURES = { C_TRADE_SKILL_UI = 1, BATTLE_PETS = 2 },
			IsPandaClassic = function() return false end,
			IsBCClassic = function() return false end,
			IsWrathClassic = function() return true end,
			IsRetail = function() return false end,
			HasFeature = function() return false end,
		},
		["Service.Event"] = {
			Register = function() end,
			Unregister = function() end,
		},
		["API.TradeSkill"] = {},
		["Item.ItemInfo"] = itemInfo,
		["Profession"] = {},
	}
	local proxy = {}
	function proxy:Include(name) return assert(includes[name], name) end
	local lib = {}
	function lib:Init(name)
		assert(name == "Tooltip")
		return tooltip
	end
	function lib:From() return proxy end
	loadSource(REMAINING_TOOLTIP_SRC, "Tooltip.lua", { LibTSMUI = lib }, false)
	return tooltip, itemInfo
end

local tooltipCalls = { links = {}, shown = 0 }
GameTooltip = {}
function GameTooltip:SetOwner() end
function GameTooltip:ClearAllPoints() end
function GameTooltip:SetPoint() end
function GameTooltip:SetHyperlink(link)
	table.insert(tooltipCalls.links, link)
end
function GameTooltip:Show() tooltipCalls.shown = tooltipCalls.shown + 1 end
function GameTooltip:Hide() end
function GameTooltip:IsVisible() return false end
function GameTooltip:AddLine() end
function GameTooltip:AddDoubleLine() end
UIParent = {}
IsShiftKeyDown = function() return false end

test("unresolved vendor item never reaches SetHyperlink", function()
	tooltipCalls.links = {}
	tooltipCalls.shown = 0
	local tooltip, itemInfo = loadTooltipContext()
	tooltip.Show({}, "i:100")
	assert(#tooltipCalls.links == 0, "unresolved item was passed to SetHyperlink")
	assert(#itemInfo.linkInputs == 0, "synthetic unknown link was built for unresolved item")
	assert(tooltipCalls.shown == 0, "empty unresolved tooltip was shown")
end)

test("full item hyperlink is preserved and resolved itemString is converted", function()
	tooltipCalls.links = {}
	local tooltip, itemInfo = loadTooltipContext()
	local fullLink = "|cffffffff|Hitem:100:0:0:0:0:0:0:0|h[Full Link]|h|r"
	tooltip.Show({}, fullLink)
	assert(tooltipCalls.links[1] == fullLink, "full hyperlink was rewritten")
	assert(#itemInfo.linkInputs == 0, "ItemInfo.GetLink was called for a complete hyperlink")
	tooltip.Hide()
	tooltip.Show({}, "i:200")
	assert(tooltipCalls.links[2] == "|cff00ff00|Hitem:200:0:0:0:0:0:0:0|h[Resolved Item]|h|r")
	assert(itemInfo.linkInputs[1] == "i:200")
end)



print(format("Vendor fix behavior tests: %d passed, %d failed", passed, failures))
return failures
