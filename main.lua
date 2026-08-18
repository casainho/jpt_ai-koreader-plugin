local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local ButtonTable = require("ui/widget/buttontable")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local SpinWidget = require("ui/widget/spinwidget")
local Font = require("ui/font")
local TitleBar = require("ui/widget/titlebar")
local Device = require("device")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local FileManagerConverter = require("apps/filemanager/filemanagerconverter")
local LuaSettings = require("luasettings")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local json = require("json")
local util = require("util")
local _ = require("gettext")
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")

local JPTAI = WidgetContainer:extend{ name = "jpt_ai", is_doc_only = true }

local response_lengths = {
    short = { label = _("Short"), max_tokens = 1024, instruction = "Keep the answer concise: one short paragraph or a compact list." },
    medium = { label = _("Medium"), max_tokens = 2500, instruction = "Give a well-developed answer with the relevant explanation and details." },
    long = { label = _("Long"), max_tokens = 7500, instruction = "Give a detailed, thorough answer. Develop the reasoning and include useful examples or structure when appropriate." },
    very_long = { label = _("Very long"), max_tokens = 12000, instruction = "Give a very detailed and comprehensive answer. Cover the relevant nuances, reasoning, and examples; do not unnecessarily abbreviate the response." },
}

-- InputDialog does not expose title-bar styling. Keep this scoped to the chat
-- dialog, including any later reinitialization caused by a screen rotation.
local CompactChatDialog = InputDialog:extend{}

function CompactChatDialog:init()
    local title_face_fullscreen = TitleBar.title_face_fullscreen
    local title_top_padding = TitleBar.title_top_padding
    local bottom_v_padding = TitleBar.bottom_v_padding
    TitleBar.title_face_fullscreen = Font:getFace("smalltfont", math.max(1, math.floor(title_face_fullscreen.orig_size * 0.66)))
    TitleBar.title_top_padding = 0
    TitleBar.bottom_v_padding = math.floor(title_face_fullscreen.orig_size * 0.17)
    InputDialog.init(self)
    TitleBar.title_face_fullscreen = title_face_fullscreen
    TitleBar.title_top_padding = title_top_padding
    TitleBar.bottom_v_padding = bottom_v_padding
end

local function pluginDirectory()
    return debug.getinfo(1, "S").source:sub(2):match("(.*/)")
end

local function trim(value)
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function htmlEscape(value)
    return value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function cssEscapeUrl(value)
    return value:gsub("\\", "\\\\"):gsub("'", "\\'")
end

-- KOReader's document APIs already return textual content. Normalize it once
-- so every context mode sends plain text, never book HTML or Markdown.
local function plainText(value)
    return value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\194\160", " "):gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n")
end

local function splitTableRow(line)
    line = trim(line):gsub("^|", ""):gsub("|$", "")
    local cells = {}
    for cell in (line .. "|"):gmatch("(.-)|") do table.insert(cells, trim(cell)) end
    return cells
end

local function isTableSeparator(line)
    if not line or not line:find("|", 1, true) then return false end
    local cells = splitTableRow(line)
    if #cells == 0 then return false end
    for _, cell in ipairs(cells) do
        if not cell:match("^:?-+:?$") then return false end
    end
    return true
end

