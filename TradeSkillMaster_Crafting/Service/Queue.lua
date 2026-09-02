-- ------------------------------------------------------------------------------ --
--                                TradeSkillMaster                                --
--                          https://tradeskillmaster.com                          --
--    All Rights Reserved - Detailed license information included with addon.     --
-- ------------------------------------------------------------------------------ --

local TSM = _G.TSMAddon ---@type TSM
local Queue = TSM.Crafting:NewPackage("Queue") ---@type AddonPackage
local Spell = TSM.LibTSMWoW:Include("API.Spell")
local CraftString = TSM.LibTSMTypes:Include("Crafting.CraftString")
local Database = TSM.LibTSMUtil:Include("Database")
local Math = TSM.LibTSMUtil:Include("Lua.Math")
local TempTable = TSM.LibTSMUtil:Include("BaseType.TempTable")
local RecipeString = TSM.LibTSMTypes:Include("Crafting.RecipeString")
local ItemString = TSM.LibTSMTypes:Include("Item.ItemString")
local MatString = TSM.LibTSMTypes:Include("Crafting.MatString")
local Group = TSM.LibTSMTypes:Include("Group")
local CustomString = TSM.LibTSMTypes:Include("CustomString")
local ChatMessage = TSM.LibTSMService:Include("UI.ChatMessage")
local BagTracking = TSM.LibTSMService:Include("Inventory.BagTracking")
local Auction = TSM.LibTSMService:Include("Auction")
local Inventory = TSM.LibTSMApp:Include("Service.Inventory")
local CraftingOperation = TSM.LibTSMSystem:Include("CraftingOperation")
local AltTracking = TSM.LibTSMApp:Include("Service.AltTracking")
local SessionInfo = TSM.LibTSMWoW:Include("Util.SessionInfo")
local private = {
	settings = nil,
	db = nil,
	optionalMatTemp = {},
	matsTemp = {},
	qualityMatTemp = {},
	-- 3.3.5 perf: кэш GetTotals — UI зовёт его на каждую перерисовку, а без
	-- кэша каждый вызов пересчитывает стоимость всех рецептов очереди.
	-- Инвалидация: любое изменение очереди (SetNum/Clear) + короткий TTL,
	-- чтобы подхватывать изменения цен.
	totalsCacheTime = 0,
	totalsCacheCost = nil,
	totalsCacheProfit = nil,
	totalsCacheCastTime = nil,
}
local MAX_NUM_QUEUED = 9999
local TOTALS_CACHE_TTL = 5



-- ============================================================================
-- Module Functions
-- ============================================================================

function Queue.OnInitialize(settingsDB)
	private.settings = settingsDB:NewView()
		:AddKey("factionrealm", "internalData", "craftingQueue")
		:AddKey("factionrealm", "internalData", "crafts")
		:AddKey("global", "craftingOptions", "ignoreGuilds")
		:AddKey("global", "craftingOptions", "ignoreCharacters")
end

function Queue.OnEnable()
	private.db = Database.NewSchema("CRAFTING_QUEUE")
		:AddUniqueStringField("recipeString")
		:AddStringField("craftString")
		:AddNumberField("num")
		:Commit()

	-- Copy to a temp table first since we might otherwise be modifying the settings table as we iterate
	local queuedRecipes = TempTable.Acquire()
	for recipeString, numQueued in pairs(private.settings.craftingQueue) do
		queuedRecipes[recipeString] = numQueued
	end
	private.db:SetQueryUpdatesPaused(true)
	for recipeString, numQueued in pairs(queuedRecipes) do
		Queue.SetNum(recipeString, numQueued)
	end
	private.db:SetQueryUpdatesPaused(false)
	TempTable.Release(queuedRecipes)
end

function Queue.GetDBForJoin()
	return private.db
end

function Queue.CreateQuery()
	return private.db:NewQuery()
end

function Queue.SetNum(recipeString, num)
	assert(type(recipeString) == "string")
	assert(strfind(recipeString, "^r:%d+"))
	private.totalsCacheTime = 0
	local numQueued = min(max(Math.Round(num or 0), 0), MAX_NUM_QUEUED)
	private.settings.craftingQueue[recipeString] = numQueued > 0 and numQueued or nil
	local query = private.db:NewQuery()
		:Equal("recipeString", recipeString)
	local row = query:GetFirstResult()
	if row and numQueued == 0 then
		-- Delete this row
		private.db:DeleteRow(row)
	elseif row then
		-- Update this row
		row:SetField("num", numQueued)
			:Update()
	elseif numQueued > 0 then
		local craftString = CraftString.FromRecipeString(recipeString)
		-- Insert a new row
		private.db:NewRow()
			:SetField("recipeString", recipeString)
			:SetField("craftString", craftString)
			:SetField("num", numQueued)
			:Create()
	end
	query:Release()
