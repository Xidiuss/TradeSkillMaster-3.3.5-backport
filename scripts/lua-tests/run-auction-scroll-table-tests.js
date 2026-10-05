// Behavioral regression test for expanding an auction row while a throttled
// full rebuild is pending. Loads the real AuctionScrollTable source in Fengari.
"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const files = {
	AUCTION_SCROLL_TABLE_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMUI", "Source", "AuctionHouse", "AuctionScrollTable.lua"),
	AUCTION_SCROLL_TABLE_TEST_SRC: path.join(__dirname, "auction-scroll-table-test.lua"),
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
	local chunk = assert(load(AUCTION_SCROLL_TABLE_TEST_SRC, "auction-scroll-table-test.lua"))
	return tostring(chunk())
`;
const bytes = to_luastring(source);
let status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring("run-auction-scroll-table-tests.lua"));
if (status !== lua.LUA_OK) fail(`Syntax error: ${lua.lua_tojsstring(L, -1)}`);
status = lua.lua_pcall(L, 0, 1, 0);
if (status !== lua.LUA_OK) fail(`Runtime error: ${lua.lua_tojsstring(L, -1)}`);
const failures = Number(lua.lua_tojsstring(L, -1));
console.log(`Auction scroll table tests: ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
