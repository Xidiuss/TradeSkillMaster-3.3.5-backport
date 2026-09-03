// Executable behavior tests for the TSM 3.3.5 vendor fixes.
// Loads the real addon sources in Fengari and supplies only the WoW / TSM
// boundaries needed by the scenarios under test.
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const luaFiles = {
	REMAINING_VENDOR_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMUI", "Source", "Vendor", "VendorBuyScrollTable.lua"),
	REMAINING_MERCHANT_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMWoW", "Source", "API", "Merchant.lua"),
	REMAINING_BUY_SCANNER_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMService", "Source", "Vendor", "Classes", "BuyScanner.lua"),
	REMAINING_TOOLTIP_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMUI", "Source", "Tooltip", "Tooltip.lua"),
	REMAINING_POSTSCAN_SRC: path.join(projectRoot, "TradeSkillMaster", "Core", "Service", "Auctioning", "PostScan.lua"),
	REMAINING_OPEN_SRC: path.join(projectRoot, "TradeSkillMaster_Mailing", "Service", "Open.lua"),
	REMAINING_INBOX_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMWoW", "Source", "API", "Inbox.lua"),
	REMAINING_ITEMINFO_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMService", "Source", "Item", "ItemInfo.lua"),
	REMAINING_ITEM_API_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMWoW", "Source", "API", "Item.lua"),
	REMAINING_TEST_SRC: path.join(__dirname, "vendor-fixes-test.lua"),
};

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function fail(message) {
	console.error(message);
	process.exit(1);
}

for (const [globalName, filePath] of Object.entries(luaFiles)) {
	let content;
	try {
		content = fs.readFileSync(filePath, "utf8");
	} catch (e) {
		fail(`Cannot read ${filePath}: ${e.message}`);
	}
	if (content.charCodeAt(0) === 0xfeff) {
		content = content.slice(1);
	}
	lua.lua_pushstring(L, to_luastring(content));
	lua.lua_setglobal(L, to_luastring(globalName));
}

function doLua(source, chunkName) {
	const bytes = to_luastring(source);
	const status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring(chunkName));
	if (status !== lua.LUA_OK) {
		fail(`Syntax error in ${chunkName}: ${lua.lua_tojsstring(L, -1)}`);
	}
	const callStatus = lua.lua_pcall(L, 0, 1, 0);
	if (callStatus !== lua.LUA_OK) {
		fail(`Runtime error in ${chunkName}: ${lua.lua_tojsstring(L, -1)}`);
	}
	const result = lua.lua_tojsstring(L, -1);
	lua.lua_pop(L, 1);
	return result;
}

const failures = doLua(`
	local chunk = assert(load(REMAINING_TEST_SRC, "vendor-fixes-test.lua"))
	return chunk()
`, "run-vendor-fixes");

console.log(`Vendor fix tests: ${failures} failed`);
process.exit(parseInt(failures, 10) > 0 ? 1 : 0);
