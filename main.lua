local WidgetContainer = require("ui/widget/container/widgetcontainer")
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

local JPTAI = WidgetContainer:extend{ name = "jpt_ai", is_doc_only = true }

-- InputDialog does not expose title-bar styling. Keep this scoped to the chat
-- dialog, including any later reinitialization caused by a screen rotation.
local CompactChatDialog = InputDialog:extend{}

function CompactChatDialog:init()
    local title_face_fullscreen = TitleBar.title_face_fullscreen
    local bottom_v_padding = TitleBar.bottom_v_padding
    TitleBar.title_face_fullscreen = Font:getFace("smalltfont", math.max(1, math.floor(title_face_fullscreen.orig_size * 0.66)))
    TitleBar.bottom_v_padding = math.floor(title_face_fullscreen.orig_size * 0.17)
    InputDialog.init(self)
    TitleBar.title_face_fullscreen = title_face_fullscreen
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
    local ok, config = pcall(dofile, self.path .. "jpt_config.lua")
    self.config = ok and config or {}
    self.question_history_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/jpt_ai.lua")
    self.question_history = self.question_history_settings:readSetting("question_history", {})
    self.font_multiplier = tonumber(self.question_history_settings:readSetting("font_multiplier", 1.0)) or 1.0
    self.translation_language = self.question_history_settings:readSetting("translation_language", "Portuguese (Portugal)")
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
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
    -- MuPDF maps any CSS weight over 400 to the full bold face, unlike
    -- CRengine's gradual font-weight control. Keep body text regular to avoid
    -- making answers noticeably heavier than the book text.
    local css = string.format("@page { margin: 0; } body { margin: 8px 0 0 0; line-height: %.2f; word-spacing: %.3fem; font-weight: normal; } p { margin: 0 0 0.7em 0; } table { border-collapse: collapse; } th { font-weight: bold; }", line_height, word_spacing)
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
        [401] = _("Authentication failed. Check the API key in jpt_config.lua."),
        [403] = _("The API key does not have permission to use this endpoint or model."),
        [404] = _("The endpoint or model was not found. Check jpt_config.lua."),
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
        if lower_original:find("timeout", 1, true) then
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

function JPTAI:getContext(mode, nearby_pages)
    local selected = self:getSelectedText()
    if selected and (mode == "minimum" or mode == "medium") then return selected, "selected text" end
    local document, total = self:getDocument()
    if not document then return nil, total end
    local ok, text, label = pcall(function()
        local function getPageRange(first, last)
            if first > last then return "" end
            if document.info.has_pages then return extractPdfText(document, first, last) end
            return document:getTextFromXPointers(document:getPageXPointer(first), document:getPageXPointer(math.min(last + 1, total))) or ""
        end
        local function combine(primary_label, primary_text, secondary_label, secondary_text)
            if not secondary_text or secondary_text == "" then return primary_text, primary_label end
            return "[PRIMARY CONTEXT — " .. primary_label .. "]\n" .. primary_text
                .. "\n\n[SECONDARY CONTEXT — " .. secondary_label .. "]\n" .. secondary_text,
                primary_label .. " with " .. secondary_label
        end
        if mode == "maximum" or mode == "book" then
            if document.info.has_pages then return extractPdfText(document, 1, total), "complete book" end
            local original = document:getXPointer()
            document:gotoPos(0); local first = document:getXPointer()
            document:gotoPage(total); local last = document:getXPointer()
            if original then document:gotoXPointer(original) end
            return document:getTextFromXPointers(first, last) or "", "complete book"
        end
        local current = document.info.has_pages and (self.ui.view and self.ui.view.state.page or 1) or document:getPageFromXPointer(document:getXPointer())
        if mode == "chapter" then
            local toc = self.ui and self.ui.toc
            local first = toc and (toc:isChapterStart(current) and current or toc:getPreviousChapter(current)) or 1
            local next_chapter = toc and toc:getNextChapter(current)
            local last = math.min(total, (next_chapter or (total + 1)) - 1)
            if document.info.has_pages then return extractPdfText(document, first, last), "current chapter" end
            return document:getTextFromXPointers(document:getPageXPointer(first), document:getPageXPointer(math.min(last + 1, total))) or "", "current chapter"
        end
        local radius = nearby_pages or (mode == "minimum" and 2 or 5)
        local first, last = math.max(1, current - radius), math.min(total, current + radius)
        if mode == "selected" then
            if not selected then return nil, _("Select text before choosing the selected-text context.") end
            return combine("selected text", selected, string.format("nearby pages (%d-%d)", first, last), getPageRange(first, last))
        end
        if mode == "page" then
            local secondary = getPageRange(first, current - 1)
            local after = getPageRange(current + 1, last)
            if after ~= "" then secondary = secondary == "" and after or secondary .. "\n\n" .. after end
            return combine("current page", getPageRange(current, current), string.format("nearby pages (±%d)", radius), secondary)
        end
        if document.info.has_pages then return extractPdfText(document, first, last), string.format("pages %d-%d", first, last) end
        return document:getTextFromXPointers(document:getPageXPointer(first), document:getPageXPointer(math.min(last + 1, total))) or "", string.format("pages %d-%d", first, last)
    end)
    text = ok and text and plainText(text) or text
    if not text or text == "" then return nil, _("KOReader could not extract text from this book.") end
    return text, label