-- Convert GitHub-style Markdown tables to HTML before KOReader handles normal Markdown.
local function renderMarkdown(markdown)
    local lines, output, tables = {}, {}, {}
    for line in (markdown .. "\n"):gmatch("(.-)\n") do
        local normalized = line:gsub("\r$", "")
        table.insert(lines, normalized)
    end
    local i = 1
    while i <= #lines do
        if lines[i]:find("|", 1, true) and isTableSeparator(lines[i + 1]) then
            local headers, rows = splitTableRow(lines[i]), {}
            i = i + 2
            while i <= #lines and lines[i]:find("|", 1, true) and trim(lines[i]) ~= "" do
                table.insert(rows, splitTableRow(lines[i]))
                i = i + 1
            end
            local html = { "<table><thead><tr>" }
            for _, cell in ipairs(headers) do table.insert(html, "<th>" .. htmlEscape(cell) .. "</th>") end
            table.insert(html, "</tr></thead><tbody>")
            for _, row in ipairs(rows) do
                table.insert(html, "<tr>")
                for column = 1, #headers do table.insert(html, "<td>" .. htmlEscape(row[column] or "") .. "</td>") end
                table.insert(html, "</tr>")
            end
            table.insert(html, "</tbody></table>")
            local token = "@@JPT_TABLE_" .. tostring(#tables + 1) .. "@@"
            table.insert(tables, { token = token, html = table.concat(html) })
            table.insert(output, token)
        else
            table.insert(output, lines[i])
            i = i + 1
        end
    end
    local html = FileManagerConverter:mdToHtml(table.concat(output, "\n"), "")
    for _, data in ipairs(tables) do html = html:gsub("<p>%s*" .. data.token .. "%s*</p>", data.html) end
    return html
end

local function extractPdfText(document, first_page, last_page)
    local parts = {}
    for page = first_page, last_page do
        local text = document:getPageText(page) or ""
        if type(text) == "table" then
            local words = {}
            for _, block in ipairs(text) do
                for _, span in ipairs(block) do if type(span) == "table" and span.word then table.insert(words, span.word) end end
            end
            text = table.concat(words, " ")
        end
        table.insert(parts, text)
    end
    return table.concat(parts, "\n")
end

function JPTAI:init()
    self.path = pluginDirectory()
    local ok, config = pcall(dofile, self.path .. "jpt_ai_config.lua")
    self.config = ok and config or {}
    self.question_history_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/jpt_ai.lua")
    self.font_multiplier = tonumber(self.question_history_settings:readSetting("font_multiplier", 1.0)) or 1.0
    self.translation_language = self.question_history_settings:readSetting("translation_language", "Portuguese (Portugal)")
    self.response_length = self.question_history_settings:readSetting("response_length", "medium")
    if not response_lengths[self.response_length] then self.response_length = "medium" end
    self.primary_context = self.question_history_settings:readSetting("primary_context", "pages")
    self.secondary_context = self.question_history_settings:readSetting("secondary_context", "chapter")
    local legacy_radius = self.question_history_settings:readSetting("page_radius", 1)
    self.primary_page_count = math.max(1, tonumber(self.question_history_settings:readSetting("primary_page_count", 1)) or 1)
    self.secondary_page_radius = math.max(0, tonumber(self.question_history_settings:readSetting("secondary_page_radius", legacy_radius)) or 1)
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:registerDictionaryButton()
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("08a_jpt_ai", function(this)
            return {
                text = "JPT AI",
                callback = function()
                    local selected = util.cleanupSelectedText(this.selected_text.text)
                    local selected_chars = util.splitToChars(selected)
                    this:onClose()
                    self.pending_selected_text = selected
                    self:openComposer("minimum", nil, nil, nil, selected .. "\n\n", #selected_chars + 2)
                end,
            }
        end)
    end
end

-- A normal long press on a single word opens KOReader's dictionary directly,
-- bypassing the multi-word highlight menu. Add an action there as well.
function JPTAI:registerDictionaryButton()
    if not (self.ui and self.ui.dictionary) then return end
    self.ui.dictionary:addToDictButtons({
        id = "jpt_ai",
        text = "JPT AI",
        conditional = true,
        callback = function(dict_popup)
            local selected = util.cleanupSelectedText(dict_popup.lookupword or dict_popup.word or "")
            if not selected:match("%S") then return end
            dict_popup:onClose()
            self.pending_selected_text = selected
            local selected_chars = util.splitToChars(selected)
            self:openComposer("minimum", nil, nil, nil, selected .. "\n\n", #selected_chars + 2)
        end,
    })
end

function JPTAI:onDispatcherRegisterActions()
    Dispatcher:registerAction("jpt_ai_open", { category = "none", event = "JPTAIOpen", title = _("Open JPT AI"), reader = true })
end

function JPTAI:onJPTAIOpen()
    self:ask("minimum", self:getSelectedText())
end

function JPTAI:addToMainMenu(menu_items)
    menu_items.jpt_ai = {
        text = _("JPT AI"), sorting_hint = "more_tools",
        sub_item_table = {
            { text = _("Ask (minimum context)"), callback = function() self:ask("minimum") end },
            { text = _("Ask (medium context)"), callback = function() self:ask("medium") end },
            { text = _("Ask (maximum context: complete book)"), callback = function() self:ask("maximum") end },
        },
    }
end

function JPTAI:getSelectedText()
    if self.pending_selected_text and self.pending_selected_text:match("%S") then return self.pending_selected_text end
    local selection = self.ui and self.ui.highlight and self.ui.highlight.selected_text
    return selection and selection.text and selection.text:match("%S") and selection.text or nil
end

function JPTAI:getBookTitle()
    local props = self.ui and self.ui.doc_props
    local title = props and (props.display_title or props.title)
    if title and title:match("%S") then return title end
    local file = self.ui and self.ui.document and self.ui.document.file
    return file and ((file:match("([^/]+)$") or file):gsub("%.[^%.]+$", "")) or _("Book")
end

-- The chat uses MuPDF HTML while EPUBs use CRengine, so their typesetting
-- settings cannot be shared directly. Mirror every setting that has an HTML
-- equivalent and load the same font files when CRengine can identify them.
function JPTAI:getBookTextStyle(font_multiplier)
    local configurable = self.ui and self.ui.document and self.ui.document.configurable or {}
    local font_size = (tonumber(configurable.font_size) or 33) * (font_multiplier or 1)
    local line_height = (tonumber(configurable.line_spacing) or 130) / 100
    local word_scaling = type(configurable.word_spacing) == "table" and tonumber(configurable.word_spacing[1]) or 100
    local word_spacing = (word_scaling - 100) / 400
    local css = string.format("@page { margin: 0; } body { margin: 8px 0 0 0; line-height: %.2f; word-spacing: %.3fem; font-weight: normal; } p { margin: 0 0 0.7em 0; } hr { margin: 0; padding: 0; } .jpt-context { font-size: 80%%; margin: 0; padding: 0; text-align: left; } table { border-collapse: collapse; } th { font-weight: bold; }", line_height, word_spacing)
    local font_name = self.ui and self.ui.font and self.ui.font.font_face
    if not font_name or font_name == "" then return css, Device.screen:scaleBySize(font_size) end

    local ok, font_css = pcall(function()
        local cre = require("document/credocument"):engineInit()
        local seen_paths, rules = {}, {}
        for index = 1, 2 do
            local bold = index == 2
            local font_path = cre.getFontFaceFilenameAndFaceIndex(font_name, bold, false)
            if font_path and not seen_paths[font_path] then
                seen_paths[font_path] = true
                table.insert(rules, string.format("@font-face { font-family: 'JPTBookFont'; src: url('%s'); font-weight: %s; }", cssEscapeUrl(font_path), bold and "bold" or "normal"))
            end
        end
        if #rules > 0 then
            table.insert(rules, "body { font-family: 'JPTBookFont'; }")
            return table.concat(rules, "\n")
        end
    end)
    if ok and font_css then css = font_css .. "\n" .. css end
    return css, Device.screen:scaleBySize(font_size)
end

function JPTAI:loadConnection()
    if not self.config.base_url or self.config.base_url == "" or not self.config.api_key or self.config.api_key == "" then
        return nil, _("JPT AI has no usable endpoint or API key.")
    end
    return { base_url = self.config.base_url, api_key = self.config.api_key, model = self.config.model }
end

function JPTAI:formatRequestError(code, body, request_ok)
    local original = body and (body:match('"message"%s*:%s*"(.-)"') or body:match('"error"%s*:%s*"(.-)"'))
    original = original or (code and tostring(code)) or (request_ok and tostring(request_ok)) or "unknown error"
    local status = tonumber(code)
    local explanations = {
        [400] = _("The request was rejected. Check the endpoint, model, and request settings."),
        [401] = _("Authentication failed. Check the API key in jpt_ai_config.lua."),
        [403] = _("The API key does not have permission to use this endpoint or model."),
        [404] = _("The endpoint or model was not found. Check jpt_ai_config.lua."),
        [408] = _("The AI server took too long to answer. Try again or use less context."),
        [413] = _("The selected context is too large for the server. Use a page, chapter, or less nearby context."),
        [422] = _("The server could not process this request. Check the model and request settings."),
        [429] = _("Too many requests. Wait a moment and try again."),
        [500] = _("The AI server had an internal error. Try again later."),
        [502] = _("The AI service is temporarily unavailable. Try again later."),
        [503] = _("The AI service is temporarily unavailable. Try again later."),
        [504] = _("The AI service timed out. Try again or use less context."),
    }
    local explanation = explanations[status]
    if not explanation and status and status >= 500 then
        explanation = _("The AI service is unavailable. Try again later.")
    end
    if not explanation then
        local lower_original = original:lower()
        if lower_original:find("wantread", 1, true) then
            explanation = _("The secure connection is still waiting for the AI service. Keep Wi-Fi connected and try again.")
        elseif lower_original:find("timeout", 1, true) then
            explanation = _("The network request timed out. Check the connection and try again.")
        elseif lower_original:find("certificate", 1, true) or lower_original:find("ssl", 1, true) then
            explanation = _("A secure connection could not be established. Check the endpoint URL and device time.")
        else
            explanation = _("The request failed. Check the connection and your AI configuration.")
        end
    end
    return explanation .. "\n\n" .. _("Original error: ") .. original
end

function JPTAI:getDocument()
    local document = self.ui and self.ui.document
    local pages = document and document.info and document.info.number_of_pages
    if not pages or pages < 1 then return nil, _("Open a book before using JPT AI.") end
    return document, pages
end

function JPTAI:getContext(primary_mode, secondary_mode)
    local selected = self:getSelectedText()
    local document, total = self:getDocument()
    if not document then return nil, total end
    local ok, text, label, response_heading = pcall(function()
        local function getPageRange(first, last)
            if first > last then return "" end
            if document.info.has_pages then return extractPdfText(document, first, last) end
            return document:getTextFromXPointers(document:getPageXPointer(first), document:getPageXPointer(math.min(last + 1, total))) or ""
        end
        local current = document.info.has_pages and (self.ui.view and self.ui.view.state.page or 1) or document:getPageFromXPointer(document:getXPointer())
        local function contextPart(mode, radius, is_secondary)
            if mode == "book" then
                local heading = "[Context: Complete book]"
                if document.info.has_pages then return heading, extractPdfText(document, 1, total) end
                local original = document:getXPointer()
                document:gotoPos(0); local first = document:getXPointer()
                document:gotoPage(total); local last = document:getXPointer()
                if original then document:gotoXPointer(original) end
                return heading, document:getTextFromXPointers(first, last) or ""
            end
            if mode == "chapter" then
            local toc = self.ui and self.ui.toc
            local chapter_error = _("KOReader could not identify the current chapter. Choose Page or Book instead.")
            if not toc then return nil, nil, chapter_error end
            local title_ok, chapter_title = pcall(toc.getTocTitleByPage, toc, current)
            if not title_ok or type(chapter_title) ~= "string" or not chapter_title:match("%S") then return nil, nil, chapter_error end
            local start_ok, is_start = pcall(toc.isChapterStart, toc, current)
            if not start_ok then return nil, nil, chapter_error end
            local first = current
            if not is_start then
                local previous_ok, previous = pcall(toc.getPreviousChapter, toc, current)
                if not previous_ok then return nil, nil, chapter_error end
                first = previous
            end
            if not first then return nil, nil, chapter_error end
            local next_ok, next_chapter = pcall(toc.getNextChapter, toc, current)
            if not next_ok then return nil, nil, chapter_error end
            local last = math.min(total, (next_chapter or (total + 1)) - 1)
                local heading = "[Context: Chapter -- " .. chapter_title .. "]\n[Pages — " .. string.format("%d-%d", first, last) .. "]"
                if document.info.has_pages then return heading, extractPdfText(document, first, last) end
                return heading, document:getTextFromXPointers(document:getPageXPointer(first), document:getPageXPointer(math.min(last + 1, total))) or ""
            end
            radius = radius or 1
            if is_secondary and primary_mode == "pages" and not (selected and selected:match("%S")) then
                local primary_radius = math.floor((self.primary_page_count - 1) / 2)
                local before = getPageRange(math.max(1, current - primary_radius - radius), current - primary_radius - 1)
                local after = getPageRange(current + primary_radius + 1, math.min(total, current + primary_radius + radius))
                local additional = before ~= "" and after ~= "" and (before .. "\n\n" .. after) or (before ~= "" and before or after)
                return "[Context: Additional pages -- " .. math.max(1, current - primary_radius - radius) .. "-" .. math.min(total, current + primary_radius + radius) .. "]", additional
            end
            local first, last = math.max(1, current - radius), math.min(total, current + radius)
            return "[Context: Pages -- " .. first .. "-" .. last .. "]", getPageRange(first, last)
        end
        local primary_heading, primary_text, primary_error
        if selected and selected:match("%S") then primary_heading, primary_text = "[Context: Selected text]", selected else primary_heading, primary_text, primary_error = contextPart(primary_mode, math.floor((self.primary_page_count - 1) / 2), false) end
        if primary_error then return nil, primary_error end
        local secondary_heading, secondary_text, secondary_error
        if primary_mode ~= "book" and secondary_mode and secondary_mode ~= "none" then
            secondary_heading, secondary_text, secondary_error = contextPart(secondary_mode, self.secondary_page_radius, true)
            if secondary_error then return nil, secondary_error end
        end
        local function contextLine(kind, heading)
            local title = heading:match("^%[Context:%s*(.-)%]") or heading
            return kind .. ": " .. title
        end
        local main_line = contextLine("Main context", primary_heading)
        local context = main_line .. "\n\n" .. primary_text
        local secondary_line
        if secondary_heading and secondary_text and secondary_text ~= "" then
            secondary_line = contextLine("Secondary context", secondary_heading)
            context = context .. "\n\n" .. secondary_line .. "\n\n" .. secondary_text
        end
        local response_heading = '<div class="jpt-context">' .. htmlEscape(main_line)
        if secondary_line then response_heading = response_heading .. "<br/>" .. htmlEscape(secondary_line) end
        return context, "primary and secondary context", response_heading .. "</div>"
    end)
    text = ok and text and plainText(text) or text
    if not text or text == "" then return nil, _("KOReader could not extract text from this book.") end
    return text, label, response_heading
end

function JPTAI:setFontMultiplier(value)
    self.font_multiplier = value
    self.question_history_settings:saveSetting("font_multiplier", value):flush()
end

function JPTAI:setTranslationLanguage(language)
    self.translation_language = trim(language)
    self.question_history_settings:saveSetting("translation_language", self.translation_language):flush()
end

function JPTAI:setResponseLength(length)
    if not response_lengths[length] then return end
    self.response_length = length
    self.question_history_settings:saveSetting("response_length", length):flush()
end

function JPTAI:setContext(kind, mode)
    self[kind .. "_context"] = mode
    self.question_history_settings:saveSetting(kind .. "_context", mode):flush()
end

function JPTAI:setPageRadius(kind, value)
    if kind == "primary" then
        self.primary_page_count = math.max(1, math.floor(tonumber(value) or 1))
        self.question_history_settings:saveSetting("primary_page_count", self.primary_page_count):flush()
        return
    end
    self[kind .. "_page_radius"] = math.max(kind == "secondary" and 0 or 1, math.floor(tonumber(value) or 1))
    self.question_history_settings:saveSetting(kind .. "_page_radius", self[kind .. "_page_radius"]):flush()
end

function JPTAI:openTranslationLanguage(resume_composer)
    local dialog
    local function resume()
        UIManager:close(dialog)
        UIManager:nextTick(resume_composer)
    end
    dialog = InputDialog:new{
        title = _("Translation language"),
        input = self.translation_language,
        input_hint = _("For example: Portuguese (Portugal)"),
        buttons = {{
            { text = _("Close"), callback = resume },
            { text = _("Save"), is_enter_default = true, callback = function()
                local language = trim(dialog:getInputText())
                if language ~= "" then self:setTranslationLanguage(language) end
                resume()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function JPTAI:openResponseLengthOptions(resume_composer)
    local selector
    local function resume()
        UIManager:close(selector)
        UIManager:nextTick(resume_composer)
    end
    local function choose(length)
        self:setResponseLength(length)
        resume()
    end
    selector = ButtonDialog:new{
        title = _("Response length"),
        use_info_style = false,
        tap_close_callback = function() UIManager:nextTick(resume_composer) end,
        buttons = {
            {
                { text = self.response_length == "short" and "✓ " .. _("Short") or _("Short"), callback = function() choose("short") end },
                { text = self.response_length == "medium" and "✓ " .. _("Medium") or _("Medium"), callback = function() choose("medium") end },
            },
            {
                { text = self.response_length == "long" and "✓ " .. _("Long") or _("Long"), callback = function() choose("long") end },
                { text = self.response_length == "very_long" and "✓ " .. _("Very long") or _("Very long"), callback = function() choose("very_long") end },
            },
            {{ text = _("Close"), font_bold = false, callback = resume }},
        },
    }
    UIManager:show(selector)
end

function JPTAI:openComposerOptions(resume_composer)
    local options
    local function resume()
        UIManager:close(options)
        UIManager:nextTick(resume_composer)
    end
    options = ButtonDialog:new{
        title = _("Options"),
        use_info_style = false,
        tap_close_callback = function() UIManager:nextTick(resume_composer) end,
        buttons = {
            {
                { text = string.format(_("Font size: %.1fx"), self.font_multiplier), font_bold = false, callback = function()
                    UIManager:show(SpinWidget:new{
                        title_text = _("Font size multiplier"),
                        info_text = _("Relative to the book's font size."),
                        value = self.font_multiplier, value_min = 0.1, value_max = 2.0, value_step = 0.1, value_hold_step = 0.1, precision = "%.1f×",
                        callback = function(spin)
                            self:setFontMultiplier(spin.value)
                            resume()
                        end,
                    })
                end },
            },
            {
                { text = _("Translation language"), font_bold = false, callback = function()
                    UIManager:close(options)
                    self:openTranslationLanguage(resume_composer)
                end },
            },
            {
                { text = _("Response length") .. ": " .. response_lengths[self.response_length].label, font_bold = false, callback = function()
                    UIManager:close(options)
                    self:openResponseLengthOptions(resume_composer)
                end },
            },
            {{ text = _("Close"), font_bold = false, callback = resume }},
        },
    }
    UIManager:show(options)
end

function JPTAI:openComposer(mode, response, question, chat_dialog, input_text, cursor_charpos, secondary_mode)
    local composer
    local default_button_sep_width = ButtonTable.sep_width
    local selected_mode = mode == "chapter" and "chapter" or (mode == "maximum" or mode == "book") and "book" or self.primary_context
    local selected_secondary = secondary_mode or self.secondary_context
    local function submitQuestion(asked)
        UIManager:close(composer)
        if asked and asked:match("%S") then
            local selected = self:getSelectedText()
            local display_question = asked
            if selected and selected:match("%S") then
                display_question = selected .. "\n\n" .. asked
            end
            local waiting = self:openChat(selected_mode, _("(Preparing answer… )"), display_question, chat_dialog, true, "", selected_secondary)
            self:sendQuestion(asked, selected_mode, waiting, selected_secondary, display_question)
        end
    end
    ButtonTable.sep_width = default_button_sep_width * 2
    composer = InputDialog:new{
        title = _("JPT AI question"), input = input_text or (chat_dialog and chat_dialog:getInputText()) or "", input_hint = _("Write your question here"),
        width = math.floor(Device.screen:getWidth() * 0.90), text_height = math.floor(Device.screen:getHeight() * 0.15),
        condensed = true, allow_newline = true,
        buttons = {
            {
                { text = _("Explain"), callback = function() submitQuestion("Explain the text clearly and concisely.") end },
                { text = _("Summarize"), callback = function() submitQuestion("Summarize the selected text, preserving the main ideas and important details.") end },
                { text = _("Translate"), callback = function() submitQuestion("Translate the selected text into " .. self.translation_language .. ", preserving its meaning and tone.") end },
            },
            {
                { text = _("Close"), callback = function()
                    self.pending_selected_text = nil
                    UIManager:close(composer)
                end },
                { text = _("Options"), width = math.floor(Device.screen:getWidth() * 0.90 / 6), callback = function()
                    local draft = composer:getInputText()
                    local cursor = composer._input_widget.charpos
                    UIManager:close(composer)
                    self:openComposerOptions(function()
                        self:openComposer(selected_mode, response, question, chat_dialog, draft, cursor, selected_secondary)
                    end)
                end },
                { text = _("Ask"), is_enter_default = true, callback = function()
                    submitQuestion(composer:getInputText())
                end },
            },
        },
    }
    ButtonTable.sep_width = default_button_sep_width
    if cursor_charpos then
        composer._input_widget.charpos = cursor_charpos
        composer._input_widget:initTextBox(composer._input_widget.text)
    end
    local function addContextButtons(kind, title)
        local current = self[kind .. "_context"]
        local radius = kind == "primary" and self.primary_page_count or self.secondary_page_radius
        local secondary_disabled = kind == "secondary" and self.primary_context == "book"
        local chapter_disabled = secondary_disabled or (kind == "secondary" and self.primary_context == "chapter")
        local pages_disabled = secondary_disabled or (kind == "secondary" and self.primary_context == "chapter")
        composer:addWidget(ButtonTable:new{ width = composer:getAddedWidgetAvailableWidth(), buttons = {{
            { text = title, align = "left", font_bold = true, callback = function() end },
        }, {
            { text = (current == "pages" and "✓ " or "") .. (kind == "primary" and "Pages (" or "± Pages (") .. radius .. ")", enabled = not pages_disabled, callback = function()
                local draft, cursor = composer:getInputText(), composer._input_widget.charpos
                if kind == "secondary" and current == "pages" then
                    self:setContext(kind, "none")
                    UIManager:close(composer)
                    self:openComposer(nil, response, question, chat_dialog, draft, cursor)
                    return
                end
                self:setContext(kind, "pages")
                UIManager:close(composer)
                UIManager:show(SpinWidget:new{
                    title_text = kind == "primary" and _("Pages in the primary context") or _("Additional pages on each side"),
                    info_text = kind == "primary" and _("Choose an odd total: 1, 3, 5, and so on.") or _("Pages included before and after the current page."),
                    value = radius, value_min = kind == "primary" and 1 or 0, value_max = kind == "primary" and 21 or 20, value_step = kind == "primary" and 2 or 1, value_hold_step = kind == "primary" and 2 or 1, precision = "%d",
                    callback = function(spin)
                        self:setPageRadius(kind, spin.value)
                    end,
                    close_callback = function()
                        self:openComposer(nil, response, question, chat_dialog, draft, cursor)
                    end,
                })
            end },
            { text = current == "chapter" and "✓ Chapter" or "Chapter", enabled = not chapter_disabled, callback = function() self:setContext(kind, kind == "secondary" and current == "chapter" and "none" or "chapter"); UIManager:close(composer); self:openComposer(nil, response, question, chat_dialog, composer:getInputText(), composer._input_widget.charpos) end },
            { text = current == "book" and "✓ Book" or "Book", enabled = not secondary_disabled, callback = function() self:setContext(kind, kind == "secondary" and current == "book" and "none" or "book"); UIManager:close(composer); self:openComposer(nil, response, question, chat_dialog, composer:getInputText(), composer._input_widget.charpos) end },
        }}, sep_width = default_button_sep_width * 2, zero_sep = true, show_parent = composer })
    end
    addContextButtons("primary", _("PRIMARY CONTEXT"))
    addContextButtons("secondary", _("SECONDARY CONTEXT"))
    UIManager:show(composer)
    composer:onShowKeyboard()
end

function JPTAI:openChat(mode, response, question, previous_dialog, input_hidden, input_text, nearby_pages)
    if previous_dialog then UIManager:close(previous_dialog) end
    input_hidden = true
    if type(response) ~= "string" then response = tostring(response or "") end
    if type(question) ~= "string" then question = nil end
    local screen, dialog = Device.screen, nil
    local width = math.floor(screen:getWidth() * 0.94)
    local markdown = question and ("**Question:**  \n" .. question .. "\n\n---\n" .. response) or response
    local css, font_size = self:getBookTextStyle(self.font_multiplier)
    -- A malformed Markdown response must not close KOReader while the answer
    -- dialog is being built. Fall back to escaped plain text in that case.
    local rendered_ok, html_body = pcall(renderMarkdown, markdown)
    if not rendered_ok or type(html_body) ~= "string" then
        logger.warn("JPT AI could not render the response as Markdown:", tostring(html_body))
        html_body = "<pre>" .. htmlEscape(markdown) .. "</pre>"
    end
    dialog = CompactChatDialog:new{
        title = "JPT AI - " .. self:getBookTitle(), input = input_text or "", input_hint = _("Write your question here"),
        fullscreen = true, condensed = true, allow_newline = true, keyboard_visible = false,
        buttons = {{
            { text = _("Close"), width = math.floor(width / 2), callback = function() UIManager:close(dialog) end },
            { text = _("Ask"), width = math.floor(width / 2), callback = function() self:openComposer("page", response, question, dialog, nil, nil, nearby_pages) end },
        }},
    }
    local output = ScrollHtmlWidget:new{
        html_body = html_body, width = width,
        height = screen:getHeight() - dialog.title_bar:getSize().h - dialog.button_table:getSize().h,
        dialog = nil, default_font_size = font_size, css = css,
    }
    dialog[1] = FrameContainer:new{
        width = screen:getWidth(), height = screen:getHeight(),
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        TopContainer:new{
            dimen = Geom:new{ w = screen:getWidth(), h = screen:getHeight() },
            dialog.dialog_frame,
        },
    }
    output.dialog = dialog
    dialog:addWidget(output)
    local output_row = dialog._added_widgets and dialog._added_widgets[1]
    for index, widget in ipairs(dialog.vgroup) do
        if widget == output_row then table.remove(dialog.vgroup, index); table.insert(dialog.vgroup, 2, output_row); break end
    end
    if input_hidden then table.remove(dialog.vgroup, 5); table.remove(dialog.vgroup, 4); table.remove(dialog.vgroup, 3) end
    dialog.onSwitchFocus = function()
        if not input_hidden then UIManager:nextTick(function() self:openComposer("page", response, question, dialog, nil, nil, nearby_pages) end) end
    end
    -- The dialog is fullscreen, but InputDialog normally asks KOReader to
    -- refresh only its content-sized frame. Force a complete e-ink repaint so
    -- no pixels from the preceding window remain at the top of the screen.
    dialog.onShow = function()
        Device.screen:clear()
        UIManager:setDirty("all", "full")
    end
    UIManager:show(dialog, "full")
    if not input_hidden then dialog:lockKeyboard(true) end
    return dialog
end

function JPTAI:sendQuestion(question, mode, chat_dialog, nearby_pages, display_question)
    display_question = display_question or question
    local connection, error_message = self:loadConnection()
    if not connection then self:openChat(mode, error_message, display_question, chat_dialog, nil, nil, nearby_pages); return end
    local context, label, response_heading = self:getContext(mode, nearby_pages)
    self.pending_selected_text = nil
    if not context then self:openChat(mode, label, display_question, chat_dialog, nil, nil, nearby_pages); return end
    UIManager:nextTick(function()
        local response_length = response_lengths[self.response_length] or response_lengths.medium
        local configured_max_tokens = tonumber(self.config.max_output_tokens) or 12000
        https.TIMEOUT = math.max(60, tonumber(self.config.request_timeout) or 180)
        local payload = json.encode({ model = connection.model, temperature = self.config.temperature or 0.2, max_tokens = math.min(configured_max_tokens, response_length.max_tokens), reasoning_effort = self.config.reasoning_effort or "low",
            messages = {{ role = "system", content = "Answer in the same language as the question. Base your answer strictly on the supplied book context. " .. response_length.instruction }, { role = "user", content = "BOOK CONTEXT (" .. label .. ") — PLAIN TEXT:\n" .. context .. "\n\nQUESTION:\n" .. question }} })
        local response = {}
        local call_ok, request_ok, code = pcall(function() return https.request{ url = connection.base_url, method = "POST", headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. connection.api_key, ["Content-Length"] = tostring(#payload) }, source = ltn12.source.string(payload), sink = ltn12.sink.table(response) } end)
        local body = table.concat(response)
        if not call_ok or not request_ok or tonumber(code) ~= 200 then
            logger.warn("JPT AI request failed:", tostring(code))
            self:openChat(mode, self:formatRequestError(code, body, request_ok), display_question, chat_dialog, nil, nil, nearby_pages)
            return
        end
        local ok, decoded = pcall(json.decode, body)
        local answer = ok and decoded and decoded.choices and decoded.choices[1] and decoded.choices[1].message and decoded.choices[1].message.content
        answer = answer or _("JPT AI received no readable response.")
        if response_heading then answer = response_heading .. "\n\n" .. answer end
        self:openChat(mode, answer, display_question, chat_dialog, nil, nil, nearby_pages)
    end)
end

function JPTAI:ask(mode, selected_text)
    self.pending_selected_text = selected_text
    self:openComposer(mode, nil, nil, nil, "")
end

return JPTAI
