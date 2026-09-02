// Behavioral tests for the real AuctionScan planner sources in a Fengari VM.
"use strict";

const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const projectRoot = path.resolve(__dirname, "..", "..");
const files = {
	PLANNER_PRELUDE_SRC: path.join(__dirname, "planner-prelude.lua"),
	QUERY_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMService", "Source", "AuctionScan", "Classes", "Query.lua"),
	QUERY_UTIL_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMService", "Source", "AuctionScan", "Classes", "QueryUtil.lua"),
	SCAN_MANAGER_SRC: path.join(projectRoot, "TradeSkillMaster", "LibTSMService", "Source", "AuctionScan", "Classes", "ScanManager.lua"),
	PLANNER_TEST_SRC: path.join(__dirname, "planner-test.lua"),
};

const mutations = {
	cost_strictness: {
		file: "QUERY_UTIL_SRC",
		from: "if fallbackEst < remainingPageEst then",
		to: "if fallbackEst <= remainingPageEst then",
	},
	category_threshold_12: {
		file: "QUERY_UTIL_SRC",
		from: "local CLASS_BATCH_MIN_ITEMS = 13",
		to: "local CLASS_BATCH_MIN_ITEMS = 12",
	},
	category_threshold_14: {
		file: "QUERY_UTIL_SRC",
		from: "local CLASS_BATCH_MIN_ITEMS = 13",
		to: "local CLASS_BATCH_MIN_ITEMS = 14",
	},
	nested_fallback_underestimate: {
		file: "QUERY_UTIL_SRC",
		from: "fallbackQueryCount = fallbackQueryCount + 1 + (root.children and #root.children or 0)",
		to: "fallbackQueryCount = fallbackQueryCount + 1",
	},
	remove_parent_chain: {
		file: "SCAN_MANAGER_SRC",
		from: "\t\tparent = parent:GetFallbackParent()",
		to: "\t\tparent = nil -- mutation: check the direct parent only",
	},
	repeated_page_full: {
		file: "QUERY_SRC",
		from: "self:_SetBrowseEndReason(\"INCOMPLETE\")",
		to: "self:_SetBrowseEndReason(\"FULL\")",
	},
	repeated_page_same_evaluation: {
		file: "QUERY_SRC",
		from: "self._lastPageFingerprintPage == self._page - 1 and self._lastPageFingerprint == pageFingerprint",
		to: "self._lastPageFingerprint == pageFingerprint",
	},
	consume_cost_switch: {
		file: "SCAN_MANAGER_SRC",
		from: "local consumeResults = (not planKind and endReason ~= \"INCOMPLETE\") or endReason == \"FULL\"",
		to: "local consumeResults = (not planKind and endReason ~= \"INCOMPLETE\") or endReason == \"FULL\" or endReason == \"COST_SWITCH\"",
	},
	consume_planned_early: {
		file: "SCAN_MANAGER_SRC",
		from: "local consumeResults = (not planKind and endReason ~= \"INCOMPLETE\") or endReason == \"FULL\"",
		to: "local consumeResults = (not planKind and endReason ~= \"INCOMPLETE\") or endReason == \"FULL\" or (planKind == \"EXACT\" and endReason == \"EARLY\")",
	},
	consume_unplanned_incomplete: {
		file: "SCAN_MANAGER_SRC",
		from: "local consumeResults = (not planKind and endReason ~= \"INCOMPLETE\") or endReason == \"FULL\"",
		to: "local consumeResults = not planKind or endReason == \"FULL\"",
	},
	double_consumer: {
		file: "SCAN_MANAGER_SRC",
		from: "\t\t\t\tself:_onQueryDoneHandler(query, numNewResults)\n",
		to: "\t\t\t\tself:_onQueryDoneHandler(query, numNewResults)\n\t\t\t\tself:_onQueryDoneHandler(query, numNewResults)\n",
	},
};

const mutationArgIndex = process.argv.indexOf("--mutation");
const activeMutationName = mutationArgIndex === -1 ? null : process.argv[mutationArgIndex + 1];
const activeMutation = activeMutationName && mutations[activeMutationName];
if (activeMutationName && !activeMutation) {
	fail(`Unknown mutation: ${activeMutationName}`);
}

function readUtf8(filePath) {
	let content = fs.readFileSync(filePath, "utf8");
	if (content.charCodeAt(0) === 0xfeff) {
		content = content.slice(1);
	}
	return content.replace(/\r\n?/g, "\n");
}

function applyMutation(globalName, content) {
	if (!activeMutation || activeMutation.file !== globalName) {
		return content;
	}
	const first = content.indexOf(activeMutation.from);
	const last = content.lastIndexOf(activeMutation.from);
	if (first === -1 || first !== last) {
		fail(`Mutation ${activeMutationName} expected one source match in ${globalName}, found ${first === -1 ? 0 : "multiple"}`);
	}
	return content.slice(0, first) + activeMutation.to + content.slice(first + activeMutation.from.length);
}

function fail(message) {
	console.error(message);
	process.exit(1);
}

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

for (const [globalName, filePath] of Object.entries(files)) {
	let content;
	try {
		content = applyMutation(globalName, readUtf8(filePath));
	} catch (e) {
		fail(`Cannot read ${filePath}: ${e.message}`);
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

doLua(`
	local chunk = assert(load(PLANNER_PRELUDE_SRC, "planner-prelude.lua"))
	TSM_PLANNER_CTX = assert(chunk())
`, "run-planner-prelude");

doLua(`
	local chunk = assert(load(QUERY_SRC, "Query.lua"))
	chunk(nil, TSM_PLANNER_CTX.addonTable)
`, "run-Query.lua");

doLua(`
	local chunk = assert(load(QUERY_UTIL_SRC, "QueryUtil.lua"))
	chunk(nil, TSM_PLANNER_CTX.addonTable)
`, "run-QueryUtil.lua");

doLua(`
	local chunk = assert(load(SCAN_MANAGER_SRC, "ScanManager.lua"))
	chunk(nil, TSM_PLANNER_CTX.addonTable)
`, "run-ScanManager.lua");

doLua(`
	local chunk = assert(load(PLANNER_TEST_SRC, "planner-test.lua"))
	chunk()
`, "run-planner-test.lua");

const failures = parseInt(doLua("return TSM_PLANNER_CTX.failures", "get-failures"), 10);
const passed = parseInt(doLua("return TSM_PLANNER_CTX.passed", "get-passed"), 10);
console.log(`Planner Lua tests: ${passed} passed, ${failures} failed`);
if (activeMutationName) {
	process.exit(failures > 0 ? 1 : 0);
}
if (failures > 0) {
	process.exit(1);
}

let survived = 0;
for (const mutationName of Object.keys(mutations)) {
	const result = childProcess.spawnSync(process.execPath, [__filename, "--mutation", mutationName], {
		encoding: "utf8",
	});
	const ranBehaviorSuite = result.stdout.includes("Planner Lua tests:");
	if (result.status === 1 && ranBehaviorSuite) {
		console.log(`MUTATION KILLED: ${mutationName}`);
	} else {
		survived++;
		console.error(`MUTATION SURVIVED/ERRORED: ${mutationName}`);
		if (result.stdout) {
			console.error(result.stdout.trim());
		}
		if (result.stderr) {
			console.error(result.stderr.trim());
		}
	}
}
console.log(`Planner mutations: ${Object.keys(mutations).length - survived} killed, ${survived} survived/errored`);
process.exit(survived > 0 ? 1 : 0);