end

function JPTAI:rememberQuestion(question)
    question = trim(question)
    for index = #self.question_history, 1, -1 do
        if self.question_history[index] == question then table.remove(self.question_history, index) end
    end
    table.insert(self.question_history, 1, question)
    while #self.question_history > 20 do table.remove(self.question_history) end
    self.question_history_settings:saveSetting("question_history", self.question_history):flush()
end

function JPTAI:clearQuestionHistory()
    self.question_history = {}
    self.question_history_settings:saveSetting("question_history", self.question_history):flush()
end

function JPTAI:setFontMultiplier(value)
    self.font_multiplier = value
    self.question_history_settings:saveSetting("font_multiplier", value):flush()
end

function JPTAI:setTranslationLanguage(language)
    self.translation_language = trim(language)
    self.question_history_settings:saveSetting("translation_language", self.translation_language):flush()
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
                { text = _("Remove the historic"), font_bold = false, callback = function()
                    self:clearQuestionHistory()
                    resume()
                end },
            },
            {{ text = _("Close"), font_bold = false, callback = resume }},
        },
    }
    UIManager:show(options)
end

function JPTAI:openComposerContext(current_mode, current_radius, set_context, resume_composer)
    local context
    local function closeContext()
        UIManager:close(context)
        UIManager:nextTick(resume_composer)
    end
    local function selectContext(mode, radius)
        set_context(mode, radius or current_radius)
        closeContext()
    end
    context = ButtonDialog:new{
        title = _("Context"),
        use_info_style = false,
        tap_close_callback = function() UIManager:nextTick(resume_composer) end,
        buttons = {
            {
                { text = _("Main context"), align = "left", font_bold = true, callback = function() end },
            },
            {
                { text = _("Selected text is used automatically when available."), align = "left", font_bold = false, callback = function() end },
            },
            {
                { text = current_mode == "page" and "✓ " .. _("Page") or _("Page"), font_bold = false, callback = function() selectContext("page") end },
                { text = current_mode == "chapter" and "✓ " .. _("Chapter") or _("Chapter"), font_bold = false, callback = function() selectContext("chapter") end },
                { text = current_mode == "book" and "✓ " .. _("Book") or _("Book"), font_bold = false, callback = function() selectContext("book") end },
            },
            {
                { text = _("Secondary context"), align = "left", font_bold = true, callback = function() end },
            },
            {
                { text = current_radius == 1 and "✓ ±1 " .. _("page") or "±1 " .. _("page"), enabled = current_mode == "selected" or current_mode == "page", font_bold = false, callback = function() selectContext(current_mode, 1) end },
                { text = current_radius == 3 and "✓ ±3 " .. _("pages") or "±3 " .. _("pages"), enabled = current_mode == "selected" or current_mode == "page", font_bold = false, callback = function() selectContext(current_mode, 3) end },
                { text = current_radius == 10 and "✓ ±10 " .. _("pages") or "±10 " .. _("pages"), enabled = current_mode == "selected" or current_mode == "page", font_bold = false, callback = function() selectContext(current_mode, 10) end },
            },
            {{ text = _("Close"), font_bold = false, callback = closeContext }},
        },
    }
    UIManager:show(context)
end

