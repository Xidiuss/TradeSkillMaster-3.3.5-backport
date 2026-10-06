"""Exercise real error reporting and window code in host Lua 5.1 with WoW mocks."""
from pathlib import Path
from lupa.lua51 import LuaRuntime

root = Path(__file__).resolve().parents[2]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().TEST_OUTPUT = lambda name, ok, err: print(
    ("PASS: " if ok else "FAIL: ") + name + ("" if ok else ": " + err)
)
for name, path in (
    ("handler_source", "LibTSMService/Source/Debug/ErrorHandler.lua"),
    ("frame_source", "LibTSMUI/Source/Debug/ErrorFrame.lua"),
):
    lua.globals()[name] = (root / "TradeSkillMaster" / path).read_text(encoding="utf-8-sig")

lua.execute(r'''
gsub, gmatch, strmatch, strfind, strsub = string.gsub, string.gmatch, string.match, string.find, string.sub
format, tinsert, tremove, floor = string.format, table.insert, table.remove, math.floor
strtrim = function(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
strjoin = function(sep, ...) local t = {...}; for i=1,#t do t[i]=tostring(t[i]) end; return table.concat(t, sep) end
wipe = function(t) for k in pairs(t) do t[k]=nil end end
date = function() return '10/06/26 00:59:28' end
print = function() end
TSM_GLOBAL_DEBUG = true
local failures = 0
local function test(name, func)
    local ok, err = pcall(func)
    if not ok then failures=failures+1 end
    TEST_OUTPUT(name, ok, tostring(err))
end
local handler, registered, bugCallback = {}, nil, nil
BugGrabber = {RegisterCallback = function(_, _, callback) bugCallback=callback end}
local debugAPI = {SetErrorHandler = function(f) registered=f end, Stack=function() return '' end}
local modules = {
    ['Service.Event']={Register=function() end}, ['API.Addon']={GetNum=function() return 0 end},
    ['Util.ClientInfo']={GetBuildInfo=function() return '3.3.5',12340 end, GetLocale=function() return 'enUS' end, IsInCombat=function() return false end, IsRetail=function() return false end},
    ['Util.Debug']=debugAPI, Threading={GetDebugStr=function() return '' end}, Addons={Suites={}},
    ['Util.Log']={Err=function() end, Length=function() return 0 end},
    ['Lua.String']={Escape=function(s) return (s:gsub('(%W)','%%%1')) end}, ['Format.JSON']={},
    ['BaseType.TempTable']={GetDebugInfo=function() return {} end},
    ObjectPool={GetDebugInfo=function() return {} end},
}
local service = {}
function service:Init() return handler end
function service:From() return self end
function service:Include(name) return assert(modules[name],name) end
service.IncludeClassType=service.Include
service.GetTime=function() return 100 end
service.GetVersionStr=function() return 'v4.14.66' end
service.IsDevVersion=function() return false end
service.IsTestVersion=function() return false end
assert(loadstring(handler_source))(nil,{LibTSMService=service})
local private
for i=1,20 do
    local name,value=debug.getupvalue(registered,i)
    if name=='private' then private=value; break end
end
assert(private)
private.GetStackInfo=function(msg) return {{file='TSM/Callback.lua',line=1,func='callback',localsStr=''}},msg end
local report, errorInfo
handler.ConfigureUI(function(text,info) report,errorInfo=text,info end,function() end)
local function capture(message)
    private.isShown=false
    report=nil
    bugCallback('BugGrabber_BugGrabbed', {
        message=message, stack='Interface/AddOns/ElvUI/moveAnything.lua:31: in function <skin>',
        locals='frame = nil',
    })
    assert(report, 'error report not shown')
end
test('BugGrabber table message uses text',function()
    capture({'Interface/AddOns/ElvUI/moveAnything.lua:31: missing frame'})
    assert(report:find('missing frame',1,true),'message was replaced by table address')
end)
test('BugGrabber preserves original stack and locals',function()
    capture('Interface/AddOns/ElvUI/moveAnything.lua:31: missing frame')
    assert(report:find('moveAnything.lua:31: in function <skin>',1,true),'captured stack lost')
    assert(report:find('frame = nil',1,true),'captured locals lost')
    assert(not report:find('TSM/Callback.lua',1,true),'callback stack replaced original stack')
end)
test('direct string errors still report',function()
    private.isShown=false
    assert(registered('TradeSkillMaster/Test.lua:1: direct error'))
    assert(report:find('direct error',1,true))
end)
test('global debug off ignores unrelated BugGrabber errors',function()
    TSM_GLOBAL_DEBUG=false
    private.isShown=false
    report=nil
    bugCallback('BugGrabber_BugGrabbed',{message='ElvUI/moveAnything.lua:31: missing frame',stack='ElvUI/moveAnything.lua:31: in function <skin>'})
    assert(report==nil)
    TSM_GLOBAL_DEBUG=true
end)
test('global debug off still reports captured TSM errors',function()
    TSM_GLOBAL_DEBUG=false
    private.isShown=false
    report=nil
    bugCallback('BugGrabber_BugGrabbed', {
        message={message='TradeSkillMaster/Test.lua:1: captured TSM error'},
        stack='TradeSkillMaster/Test.lua:1: in function <test>',
    })
    assert(report and report:find('captured TSM error',1,true))
    TSM_GLOBAL_DEBUG=true
end)

local objects={}
local objectMT={__index=function(_, key)
    return function(self, ...)
        if key=='CreateFontString' or key=='CreateTexture' then return CreateFrame(key) end
        if key=='SetText' then self.text=(...) end
        if key=='SetScript' then local event,callback=...; self.scripts[event]=callback end
        if key=='GetWidth' then return 600 end
    end
end}
CreateFrame=function(kind)
    local obj=setmetatable({kind=kind,scripts={}},objectMT)
    objects[#objects+1]=obj
    return obj
end
RELOADUI=nil
CLOSE='Close'
local frameClass={__static={},__private={}}
local ui={}
function ui:DefineClassType() return frameClass end
function ui:From() return self end
function ui:Include(name)
    if name=='Debug.ErrorHandler' then return handler end
    return modules[name] or {}
end
ui.GetVersionStr=service.GetVersionStr
LibStub=function() return {} end
assert(loadstring(frame_source))(nil,{LibTSMUI=ui})
local instance={__closure=function() return function() end end}
frameClass.__private.__init(instance)
test('reload button has text without RELOADUI',function()
    assert(instance._frame.reloadBtn.text=='Reload UI','reload button blank')
end)
test('enUS window labels and copy action',function()
    local expected={['TSM Error Window (v4.14.66)']=false,['Show Full Error']=false,['Select All (Copy)']=false}
    for _,obj in ipairs(objects) do
        if expected[obj.text]~=nil then expected[obj.text]=true end
        assert(type(obj.text)~='string' or not obj.text:find('[\128-\255]'),'hardcoded non-English label')
    end
    for label,found in pairs(expected) do assert(found,'missing label: '..label) end
    local focused,highlighted=false,false
    instance._frame.editBox.SetFocus=function() focused=true end
    instance._frame.editBox.HighlightText=function() highlighted=true end
    instance._frame.selectBtn.scripts.OnClick()
    assert(focused and highlighted,'copy action did not select report')
end)
test('Show keeps English instructions',function()
    frameClass.Show(instance,'test error',{}, {}, false)
    assert(instance._frame.text.text:find('Ctrl+C',1,true))
    assert(not instance._frame.text.text:find('[\128-\255]'))
end)
assert(failures==0,tostring(failures)..' error-window tests failed')
''')
