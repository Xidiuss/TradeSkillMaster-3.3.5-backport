-- ------------------------------------------------------------------------------ --
--                                TradeSkillMaster                                --
--                          https://tradeskillmaster.com                          --
--    All Rights Reserved - Detailed license information included with addon.     --
-- ------------------------------------------------------------------------------ --

if not TSMDEV then
	return
end
TSMDEV.Tracing = {}
local Tracing = TSMDEV.Tracing
local LibTSMDev = select(2, ...).LibTSMDev
local Log = LibTSMDev:From("LibTSMUtil"):Include("Util.Log")



-- ============================================================================
-- Module Functions
-- ============================================================================

function Tracing.Enable(apiName)
	local tableName, tableKey = strsplit(".", apiName)
	if not tableKey then
		tableKey = tableName
		tableName = nil
	end
	assert(tableKey)
	--! WotLK fix: Blizzard_EventTrace / EventTrace:LogEvent do not exist here.
	hooksecurefunc(tableName and _G[tableName] or _G, tableKey, function(...)
		local argStr = ""
		for i = 1, select("#", ...) do
			argStr = argStr..(i > 1 and ", " or "")..tostring((select(i, ...)))
		end
		Log.Info("%s(%s)", apiName, argStr)
	end)
end