function JPTAI:openComposer(mode, response, question, chat_dialog, input_text, cursor_charpos, nearby_pages)
    local composer
    local default_button_sep_width = ButtonTable.sep_width
    local selected_mode = mode == "selected" and "selected" or mode == "chapter" and "chapter" or (mode == "maximum" or mode == "book") and "book" or (self:getSelectedText() and "selected" or "page")
    local selected_radius = nearby_pages or (mode == "medium" and 3 or 1)
    local function submitQuestion(asked, remember_question)
        UIManager:close(composer)
        if asked and asked:match("%S") then
            local selected = self:getSelectedText()
            local display_question = asked
            if selected_mode == "selected" and selected and selected:match("%S") then
                display_question = selected .. "\n\n" .. asked
            end
            if remember_question then
                local history_question = asked
                if selected and asked:sub(1, #selected) == selected then
                    history_question = trim(asked:sub(#selected + 1))
                end
                if history_question:match("%S") then self:rememberQuestion(history_question) end
            end
            local waiting = self:openChat(selected_mode, _("(Preparing answer… )"), display_question, chat_dialog, true, "", selected_radius)
            self:sendQuestion(asked, selected_mode, waiting, selected_radius, display_question)
        end
    end
    ButtonTable.sep_width = default_button_sep_width * 2
    composer = InputDialog:new{
        title = _("JPT AI question"), input = input_text or (chat_dialog and chat_dialog:getInputText()) or "", input_hint = _("Write your question here"),
        width = math.floor(Device.screen:getWidth() * 0.90), text_height = math.floor(Device.screen:getHeight() * 0.15),
        condensed = true, allow_newline = true,
        buttons = {
            {
                { text = _("Explain"), callback = function() submitQuestion("Explain the text clearly and concisely.", false) end },
                { text = _("Summarize"), callback = function() submitQuestion("Summarize the selected text, preserving the main ideas and important details.", false) end },
                { text = _("Translate"), callback = function() submitQuestion("Translate the selected text into " .. self.translation_language .. ", preserving its meaning and tone.", false) end },
                { text = _("Context"), callback = function()
                    local draft = composer:getInputText()
                    local cursor = composer._input_widget.charpos
                    UIManager:close(composer)
                    self:openComposerContext(selected_mode, selected_radius, function(mode, radius)
                        selected_mode, selected_radius = mode, radius
                    end, function()
                        self:openComposer(selected_mode, response, question, chat_dialog, draft, cursor, selected_radius)
                    end)
                end },
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
                        self:openComposer(selected_mode, response, question, chat_dialog, draft, cursor, selected_radius)
                    end)
                end },
                { text = _("Ask"), is_enter_default = true, callback = function()
                    submitQuestion(composer:getInputText(), true)
                end },
            },
        },
    }
    ButtonTable.sep_width = default_button_sep_width
    if cursor_charpos then
        composer._input_widget.charpos = cursor_charpos
        composer._input_widget:initTextBox(composer._input_widget.text)
    end
    local history_buttons = {}
    for index = 1, math.min(#self.question_history, 4) do
        local previous_question = self.question_history[index]
        table.insert(history_buttons, {{
            text = previous_question,
            callback = function() composer:setInputText(previous_question, true, false) end,
        }})
    end
    if #history_buttons > 0 then
        composer:addWidget(ButtonTable:new{
            width = composer:getAddedWidgetAvailableWidth(), buttons = history_buttons, sep_width = default_button_sep_width * 2, zero_sep = true, show_parent = composer,
        })
    end
    UIManager:show(composer)
    composer:onShowKeyboard()
end

function JPTAI:openChat(mode, response, question, previous_dialog, input_hidden, input_text, nearby_pages)
    if previous_dialog then UIManager:close(previous_dialog) end
    input_hidden = true
    local screen, dialog = Device.screen, nil
    local width = math.floor(screen:getWidth() * 0.94)
    local markdown = question and ("**Question:**  \n" .. question .. "\n\n---\n\n" .. response) or response
    local css, font_size = self:getBookTextStyle(self.font_multiplier)
    local output = ScrollHtmlWidget:new{
        html_body = renderMarkdown(markdown), width = width, height = math.floor(screen:getHeight() * (input_hidden and 0.86 or 0.65)), dialog = nil,
        default_font_size = font_size,
        css = css,
    }
    dialog = CompactChatDialog:new{
        title = "JPT AI - " .. self:getBookTitle(), input = input_text or "", input_hint = _("Write your question here"),
        fullscreen = true, condensed = true, allow_newline = true, keyboard_visible = false,
        buttons = {{
            { text = _("Close"), width = math.floor(width / 2), callback = function() UIManager:close(dialog) end },
            { text = _("Ask"), width = math.floor(width / 2), callback = function() self:openComposer("page", response, question, dialog, nil, nil, nearby_pages) end },
        }},
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
    UIManager:show(dialog)
    if not input_hidden then dialog:lockKeyboard(true) end
    return dialog
end

function JPTAI:sendQuestion(question, mode, chat_dialog, nearby_pages, display_question)
    display_question = display_question or question
    local connection, error_message = self:loadConnection()
    if not connection then self:openChat(mode, error_message, display_question, chat_dialog, nil, nil, nearby_pages); return end
    local context, label = self:getContext(mode, nearby_pages)
    self.pending_selected_text = nil
    if not context then self:openChat(mode, label, display_question, chat_dialog, nil, nil, nearby_pages); return end
    UIManager:nextTick(function()
        local payload = json.encode({ model = connection.model, temperature = self.config.temperature or 0.2, max_tokens = self.config.max_output_tokens or 8192, reasoning_effort = self.config.reasoning_effort or "low",
            messages = {{ role = "system", content = "Answer in the same language as the question. Base your answer strictly on the supplied book context." }, { role = "user", content = "BOOK CONTEXT (" .. label .. ") — PLAIN TEXT:\n" .. context .. "\n\nQUESTION:\n" .. question }} })
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
        self:openChat(mode, answer or _("JPT AI received no readable response."), display_question, chat_dialog, nil, nil, nearby_pages)
    end)
end

function JPTAI:ask(mode, selected_text)
    self.pending_selected_text = selected_text
    self:openComposer(mode, nil, nil, nil, "")
end

return JPTAI
