// Behavioral integration tests loading the real PostScan and CancelScan sources.
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const files = {
	TSM_PRICE_LOG_SRC: path.join(projectRoot, "TradeSkillMaster", "Compat", "TSMDebug.lua"),
	AUCTION_PRICE_LOG_PRELUDE_SRC: path.join(__dirname, "auction-price-log-prelude.lua"),
	POST_SCAN_SRC: path.join(projectRoot, "TradeSkillMaster", "Core", "Service", "Auctioning", "PostScan.lua"),
	CANCEL_SCAN_SRC: path.join(projectRoot, "TradeSkillMaster", "Core", "Service", "Auctioning", "CancelScan.lua"),
	AUCTION_PRICE_LOG_TEST_SRC: path.join(__dirname, "auction-price-log-integration-test.lua"),
};

function fail(message) {
	console.error(message);
	process.exit(1);
}

function readUtf8(filePath) {
	let content = fs.readFileSync(filePath, "utf8");
	if (content.charCodeAt(0) === 0xfeff) content = content.slice(1);
	return content;
}

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
for (const [globalName, filePath] of Object.entries(files)) {
	try {
		lua.lua_pushstring(L, to_luastring(readUtf8(filePath)));
		lua.lua_setglobal(L, to_luastring(globalName));
	} catch (e) {
		fail(`Cannot read ${filePath}: ${e.message}`);
	}
}

const source = `
	assert(load(TSM_PRICE_LOG_SRC, "TSMDebug.lua"))()
	AUCTION_PRICE_LOG_CTX = assert(load(AUCTION_PRICE_LOG_PRELUDE_SRC, "auction-price-log-prelude.lua"))()
	local passed, failures = assert(load(AUCTION_PRICE_LOG_TEST_SRC, "auction-price-log-integration-test.lua"))()
	return tostring(passed)..","..tostring(failures)
`;
const bytes = to_luastring(source);
let status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring("run-auction-price-log-tests.lua"));
if (status !== lua.LUA_OK) fail(`Syntax error: ${lua.lua_tojsstring(L, -1)}`);
status = lua.lua_pcall(L, 0, 1, 0);
if (status !== lua.LUA_OK) fail(`Runtime error: ${lua.lua_tojsstring(L, -1)}`);
const [passed, failures] = lua.lua_tojsstring(L, -1).split(",").map(Number);
console.log(`Auction price log integration tests: ${passed} passed, ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
