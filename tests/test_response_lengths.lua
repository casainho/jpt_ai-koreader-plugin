local script_path = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("(.*/)") or ""
local real_require, real_dofile = require, dofile
local policy = dofile(script_path .. "../context_policy.lua")
local saved = { response_length = "long" }
local settings = {}
function settings:readSetting(key, default)
    if saved[key] ~= nil then return saved[key] end
    return default
end
function settings:saveSetting(key, value)
    if type(value) == "table" then
        local copy = {}
        for k, v in pairs(value) do copy[k] = v end
        value = copy
    end
    saved[key] = value
    return self
end
function settings:flush() return self end

-- Exercise the real composer callbacks and preference loading without a device
-- or access to the private provider configuration.
local widget = { sep_width = 1 }
function widget:extend(value) return setmetatable(value, { __index = self }) end
function widget:new(value)
    value = value or {}
    value._input_widget = { charpos = 1 }
    value.vgroup = {}
    return setmetatable(value, { __index = self })
end
function widget:getInputText() return "" end
function widget:getAddedWidgetAvailableWidth() return 900 end
function widget:addWidget(value)
    self.added = self.added or {}
    table.insert(self.added, value)
end
local shown
local modules = {
    context_policy = policy,
    gettext = function(text) return "localized:" .. text end,
    datastorage = { getSettingsDir = function() return "unused-test-settings" end },
    luasettings = { open = function() return settings end },
    device = { screen = {
        getWidth = function() return 1264 end,
        getHeight = function() return 1680 end,
    } },
    ["ui/uimanager"] = {
        show = function(_, dialog) shown = dialog end,
        close = function() end,
    },
    ["ui/size"] = { padding = { default = 1 }, margin = { default = 1 } },
}
require = function(name) return modules[name] or widget end
dofile = function(path)
    if path:match("jpt_ai_config%.lua$") then return {} end
    return real_dofile(path)
end
local Plugin = dofile(script_path .. "../main.lua")
local function instance()
    local obj = Plugin:new{ ui = { menu = { registerToMainMenu = function() end } } }
    obj.onDispatcherRegisterActions = function() end
    obj.registerAutomaticSelectionLaunch = function() end
    obj.registerDictionaryButton = function() end
    obj.getSelectedText = function() return nil end
    obj.sendQuestion = function(self, ...)
        self.request_length = select(10, ...)
    end
    obj:init()
    return obj
end
local function click(obj, index, expected)
    obj:openComposer(nil)
    shown.buttons[1][index].callback()
    assert(obj.request_length == expected, "incorrect length passed to request")
end

local obj = instance()
for _, action in ipairs({ "translate", "summarize", "explain", "meaning" }) do
    assert(obj.action_response_lengths[action] == "long", "migrate old preference")
end
obj:setResponseLength("short")
click(obj, 1, "short")
click(obj, 2, "long") -- No change: Summarize retains its own value.
obj:setResponseLength("very_long")
click(obj, 3, "very_long")
obj:setResponseLength("medium")
click(obj, 4, "medium")
click(obj, 1, "short")
click(obj, 3, "very_long")

obj = instance() -- Reload preferences as on a plugin restart.
click(obj, 1, "short")
click(obj, 2, "long")
click(obj, 3, "very_long")
click(obj, 4, "medium")
obj:setResponseLength("medium") -- Explicitly choosing the displayed value counts.
click(obj, 1, "medium")
click(obj, 2, "long")
obj:setResponseLength("short")
assert(obj:resolveResponseLength(nil) == "short", "custom question length")
click(obj, 4, "medium") -- A custom question does not overwrite action settings.
saved.action_response_lengths.explain = "invalid"
obj = instance()
assert(obj.action_response_lengths.explain == "short", "invalid preference fallback")
click(obj, 1, "medium")

-- Context selector callbacks, persistence, and the real extraction path.
obj:openComposer(nil)
shown.added[1].buttons[2][1].callback()
assert(shown.value_step == 2 and shown.value_max == 21, "restore primary picker")
assert(not shown.added, "primary has no checkbox")
shown.callback({ value = 5 })
assert(saved.primary_page_count == 5, "save original primary count")

for _, selection in ipairs({ false, true }) do
    obj.getSelectedText = function() return selection and "selected word" or nil end
    obj:openComposer(nil)
    local secondary_row = shown.added[2].buttons[2]
    assert(#secondary_row == 4, "secondary has None, Pages, Chapter, Book")
    secondary_row[2].callback()
    local picker = shown
    assert(picker.value_table == policy.secondaryPageCounts, "secondary power-of-two picker")
    assert(picker.added[1].text == "localized:Only previous pages", "secondary checkbox label")
    picker.added[1].checked = true
    picker.callback({ value = 8 })
    assert(saved.secondary_only_previous_pages == true, "persist checkbox")
    local key = selection and "selection_secondary_page_count" or "secondary_page_count"
    assert(saved[key] == 8, "persist secondary page count")
    obj.ui.document = {
        info = { has_pages = true, number_of_pages = 100 },
        getPageText = function(_, page) return "page " .. page end,
    }
    obj.ui.view = { state = { page = 50 } }
    local text = obj:getContext("pages", "nearby_pages", 5)
    assert(text:find("Secondary context: 43 - 50 (current page)", 1, true), "secondary previous-only range")
    if not selection then
        assert(text:find("Pages -- 48-52", 1, true), "primary stays centered")
    end
    picker.added[1].checked = false
    picker.callback({ value = 8 })
    text = obj:getContext("pages", "nearby_pages", 5)
    assert(text:find("Secondary context: 46 - 50 (current page) - 53", 1, true), "secondary centered range")
    obj.ui.view.state.page = 1
    text = obj:getContext("pages", "nearby_pages", 5)
    assert(text:find("Secondary context: 1 (current page) - 4", 1, true), "book start marker")
    obj.ui.view.state.page = 100
    local heading
    text, _, heading = obj:getContext("pages", "nearby_pages", 5)
    assert(heading:find("Secondary context: 96 - 100 (current page)", 1, true), "book end display marker")
    obj:setSecondaryPageCount(1, selection)
    text = obj:getContext("pages", "nearby_pages", 5)
    assert(text:find("Secondary context: 100 (current page)\n", 1, true), "single page marker")
    obj:setSecondaryPageCount(8, selection)
end
obj = instance()
assert(obj.secondary_only_previous_pages == false, "reload checkbox")
assert(obj.secondary_page_count == 8 and obj.selection_secondary_page_count == 8, "reload counts")
assert(obj.primary_page_count == 5, "reload original primary count")
saved.selection_secondary_context = "current_page"
obj = instance()
assert(obj.selection_secondary_context == "nearby_pages", "migrate old Page choice")
assert(obj.selection_secondary_page_count == 1, "old Page choice keeps one page")
assert(saved.selection_secondary_context == "nearby_pages", "persist migrated choice")
obj = instance()
assert(obj.selection_secondary_page_count == 1, "reload migrated one-page choice")

require, dofile = real_require, real_dofile
print("JPT AI action response-length tests passed (KOReader UI/settings stubs)")
