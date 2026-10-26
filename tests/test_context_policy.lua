local script_path = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("(.*/)") or ""
local Policy = dofile(script_path .. "../context_policy.lua")

local function equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

local minimum = Policy.resolvePreset("minimum", false)
equal(minimum.primary_page_count, 1, "minimum pages")
equal(minimum.secondary_context, "none", "minimum secondary context")
local selected_minimum = Policy.resolvePreset("minimum", true)
equal(selected_minimum.primary_context, "pages", "selected minimum keeps selection primary")
equal(selected_minimum.secondary_context, "none", "selected minimum has no supporting context")

local medium = Policy.resolvePreset("medium", false)
equal(medium.primary_page_count, 3, "medium pages")
equal(medium.secondary_context, "none", "medium secondary context")
local selected_medium = Policy.resolvePreset("medium", true)
equal(selected_medium.secondary_context, "nearby_pages", "selected medium secondary context")

local maximum = Policy.resolvePreset("maximum", false)
equal(maximum.primary_context, "book", "maximum primary context")
local selected_maximum = Policy.resolvePreset("maximum", true)
equal(selected_maximum.secondary_context, "book", "selected maximum secondary context")

equal(Policy.normalizeSecondaryPageCount(3), 4, "migrate old odd count")
equal(Policy.normalizeSecondaryPageCount(21), 32, "migrate old maximum")
equal(Policy.normalizeSecondaryPageCount(33), 64, "continue beyond old maximum")
equal(Policy.normalizeSecondaryPageCount(513), 1024, "continue doubling")
equal(Policy.normalizeSecondaryPageCount(nil), 1, "missing count")
for index, count in ipairs(Policy.secondaryPageCounts) do
    local normalized, selected_index = Policy.normalizeSecondaryPageCount(count)
    equal(normalized, count, "preserve page count")
    equal(selected_index, index, "picker index")
    for _, only_previous in ipairs(count <= 1024 and { false, true } or {}) do
        local first, last = Policy.secondaryPageRange(2048, 4096, count, only_previous)
        equal(last - first + 1, count, "exact total in both modes")
        assert(first <= 2048 and last >= 2048, "include current page")
        if only_previous then equal(last, 2048, "exclude following pages") end
    end
end
local first, last = Policy.secondaryPageRange(50, 100, 4, false)
equal(first, 48, "even total starts before current page")
equal(last, 51, "even total ends after current page")
first, last = Policy.secondaryPageRange(1, 100, 8, true)
equal(first, 1, "previous pages clamp at book start")
equal(last, 1, "no following pages at book start")
first, last = Policy.secondaryPageRange(100, 100, 8, false)
equal(first, 96, "centered range at book end")
equal(last, 100, "centered range clamps at book end")

local primary_first, primary_last = Policy.primaryPageRange(50, 100, 5)
equal(primary_first, 48, "original primary start")
equal(primary_last, 52, "original primary end")
equal(Policy.normalizePrimaryPageCount(4), 3, "restore odd primary count")
equal(Policy.normalizePrimaryPageCount(64), 21, "restore primary maximum")

equal(Policy.estimateTokens(""), 0, "empty estimate")
equal(Policy.estimateTokens("1234"), 2, "byte estimate rounds up")
equal(Policy.estimateTokensFromBytes(7), 3, "length estimate rounds up")

local pdf = {
    info = { has_pages = true },
    getPageText = function(_, page)
        if page == 1 then return { { { word = "primeira" }, { word = "página" } } } end
        return "segunda página"
    end,
}
equal(Policy.getPageTextRange(pdf, 2, 1, 2), "primeira página\nsegunda página", "PDF text extraction")
equal(Policy.getPageTextRange(pdf, 2, 2, 1), "", "empty PDF range")

local epub = {
    info = { has_pages = false },
    getPageXPointer = function(_, page) return "p" .. page end,
    getTextFromXPointers = function(_, first, last) return first .. "-" .. last end,
}
equal(Policy.getPageTextRange(epub, 3, 1, 3), "p1-p3", "EPUB range clamps to document end")

local context, label = Policy.combineContext("Selected text", "word", "Current page", "surrounding")
equal(context, "Main context: Selected text\n\nword\n\nSecondary context: Current page\n\nsurrounding", "context composition")
equal(label, "primary and secondary context", "context label")

equal(Policy.errorCategory(401), "unauthorized", "authentication error")
equal(Policy.errorCategory(413), "too_large", "oversized context")
equal(Policy.errorCategory(-6), "timeout", "async timeout")
equal(Policy.errorCategory(-11), "tls_error", "TLS error")
equal(Policy.errorCategory(429), "rate_limited", "rate limit error")
equal(Policy.errorCategory(nil, "certificate verify failed"), "tls_error", "TLS message classification")

print("JPT AI context policy tests passed")
