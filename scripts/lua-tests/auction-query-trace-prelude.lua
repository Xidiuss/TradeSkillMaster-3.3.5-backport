local function NewProviderEnum(glyphClassId)
	if glyphClassId == 5 then
		return {
			Weapon = 1, Armor = 2, Container = 3, Consumable = 4,
			Glyph = 5, Tradegoods = 6, Projectile = 7, Quiver = 8,
			Recipe = 9, Gem = 10, Miscellaneous = 11, Questitem = 12,
		}
	end
	return {
		Weapon = 2, Armor = 4, Container = 1, Consumable = 0,
		Glyph = 16, Tradegoods = 7, Projectile = 6, Quiver = 11,
		Recipe = 9, Gem = 3, Miscellaneous = 15, Questitem = 12,
	}
end

local function NewWrapperContext(glyphClassId)
	local nativeCalls = {}
	local sequence = {}
	local moduleLoadCallback = nil
	local nativeQueryHook = nil
	local nativeHooksEnabled = true
	local module = {}

	_G.TSM_SCAN_TRACE = true
	_G.TSMPostScanLogDB = nil
	_G.TSMCancelScanLogDB = nil
	_G.time = function() return 100 end
	_G.Enum = {
		ItemClass = NewProviderEnum(glyphClassId),
		InventoryType = {
			IndexChestType = 5,
			IndexRobeType = 20,
			IndexNeckType = 2,
			IndexFingerType = 11,
			IndexTrinketType = 12,
			IndexHoldableType = 23,
			IndexBodyType = 4,
			IndexCloakType = 16,
		},
		ItemArmorSubclass = { Generic = 0, Cloth = 1 },
	}
	_G.ItemLocation = { CreateEmpty = function() return {} end }
	_G.wipe = function(tbl)
		for key in pairs(tbl) do
			tbl[key] = nil
		end
		return tbl
	end
	_G.tinsert = table.insert
	_G.strmatch = string.match
	_G.strsplit = function(separator, value)
		local separatorStart, separatorEnd = string.find(value, separator, 1, true)
		if not separatorStart then
			return value
		end
		return string.sub(value, 1, separatorStart - 1), string.sub(value, separatorEnd + 1)
	end
	_G.min = math.min
	_G.GetTime = function() return 100 end

	_G.QueryAuctionItems = function(...)
		table.insert(sequence, "NATIVE")
		table.insert(nativeCalls, { count = select("#", ...), ... })
		if nativeHooksEnabled and nativeQueryHook then
			nativeQueryHook(...)
		end
	end
	_G.hooksecurefunc = function(target, name, callback)
		if target == _G and name == "QueryAuctionItems" then
			nativeQueryHook = callback
		end
	end

	assert(load(TSM_DEBUG_SRC, "TSMDebug.lua"))()
	local realPriceLogTrace = TSMDBG.PriceLogTrace
	TSMDBG.PriceLogTrace = function(message)
		table.insert(sequence, "TRACE")
		return realPriceLogTrace(message)
	end

	-- API_EVENT_INFO references many client constants while the module loads.
	-- Give only missing all-caps constants stable, unique values.
	local previousGlobalMetatable = getmetatable(_G)
	setmetatable(_G, {
		__index = function(tbl, key)
			if type(key) == "string" and key:match("^[A-Z][A-Z0-9_]+$") then
				rawset(tbl, key, key)
				return key
			end
			if previousGlobalMetatable and previousGlobalMetatable.__index then
				if type(previousGlobalMetatable.__index) == "function" then
					return previousGlobalMetatable.__index(tbl, key)
				end
				return previousGlobalMetatable.__index[key]
			end
		end,
	})

	local futureType = {}
	function futureType.New()
		return {
			SetScript = function(self, _, callback) self.cleanup = callback end,
			Start = function() end,
			Done = function(self)
				if self.cleanup then
					self.cleanup()
				end
			end,
		}
	end

	local delayTimer = {}
	function delayTimer.New()
		return {
			RunForTime = function() end,
			Cancel = function() end,
		}
	end

	local APIWrapper = {}
	setmetatable(APIWrapper, {
		__call = function(class, name)
			local instance = setmetatable({}, { __index = class })
			instance:__init(name)
			return instance
		end,
	})

	function module:OnModuleLoad(callback)
		moduleLoadCallback = callback
	end

	local clientInfo = {
		FEATURES = { C_AUCTION_HOUSE = "C_AUCTION_HOUSE" },
		HasFeature = function() return false end,
		IsRetail = function() return false end,
	}
	local auctionHouse = { CanSendQuery = function() return true end }
	local event = { Register = function() end, Unregister = function() end }
	local defaultUI = {
		RegisterAuctionHouseVisibleCallback = function() end,
		IsAuctionHouseVisible = function() return true end,
	}
	local log = { Warn = function() end, Err = function() end, Info = function() end }

	local utilLibrary = {}
	function utilLibrary:IncludeClassType()
		return futureType
	end
	function utilLibrary:Include(name)
		if name == "Util.Log" then
			return log
		elseif name == "Lua.Math" then
			return { Round = function(value) return value end }
		elseif name == "Lua.Table" then
			return { Equal = function(left, right) return left == right end }
		elseif name == "Lua.Vararg" then
			return {
				IntoTable = function(tbl, ...)
					wipe(tbl)
					for index = 1, select("#", ...) do
						tbl[index] = select(index, ...)
					end
				end,
			}
		elseif name == "Lua.DebugStack" then
			return { GetLocation = function() return nil end }
		elseif name == "Util.Analytics" then
			return { Action = function() end }
		end
		return {}
	end

	local lib = {}
	function lib:Init()
		return module
	end
	function lib:Include(name)
		if name == "API.AuctionHouse" then
			return auctionHouse
		elseif name == "Service.Event" then
			return event
		elseif name == "UI.DefaultUI" then
			return defaultUI
		elseif name == "Util.ClientInfo" then
			return clientInfo
		end
		return {}
	end
	function lib:IncludeClassType()
		return delayTimer
	end
	function lib:From()
		return utilLibrary
	end
	function lib:DefineClassType()
		return APIWrapper
	end

	assert(load(AUCTION_HOUSE_WRAPPER_SRC, "AuctionHouseWrapper.lua"))(nil, { LibTSMWoW = lib })
	assert(moduleLoadCallback, "AuctionHouseWrapper did not register OnModuleLoad")
	moduleLoadCallback()

	return {
		module = module,
		nativeCalls = nativeCalls,
		sequence = sequence,
		SetNativeHooksEnabled = function(value)
			nativeHooksEnabled = value
		end,
	}
end

return NewWrapperContext
