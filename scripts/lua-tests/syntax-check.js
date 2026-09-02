// Syntax-checks every production Lua file modified by the consolidated fixes using
// the fengari Lua 5.1 compiler (load only, no execution - WoW globals are a
// runtime concern, not a syntax one).
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const files = [
	"TSM_CancelScan/Core.lua",
	"TSM_PostScan/Core.lua",
	"TradeSkillMaster/Compat/ClassicAPI/Lib/ChatThrottleLib.lua",
	"TradeSkillMaster/Compat/ClassicAPI/Util/EnumSupport.lua",
	"TradeSkillMaster/Compat/TSMDebug.lua",
	"TradeSkillMaster/Compat/WrathBootstrap.lua",
	"TradeSkillMaster/Core/Service/Auctioning/CancelScan.lua",
	"TradeSkillMaster/Core/Service/Auctioning/PostScan.lua",
	"TradeSkillMaster/Core/Service/Destroying/Core.lua",
	"TradeSkillMaster/Core/UI/AuctionUI/Core.lua",
	"TradeSkillMaster/Core/UI/AuctionUI/FullScan.lua",
	"TradeSkillMaster/Core/UI/MainUI/Core.lua",
	"TradeSkillMaster/Core/UI/MainUI/Groups.lua",
	"TradeSkillMaster/Core/UI/MainUI/Settings/General.lua",
	"TradeSkillMaster/LibTSMApp/Source/Service/SlashCommands.lua",
	"TradeSkillMaster/LibTSMService/Source/Auction/Classes/Scanner.lua",
	"TradeSkillMaster/LibTSMService/Source/AuctionScan/Classes/Query.lua",
	"TradeSkillMaster/LibTSMService/Source/AuctionScan/Classes/QueryUtil.lua",
	"TradeSkillMaster/LibTSMService/Source/AuctionScan/Classes/Row.lua",
	"TradeSkillMaster/LibTSMService/Source/AuctionScan/Classes/ScanManager.lua",
	"TradeSkillMaster/LibTSMService/Source/AuctionScan/Classes/Scanner.lua",
	"TradeSkillMaster/LibTSMService/Source/Debug/ErrorHandler.lua",
	"TradeSkillMaster/LibTSMService/Source/Inventory/BagTracking.lua",
	"TradeSkillMaster/LibTSMService/Source/Item/ItemInfo.lua",
	"TradeSkillMaster/LibTSMService/Source/UI/Theme.lua",
	"TradeSkillMaster/LibTSMService/Source/Vendor/Classes/BuyScanner.lua",
	"TradeSkillMaster/LibTSMSystem/Source/Operation/AuctioningOperation.lua",
	"TradeSkillMaster/LibTSMTypes/Source/Threading/Classes/Thread.lua",
	"TradeSkillMaster/LibTSMUI/Source/AuctionHouse/AuctionBuyScan.lua",
	"TradeSkillMaster/LibTSMUI/Source/AuctionHouse/AuctionScrollTable.lua",
	"TradeSkillMaster/LibTSMUI/Source/Debug/ErrorFrame.lua",
	"TradeSkillMaster/LibTSMUI/Source/Frames/ApplicationFrame.lua",
	"TradeSkillMaster/LibTSMUI/Source/Util/UIUtils.lua",
	"TradeSkillMaster/LibTSMUI/Source/Vendor/VendorBuyScrollTable.lua",
	"TradeSkillMaster/LibTSMUI/Source/Vendor/VendorBuybackScrollTable.lua",
	"TradeSkillMaster/LibTSMUI/Source/Vendor/VendorSellScrollTable.lua",
	"TradeSkillMaster/LibTSMWoW/Source/API/AuctionHouse.lua",
	"TradeSkillMaster/LibTSMWoW/Source/API/AuctionHouseWrapper.lua",
	"TradeSkillMaster/LibTSMWoW/Source/API/Item.lua",
	"TradeSkillMaster/LibTSMWoW/Source/API/Merchant.lua",
	"TradeSkillMaster/LibTSMWoW/Source/API/TradeSkill.lua",
	"TradeSkillMaster/LibTSMWoW/Source/UI/DefaultUI.lua",
	"TradeSkillMaster/LibTSMWoW/Source/Util/ItemClass.lua",
	"TradeSkillMaster/Locale/Core.lua",
	"TradeSkillMaster/Locale/enUS.lua",
	"TradeSkillMaster/Locale/zhCN.lua",
	"TradeSkillMaster/Locale/zhTW.lua",
	"TradeSkillMaster/TradeSkillMaster.lua",
	"TradeSkillMaster_Crafting/Service/Core.lua",
	"TradeSkillMaster_Crafting/Service/ProfessionUtil.lua",
	"TradeSkillMaster_Crafting/Service/Queue.lua",
	"TradeSkillMaster_Crafting/UI/CraftingUI_Crafting.lua",
	"TradeSkillMaster_Crafting/UI/MainUI_Settings_Crafting.lua",
];

let bad = 0;
for (const relPath of files) {
	const absPath = path.join(projectRoot, relPath);
	let content;
	try {
		content = fs.readFileSync(absPath, "utf8");
	} catch (e) {
		console.error(`READ FAIL: ${relPath}: ${e.message}`);
		bad++;
		continue;
	}
	if (content.charCodeAt(0) === 0xfeff) {
		content = content.slice(1);
	}
	const L = lauxlib.luaL_newstate();
	const status = lauxlib.luaL_loadbuffer(L, to_luastring(content), content.length, to_luastring(relPath));
	if (status !== lua.LUA_OK) {
		console.error(`SYNTAX FAIL: ${relPath}: ${lua.lua_tojsstring(L, -1)}`);
		bad++;
	} else {
		console.log(`SYNTAX OK: ${relPath}`);
	}
}
process.exit(bad > 0 ? 1 : 0);
