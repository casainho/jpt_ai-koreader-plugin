local Policy = {}

-- Offer powers of two throughout Lua's exact integer range, without a small
-- fixed UI cap. A document boundary still limits the extracted page range.
Policy.secondaryPageCounts = {}
for exponent = 0, 52 do
    Policy.secondaryPageCounts[#Policy.secondaryPageCounts + 1] = 2 ^ exponent
end

function Policy.normalizeSecondaryPageCount(value)
    value = tonumber(value) or 1
    for index, count in ipairs(Policy.secondaryPageCounts) do
        if value <= count then return count, index end
    end
    return Policy.secondaryPageCounts[#Policy.secondaryPageCounts], #Policy.secondaryPageCounts
end

-- Include the current page. For even totals, prefer one more page behind it.
function Policy.secondaryPageRange(current, total, count, only_previous)
    count = Policy.normalizeSecondaryPageCount(count)
    local before = only_previous and (count - 1) or math.floor(count / 2)
    local after = count - before - 1
    return math.max(1, current - before), math.min(total, current + after)
end

-- Preserve the original odd, centered primary-page selector (1..21).
function Policy.normalizePrimaryPageCount(value)
    local count = math.max(1, math.min(21, math.floor(tonumber(value) or 1)))
    return count % 2 == 0 and count - 1 or count
end

function Policy.primaryPageRange(current, total, count)
    local radius = math.floor((Policy.normalizePrimaryPageCount(count) - 1) / 2)
    return math.max(1, current - radius), math.min(total, current + radius)
end

-- This estimate is intentionally conservative and is used only to warn. It is
-- not a tokenizer and must never be presented as an exact provider count.
function Policy.estimateTokens(text)
    return Policy.estimateTokensFromBytes(#(text or ""))
end

function Policy.estimateTokensFromBytes(byte_count)
    return math.ceil(math.max(0, tonumber(byte_count) or 0) / 3)
end

function Policy.resolvePreset(name, has_selection)
    if name == "minimum" then
        return {
            primary_context = "pages",
            primary_page_count = 1,
            secondary_context = "none",
            secondary_page_radius = 1,
        }
    elseif name == "medium" then
        return {
            primary_context = "pages",
            primary_page_count = 3,
            secondary_context = has_selection and "nearby_pages" or "none",
            secondary_page_radius = 1,
        }
    elseif name == "maximum" then
        return {
            primary_context = has_selection and "pages" or "book",
            primary_page_count = 1,
            secondary_context = has_selection and "book" or "none",
            secondary_page_radius = 1,
        }
    end
end

function Policy.extractPdfText(document, first_page, last_page)
    local parts = {}
    for page = first_page, last_page do
        local text = document:getPageText(page) or ""
        if type(text) == "table" then
            local words = {}
            for _, block in ipairs(text) do
                for _, span in ipairs(block) do
                    if type(span) == "table" and span.word then
                        table.insert(words, span.word)
                    end
                end
            end
            text = table.concat(words, " ")
        end
        table.insert(parts, text)
    end
    return table.concat(parts, "\n")
end

function Policy.getPageTextRange(document, total_pages, first_page, last_page)
    if first_page > last_page then return "" end
    if document.info and document.info.has_pages then
        return Policy.extractPdfText(document, first_page, last_page)
    end
    return document:getTextFromXPointers(
        document:getPageXPointer(first_page),
        document:getPageXPointer(math.min(last_page + 1, total_pages))
    ) or ""
end

function Policy.combineContext(main_heading, main_text, secondary_heading, secondary_text)
    local main_line = main_heading:match("^Main context:") and main_heading or "Main context: " .. main_heading
    local context = main_line .. "\n\n" .. main_text
    local secondary_line
    if secondary_heading and secondary_text and secondary_text ~= "" then
        secondary_line = secondary_heading:match("^Secondary context:") and secondary_heading or "Secondary context: " .. secondary_heading
        context = context .. "\n\n" .. secondary_line .. "\n\n" .. secondary_text
    end
    return context, secondary_line and "primary and secondary context" or "primary context", main_line, secondary_line
end

function Policy.errorCategory(code, message)
    local status = tonumber(code)
    local by_status = {
        [400] = "bad_request",
        [401] = "unauthorized",
        [403] = "forbidden",
        [404] = "not_found",
        [408] = "timeout",
        [413] = "too_large",
        [422] = "unprocessable",
        [429] = "rate_limited",
        [500] = "server_error",
        [502] = "unavailable",
        [503] = "unavailable",
        [504] = "timeout",
        [-5] = "timeout",
        [-6] = "timeout",
        [-11] = "tls_error",
    }
    if by_status[status] then return by_status[status] end
    if status and status >= 500 then return "unavailable" end
    local lower = tostring(message or ""):lower()
    if lower:find("wantread", 1, true) or lower:find("timeout", 1, true) then return "timeout" end
    if lower:find("certificate", 1, true) or lower:find("ssl", 1, true) then return "tls_error" end
    return "request_failed"
end

return Policy
