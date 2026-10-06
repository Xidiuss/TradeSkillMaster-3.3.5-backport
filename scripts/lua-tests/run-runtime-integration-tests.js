"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const sources = {
	R_LIBSTUB: ["TradeSkillMaster", "External", "EmbeddedLibs", "LibStub", "LibStub.lua"],
	R_TSM_DEBUG: ["TradeSkillMaster", "Compat", "TSMDebug.lua"],
	R_CLASS: ["TradeSkillMaster", "External", "LibTSMClass", "LibTSMClass.lua"],
	R_CORE: ["TradeSkillMaster", "LibTSMCore", "Core.lua"],
	R_UTIL_CORE: ["TradeSkillMaster", "LibTSMUtil", "Source", "Core.lua"],
	R_DEBUG_STACK: ["TradeSkillMaster", "LibTSMUtil", "Source", "Lua", "DebugStack.lua"],
	R_MATH: ["TradeSkillMaster", "LibTSMUtil", "Source", "Lua", "Math.lua"],
	R_TABLE: ["TradeSkillMaster", "LibTSMUtil", "Source", "Lua", "Table.lua"],
	R_VARARG: ["TradeSkillMaster", "LibTSMUtil", "Source", "Lua", "Vararg.lua"],
	R_STRING: ["TradeSkillMaster", "LibTSMUtil", "Source", "Lua", "String.lua"],
	R_ENUM: ["TradeSkillMaster", "LibTSMUtil", "Source", "BaseType", "EnumType.lua"],
	R_FUTURE: ["TradeSkillMaster", "LibTSMUtil", "Source", "BaseType", "Future.lua"],
	R_ITERATOR: ["TradeSkillMaster", "LibTSMUtil", "Source", "BaseType", "Iterator.lua"],
	R_NAMED_TUPLE_LIST: ["TradeSkillMaster", "LibTSMUtil", "Source", "BaseType", "NamedTupleList.lua"],
	R_OBJECT_POOL: ["TradeSkillMaster", "LibTSMUtil", "Source", "BaseType", "ObjectPool.lua"],
	R_SMART_MAP: ["TradeSkillMaster", "LibTSMUtil", "Source", "BaseType", "SmartMap.lua"],
	R_TEMP_TABLE: ["TradeSkillMaster", "LibTSMUtil", "Source", "BaseType", "TempTable.lua"],
	R_BINARY_SEARCH: ["TradeSkillMaster", "LibTSMUtil", "Source", "Util", "BinarySearch.lua"],
	R_HASH: ["TradeSkillMaster", "LibTSMUtil", "Source", "Util", "Hash.lua"],
	R_LOG: ["TradeSkillMaster", "LibTSMUtil", "Source", "Util", "Log.lua"],
	R_FSM_STATE: ["TradeSkillMaster", "LibTSMUtil", "Source", "FSM", "Type", "State.lua"],
	R_FSM_OBJECT: ["TradeSkillMaster", "LibTSMUtil", "Source", "FSM", "Type", "Object.lua"],
	R_FSM: ["TradeSkillMaster", "LibTSMUtil", "Source", "FSM", "FSM.lua"],
	R_REACTIVE_PUBLISHER: ["TradeSkillMaster", "LibTSMUtil", "Source", "Reactive", "Type", "Publisher.lua"],
	R_REACTIVE_EXPRESSION: ["TradeSkillMaster", "LibTSMUtil", "Source", "Reactive", "Type", "Expression.lua"],
	R_REACTIVE_STATE: ["TradeSkillMaster", "LibTSMUtil", "Source", "Reactive", "Type", "State.lua"],
	R_REACTIVE_STATE_SCHEMA: ["TradeSkillMaster", "LibTSMUtil", "Source", "Reactive", "Type", "StateSchema.lua"],
	R_REACTIVE_STREAM: ["TradeSkillMaster", "LibTSMUtil", "Source", "Reactive", "Type", "Stream.lua"],
	R_REACTIVE: ["TradeSkillMaster", "LibTSMUtil", "Source", "Reactive", "Reactive.lua"],
	R_DATABASE_UTIL: ["TradeSkillMaster", "LibTSMUtil", "Source", "Database", "Util.lua"],
	R_DATABASE_ROW: ["TradeSkillMaster", "LibTSMUtil", "Source", "Database", "Type", "Row.lua"],
	R_DATABASE_QUERY_CLAUSE: ["TradeSkillMaster", "LibTSMUtil", "Source", "Database", "Type", "QueryClause.lua"],
	R_DATABASE_QUERY: ["TradeSkillMaster", "LibTSMUtil", "Source", "Database", "Type", "Query.lua"],
	R_DATABASE_TABLE: ["TradeSkillMaster", "LibTSMUtil", "Source", "Database", "Type", "Table.lua"],
	R_DATABASE_SCHEMA: ["TradeSkillMaster", "LibTSMUtil", "Source", "Database", "Type", "Schema.lua"],
	R_DATABASE: ["TradeSkillMaster", "LibTSMUtil", "Source", "Database", "Database.lua"],
	R_TYPES_CORE: ["TradeSkillMaster", "LibTSMTypes", "Source", "Core.lua"],
	R_EVENT_WAITER: ["TradeSkillMaster", "LibTSMTypes", "Source", "Threading", "Classes", "EventWaiter.lua"],
	R_FUNCTION_WAITER: ["TradeSkillMaster", "LibTSMTypes", "Source", "Threading", "Classes", "FunctionWaiter.lua"],
	R_FUTURE_WAITER: ["TradeSkillMaster", "LibTSMTypes", "Source", "Threading", "Classes", "FutureWaiter.lua"],
	R_SCHEDULER: ["TradeSkillMaster", "LibTSMTypes", "Source", "Threading", "Classes", "Scheduler.lua"],
	R_THREAD: ["TradeSkillMaster", "LibTSMTypes", "Source", "Threading", "Classes", "Thread.lua"],
	R_THREADING: ["TradeSkillMaster", "LibTSMTypes", "Source", "Threading", "Threading.lua"],
	R_WOW_CORE: ["TradeSkillMaster", "LibTSMWoW", "Source", "Core.lua"],
	R_INBOX: ["TradeSkillMaster", "LibTSMWoW", "Source", "API", "Inbox.lua"],
	R_SERVICE_CORE: ["TradeSkillMaster", "LibTSMService", "Source", "Core.lua"],
	R_MAIL_UTIL: ["TradeSkillMaster", "LibTSMService", "Source", "Mail", "Classes", "Util.lua"],
	R_MAIL_SCANNER: ["TradeSkillMaster", "LibTSMService", "Source", "Mail", "Classes", "Scanner.lua"],
	R_ACCOUNTING_MAIL: ["TradeSkillMaster_Accounting", "Service", "Mail.lua"],
	R_OPEN: ["TradeSkillMaster_Mailing", "Service", "Open.lua"],
	R_MAIL_UI: ["TradeSkillMaster_Mailing", "UI", "MailingUI_Inbox.lua"],
	R_TEST: ["scripts", "lua-tests", "runtime-integration-test.lua"],
};

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function fail(message) {
	console.error(message);
	process.exit(1);
}

for (const [globalName, relativeParts] of Object.entries(sources)) {
	const filePath = path.join(projectRoot, ...relativeParts);
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

const launch = `
	local chunk = assert(load(R_TEST, "runtime-integration-test.lua"))
	return chunk()
`;
const bytes = to_luastring(launch);
let status = lauxlib.luaL_loadbuffer(L, bytes, bytes.length, to_luastring("run-runtime-integration-tests"));
if (status !== lua.LUA_OK) {
	fail(`Syntax error: ${lua.lua_tojsstring(L, -1)}`);
}
status = lua.lua_pcall(L, 0, 1, 0);
if (status !== lua.LUA_OK) {
	fail(`Runtime error: ${lua.lua_tojsstring(L, -1)}`);
}
const failures = Number(lua.lua_tojsstring(L, -1));
console.log(`Runtime integration tests: ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
