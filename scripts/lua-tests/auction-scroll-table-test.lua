local failures = 0

tinsert = table.insert
tremove = table.remove
strmatch = string.match
floor = math.floor
ceil = math.ceil
wipe = function(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
	return tbl
end

local function test(name, func)
	local ok, err = pcall(func)
	if ok then
		print("PASS: "..name)
	else
		failures = failures + 1
		print("FAIL: "..name.." -> "..tostring(err))
	end
end

local auctionScrollTableClass = nil
local uiElements = {}
function uiElements.Define()
	auctionScrollTableClass = {
		__private = {},
		__protected = {},
		_AddActionScripts = function() end,
	}
	return auctionScrollTableClass
end

local tableUtil = {}
function tableUtil.SortWithValueLookup(tbl, valueLookup, reverse, secondarySort)
	table.sort(tbl, function(a, b)
		local aValue = valueLookup[a]
		local bValue = valueLookup[b]
		if aValue == bValue then
			return secondarySort(a, b)
		elseif reverse then
			return aValue > bValue
		else
			return aValue < bValue
		end
	end)
end

local directModules = {
	["AuctionHouse.AuctionHouseUIUtils"] = {},
	["Tooltip"] = {},
	["Util.UIElements"] = uiElements,
	["Util.UIUtils"] = {},
}
local fromModules = {
	LibTSMService = {
		["Item.ItemInfo"] = {},
		["UI.TextureAtlas"] = {},
		["UI.Theme"] = {},
	},
	LibTSMTypes = {
		["Item.ItemString"] = {},
		["CustomString"] = {},
	},
	LibTSMUtil = {
		["BaseType.TempTable"] = {},
		["Lua.Math"] = {},
		["Lua.Table"] = tableUtil,
		["UI.Money"] = {},
	},
}

local lib = {
	Locale = {
		GetTable = function()
			return setmetatable({}, { __index = function(_, key) return key end })
		end,
	},
	IsVanillaClassic = function() return false end,
	IsBCClassic = function() return false end,
	IsWrathClassic = function() return true end,
}
function lib:Include(name)
	return assert(directModules[name], name)
end
function lib:From(name)
	if name == "LibTSMWoW" then
		return { IncludeClassType = function(_, className)
			assert(className == "DelayTimer")
			return {}
		end }
	end
	local modules = assert(fromModules[name], name)
	return { Include = function(_, moduleName) return assert(modules[moduleName], moduleName) end }
end

assert(load(AUCTION_SCROLL_TABLE_SRC, "AuctionScrollTable.lua"))(nil, { LibTSMUI = lib })
assert(auctionScrollTableClass)

local function newSubRow(name, baseItemString, sortValue)
	local row = {
		name = name,
		baseItemString = baseItemString,
		sortValue = sortValue,
	}
	function row:IsSubRow() return true end
	function row:GetBaseItemString() return self.baseItemString end
	function row:GetBuyouts() return self.sortValue, self.sortValue end
	function row:GetListingInfo() return nil, self.sortValue, self.sortValue end
	return row
end

local function newResultRow(baseItemString, subRows)
	local row = { baseItemString = baseItemString, subRows = subRows }
	function row:SubRowIterator() return ipairs(self.subRows) end
	return row
end

test("manual expand flushes stale data and keeps the clicked item after resort", function()
	local aOld = newSubRow("a-old", "i:1", 200)
	local aNew = newSubRow("a-new", "i:1", 100)
	local bFirst = newSubRow("b-first", "i:2", 50)
	local resultA = newResultRow("i:1", { aOld, aNew })
	local resultB = newResultRow("i:2", { bFirst })
	local timerCancelCount = 0
	local updateCount = 0
	local instance = {
		_rawData = { aOld, bFirst },
		_data = { baseItemString = { "i:1", "i:2" } },
		_rowByItem = { ["i:1"] = resultA, ["i:2"] = resultB },
		_expanded = {},
		_auctionScan = {},
		_updateDataPending = true,
		_updateThrottleTimer = {
			Cancel = function() timerCancelCount = timerCancelCount + 1 end,
		},
	}
	instance._FlushPendingUpdateData = auctionScrollTableClass.__protected._FlushPendingUpdateData
	function instance:_GetSettingsValue()
		return { sortCol = "pct", sortAscending = true }
	end
	function instance:_GetSortValue(row)
		return row.sortValue
	end
	function instance:_UpdateData(_, _, _, forceImmediate)
		assert(forceImmediate == true)
		updateCount = updateCount + 1
		self._rawData = { bFirst, aNew }
		self._data.baseItemString = { "i:2", "i:1" }
	end
	function instance:_InsertSubRows(dataIndex, rows)
		for i, row in ipairs(rows) do
			table.insert(self._rawData, dataIndex + i - 1, row)
			table.insert(self._data.baseItemString, dataIndex + i - 1, row:GetBaseItemString())
		end
	end
	function instance:_SetDataForRow() end
	function instance:_DrawRowsForUpdatedData() end

	auctionScrollTableClass.__private._SetExpanded(instance, 1, true)

	assert(updateCount == 1, "pending rebuild was not flushed")
	assert(timerCancelCount == 1, "pending throttle timer was not canceled")
	assert(instance._expanded["i:1"] == true, "clicked item was not expanded")
	assert(instance._expanded["i:2"] == nil, "resort expanded the wrong item")
	assert(instance._rawData[1] == bFirst)
	assert(instance._rawData[2] == aNew)
	assert(instance._rawData[3] == aOld)
end)

return failures