end

function Queue.GetNum(recipeString)
	return private.db:GetUniqueRowField("recipeString", recipeString, "num") or 0
end

function Queue.GetNumByCraftString(craftString)
	return private.db:NewQuery()
		:Equal("craftString", craftString)
		:SumAndRelease("num")
end

function Queue.Adjust(recipeString, amount)
	Queue.SetNum(recipeString, Queue.GetNum(recipeString) + amount)
end

function Queue.Clear()
	private.totalsCacheTime = 0
	wipe(private.settings.craftingQueue)
	private.db:Truncate()
end

function Queue.GetNumItems()
	return private.db:NewQuery():CountAndRelease()
end

function Queue.GetTotals()
	-- 3.3.5 perf: см. комментарий у totalsCacheTime
	if GetTime() - private.totalsCacheTime < TOTALS_CACHE_TTL then
		return private.totalsCacheCost, private.totalsCacheProfit, private.totalsCacheCastTime
	end
	local totalCost, totalProfit, totalCastTimeMs = nil, nil, nil
	local query = private.db:NewQuery()
		:Select("recipeString", "craftString", "num")
	for _, recipeString, craftString, numQueued in query:Iterator() do
		local craftInfo = private.settings.crafts[craftString]
		local numResult = craftInfo and craftInfo.numResult or 0
		local cost, _, profit = TSM.Crafting.Cost.GetCostsByRecipeString(recipeString)
		if cost then
			totalCost = (totalCost or 0) + cost * numQueued * numResult
		end
		if profit then
			totalProfit = (totalProfit or 0) + profit * numQueued * numResult
		end
		local spellId = CraftString.GetSpellId(craftString)
		local _, _, castTime = Spell.GetInfo(spellId)
		if castTime then
			totalCastTimeMs = (totalCastTimeMs or 0) + castTime * numQueued
		end
	end
	query:Release()
	private.totalsCacheTime = GetTime()
	private.totalsCacheCost = totalCost
	private.totalsCacheProfit = totalProfit
	private.totalsCacheCastTime = totalCastTimeMs and ceil(totalCastTimeMs / 1000) or nil
	return private.totalsCacheCost, private.totalsCacheProfit, private.totalsCacheCastTime
end

function Queue.RestockGroups(groups)
	-- 3.3.5: bag tracking events are unreliable at login, so force a synchronous
	-- rescan to make sure NumInventory reflects items crafted since login.
	BagTracking.RescanAllBags()
	if _G.TSM_CRAFT_TRACE then
		local ignoredChars = TempTable.Acquire()
		for player, ignored in pairs(private.settings.ignoreCharacters) do
			if ignored then
				tinsert(ignoredChars, player)
			end
		end
		local ignoredGuilds = TempTable.Acquire()
		for guild, ignored in pairs(private.settings.ignoreGuilds) do
			if ignored then
				tinsert(ignoredGuilds, guild)
			end
		end
		print(("[TSM RestockTrace] restock begin: ignoreCharacters=[%s] ignoreGuilds=[%s]"):format(table.concat(ignoredChars, ", "), table.concat(ignoredGuilds, ", ")))
		TempTable.Release(ignoredChars)
		TempTable.Release(ignoredGuilds)
	end
	private.db:SetQueryUpdatesPaused(true)
	for _, groupPath in ipairs(groups) do
		if groupPath ~= Group.GetRootPath() then
			for _, itemString in Group.ItemIterator(groupPath) do
				local levelItemString = ItemString.ToLevel(itemString)
				if TSM.Crafting.CanCraftItem(levelItemString) then
					local isValid, err = TSM.Crafting.IsOperationValid(itemString)
					if isValid then
						private.RestockItem(itemString)
					elseif err then
						ChatMessage.PrintUser(err)
					end
				end
			end
		end
	end
	private.db:SetQueryUpdatesPaused(false)
end



-- ============================================================================
-- Private Helper Functions
-- ============================================================================

