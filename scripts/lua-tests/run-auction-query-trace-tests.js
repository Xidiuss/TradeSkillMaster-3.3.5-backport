// Behavioral test for the real classic AuctionHouseWrapper.SendQuery boundary.
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const files = {
	TSM_DEBUG_SRC: path.join(projectRoot, "TradeSkillMaster", "Compat", "TSMDebug.lua"),
	AUCTION_HOUSE_WRAPPER_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMWoW", "Source", "API", "AuctionHouseWrapper.lua"),
	AUCTION_QUERY_TRACE_PRELUDE_SRC: path.join(__dirname, "auction-query-trace-prelude.lua"),
	AUCTION_QUERY_TRACE_TEST_SRC: path.join(__dirname, "auction-query-trace-test.lua"),
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
	} catch (error) {
		fail(`Cannot read ${filePath}: ${error.message}`);
	}
}

const source = `
	NewWrapperContext = assert(load(AUCTION_QUERY_TRACE_PRELUDE_SRC, "auction-query-trace-prelude.lua"))()
	local passed, failures = assert(load(AUCTION_QUERY_TRACE_TEST_SRC, "auction-query-trace-test.lua"))()
	return tostring(passed)..","..tostring(failures)
`;
const bytes = to_luastring(source);
let status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring("run-auction-query-trace-tests.lua"));
if (status !== lua.LUA_OK) fail(`Syntax error: ${lua.lua_tojsstring(L, -1)}`);
status = lua.lua_pcall(L, 0, 1, 0);
if (status !== lua.LUA_OK) fail(`Runtime error: ${lua.lua_tojsstring(L, -1)}`);
const [passed, failures] = lua.lua_tojsstring(L, -1).split(",").map(Number);
console.log(`Auction query trace tests: ${passed} passed, ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
