-- ------------------------------------------------------------------------------ --
--                                TradeSkillMaster                                --
--                          https://tradeskillmaster.com                          --
--    All Rights Reserved - Detailed license information included with addon.     --
-- ------------------------------------------------------------------------------ --

local LibTSMDev = select(2, ...).LibTSMDev
local StateInspect = LibTSMDev:Init("StateInspect")
local SlashCommands = LibTSMDev:From("LibTSMApp"):Include("Service.SlashCommands")
local State = LibTSMDev:From("LibTSMUtil"):Include("Reactive.Type.State")



-- ============================================================================
-- Module Loading
-- ============================================================================

StateInspect:OnModuleLoad(function()
	SlashCommands.RegisterDebug("state", function()
		C_AddOns.LoadAddOn("Blizzard_DebugTools")
		--! WotLK fix: 3.3.5a DebugTools has DevTools_Dump, but no table inspector.
		DevTools_Dump(State.GetDebugData())
	end)
end)