function private.RestockItem(itemString)
	assert(not next(private.optionalMatTemp) and not next(private.qualityMatTemp))
	local cheapestCost, cheapestCraftString, cheapestConcentration = TSM.Crafting.Cost.GetLowestCostByItem(itemString, private.optionalMatTemp, private.qualityMatTemp)
	if not cheapestCraftString or (cheapestConcentration or 0) > 0 then
		-- Can't craft this item (or need concentration)
		wipe(private.qualityMatTemp)
		wipe(private.optionalMatTemp)
		return
	end
	for _, matItemString in ipairs(private.qualityMatTemp) do
		local matString = private.qualityMatTemp[matItemString]
		private.optionalMatTemp[MatString.GetSlotId(matString)] = ItemString.ToId(matItemString)
	end
	wipe(private.qualityMatTemp)
	local recipeString = RecipeString.FromCraftString(cheapestCraftString, private.optionalMatTemp)
	wipe(private.optionalMatTemp)
	local itemValue = TSM.Crafting.Cost.GetCraftedItemValue(itemString)
	local profit = itemValue and cheapestCost and (itemValue - cheapestCost) or nil
	local hasMinProfit, minProfit = CraftingOperation.GetMinProfit(itemString)
	if hasMinProfit and (not minProfit or not profit or profit < minProfit) then
		-- Profit is too low
		return
	end

	local haveQuantity = CustomString.GetSourceValue("NumInventory", itemString) or 0
	local rawHaveQuantity = haveQuantity
	for guild, ignored in pairs(private.settings.ignoreGuilds) do
		if ignored then
			haveQuantity = haveQuantity - AltTracking.GetGuildQuantity(itemString, guild)
		end
	end
	for player, ignored in pairs(private.settings.ignoreCharacters) do
		-- NumInventory always includes the current player's own inventory, so
		-- subtracting it here (own character selected in the ignore list) would
		-- cancel it out and make every owned item look missing - the restock queue
		-- then re-adds everything the player already has.
		if ignored and not SessionInfo.IsPlayer(player) then
			haveQuantity = haveQuantity - AltTracking.GetBagQuantity(itemString, player)
			haveQuantity = haveQuantity - AltTracking.GetBankQuantity(itemString, player)
			haveQuantity = haveQuantity - AltTracking.GetAuctionQuantity(itemString, player)
			haveQuantity = haveQuantity - AltTracking.GetMailQuantity(itemString, player)
		end
	end
	-- 3.3.5 fix: clamp вместо assert. NumInventory и AltTracking на backport'е
	-- могут расходиться охватом источников (например, почта игнорируемого
	-- персонажа, не учтённая в NumInventory) — разность уходила в минус и
	-- assert ронял весь Restock Groups.
	haveQuantity = max(haveQuantity, 0)
	local neededQuantity = CraftingOperation.GetRestockQuantity(itemString, haveQuantity)
	-- Diagnostic instrumentation toggled by "/tsmcraftdebug trace": raw is the
	-- NumInventory source value (what the data layer holds), ignoredSub is how much
	-- the ignore-characters/guilds lists subtracted, and have is the final value the
	-- restock decision used. fresh/bag/ah are direct data-layer reads for comparison.
	if _G.TSM_CRAFT_TRACE then
		local freshQuantity = Inventory.GetTotalQuantity(itemString)
		local ignoredSub = rawHaveQuantity - haveQuantity
		print(("[TSM RestockTrace] %s raw=%d ignoredSub=%d have=%d fresh(data)=%d bag=%d ah=%d needed=%d%s%s"):format(
			itemString,
			rawHaveQuantity,
			ignoredSub,
			haveQuantity,
			freshQuantity,
			BagTracking.GetBagQuantity(itemString),
			Auction.GetQuantity(itemString),
			neededQuantity,
			neededQuantity == 0 and " (skip)" or "",
			ignoredSub > 0 and "  <<< IGNORED INVENTORY SUBTRACTED" or (rawHaveQuantity < freshQuantity and "  <<< STALE CACHE" or "")
		))
	end
	if neededQuantity == 0 then
		return
	end
	if CraftString.GetQuality(cheapestCraftString) then
		assert(not next(private.matsTemp) and not next(private.qualityMatTemp))
		TSM.Crafting.GetMatsAsTable(cheapestCraftString, private.matsTemp)
		wipe(private.qualityMatTemp)
		wipe(private.matsTemp)
	end
	Queue.SetNum(recipeString, floor(neededQuantity / TSM.Crafting.GetNumResult(cheapestCraftString)))
end
