local Cache = require("cache")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

local HTML_VOID_ELEMENT_TAGS = {
    area=true,
    base=true,
    br=true,
    col=true,
    embed=true,
    hr=true,
    img=true,
    input=true,
    link=true,
    meta=true,
    param=true,
    source=true,
    track=true,
    wbr=true,
}

local function find_first(s, patterns, index)
    local res = {}
    for _, p in ipairs(patterns) do
        local match = { s:find(p, index) }
        if #match > 0 and (#res == 0 or match[1] < res[1]) then
            res = match
        end
    end

    return table.unpack(res)
end

---@param html string
---@return function token_iterator
local function tokenize_html(html)
    local pos = 0

    return function ()
        while html ~= nil and pos < #html do
            local start = find_first(html, {"<!%-%-", "<[-A-Z0-9a-z/!$]", "<%?"}, pos)
            if not start then
                local text = html:sub(pos)
                pos = #html

                return {
                    type = "text",
                    text = text,
                    raw = text,
                }
            end

            if start ~= pos then
                local text = html:sub(pos, start - 1)

                pos = start

                return {
                    type = "text",
                    text = text,
                    raw = text,
                }
            end

            local _, stop

            local is_ignored = false

            if html:match("^<!%-%-", start) then
                _,stop = html:find("%-%->", start)
                is_ignored = true
            elseif html:match("^<%?", start) then
                _,stop = html:find("?>", start)
                is_ignored = true
            else
                _,stop = html:find("%b<>", start)
            end

            if not stop then
                pos = start + 1

                local text = html:sub(start, start)

                return {
                    type = "text",
                    text = text,
                    raw = text,
                }
            elseif is_ignored then
                pos = stop + 1
            else
                pos = stop + 1

                local found_tag = html:sub(start, stop)
                local found_end_tag, found_tag_name = found_tag:match("^<(/?)([^%s>]+)")

                if found_tag_name then
                    if found_end_tag == "/" then
                        return {type="end-tag", text=found_tag_name:lower(), raw=found_tag}
                    else
                        return {type="tag", text=found_tag_name:lower(), raw=found_tag}
                    end
                end
            end
        end

        return nil
    end
end

---@param tokens function
---@param callback function
local function walk_tree(tokens, callback)
    -- If we we leave the fragment path we have a problem and should bail.
    local depth = 0

    -- Search among the siblings
    for token in tokens do
        if not callback(depth, token) then
            return true
        end

        if token.type == "tag" and not HTML_VOID_ELEMENT_TAGS[token.text] then
            depth = depth + 1
        elseif token.type == "end-tag" and not HTML_VOID_ELEMENT_TAGS[token.text] then
            depth = depth - 1
        end

        if depth < 0 then
            return false
        end
    end

    return true
end

---@return boolean ok
---@return string text
local function get_text(tokens, match_index)
    local match_counter = 0
    local target_token

    local ok = walk_tree(tokens, function(depth, token)
        if depth > 0 then
            return true
        end

        if token.type ~= "text" then
            return true
        end

        match_counter = match_counter + 1

        if match_counter ~= match_index then
            return true
        end

        target_token = token
        return false
    end)

    if not ok or target_token == nil then
        return false, ""
    end

    return true, target_token.text
end

---@param tokens function
---@param match_index integer
---@param match_text string
---@return boolean ok
---@return integer node_counter
local function count_children(tokens, match_index, match_text)
    local node_counter = 0
    local match_counter = 0

    local target_token

    local ok = walk_tree(tokens, function(depth, token)
        if depth > 0 then
            return true
        end

        node_counter = node_counter + 1

        if token.type ~= "tag" then
            return true
        end

        if token.text ~= match_text then
            return true
        end

        match_counter = match_counter + 1

        if match_counter ~= match_index then
            return true
        end

        target_token = token
        return false
    end)

    if not ok or target_token == nil then
        return false, 0
    end

    return true, node_counter
end

---@return boolean ok
---@return string type
---@return string text
---@return integer type_counter
local function get_child(tokens, child_index)
    local node_counter = 0

    local target_token

    local match_counters = {}

    local ok = walk_tree(tokens, function(depth, token)
        if depth > 0 then
            return true
        end

        if token.type ~= "tag" and token.type ~= "text" then
            return true
        end

        node_counter = node_counter + 1

        if token.type == "text" then
            match_counters["text()"] = (match_counters["text()"] or 0) + 1
        elseif token.type == "tag" then
            match_counters[token.text] = (match_counters[token.text] or 0) + 1
        end

        if node_counter ~= child_index then
            return true
        end

        target_token = token
        return false
    end)

    if not ok or target_token == nil then
        return false, "", "", 0
    end

    local match_counter = 0

    if target_token.type == "text" and match_counters["text()"] then
        match_counter = match_counters["text()"]
    elseif target_token.type == "tag" and match_counters[target_token.text] then
        match_counter = match_counters[target_token.text]
    end

    return true, target_token.type, target_token.text, match_counter
end

local function format_cfi(fragment_index, local_path)
    local global_path = "/6/" .. tostring(fragment_index * 2)

    return "epubcfi(" .. global_path .. "!" .. local_path .. ")"
end

---@param text string
---@param character_offset number
---@param ignore_whitespace boolean ignore inconsequential whitespace - true for xpointer, false for CFI
---@return number
local function translate_character_offset(text, character_offset, ignore_whitespace)
    local newline_count = 0
    local ignored_count = 0
    local text_offset = 0
    local is_ignored = true

    while text_offset <= #text do
        if ignore_whitespace and text_offset - newline_count - 1 >= character_offset then
            break
        elseif not ignore_whitespace and text_offset - ignored_count - 1 >= character_offset then
            break
        end

        local char = text:sub(text_offset, text_offset)

        if char == "\n" or char == "\r" then
            is_ignored = true
            newline_count = newline_count + 1
        else
            if char ~= "\t" and char ~= " " then
                is_ignored = false
            end
        end

        if is_ignored then
            ignored_count = ignored_count + 1
        end

        text_offset = text_offset + 1
    end

    if ignore_whitespace then
        return text_offset - ignored_count - 1
    else
        return text_offset - newline_count - 1
    end
end

---@param text string
---@param character_offset number
---@return number
local function translate_character_offset_cfi_to_xpointer(text, character_offset)
    return translate_character_offset(text, character_offset, true)
end

---@param text string
---@param character_offset number
---@return number
local function translate_character_offset_xpointer_to_cfi(text, character_offset)
    return translate_character_offset(text, character_offset, false)
end

---@class XPointerFragmentPart
---@field tag_name string
---@field tag_index integer
---@field character_offset? number

---@return number fragment_index
---@return XPointerFragmentPart[] fragment_path
local function decompose_xpointer(xpointer)
    local fragment_index, serialized_path = xpointer:match("^/body/DocFragment%[(%d+)%](.*)$")

    fragment_index = tonumber(fragment_index) or 1

    if serialized_path == nil then
        serialized_path = "/html/body"
    end

    local fragment_path = {}

    for fragment_path_part in serialized_path:gmatch("[^/]+") do
        local tag_name_no_character_offset, character_offset_str = fragment_path_part:match("(.*)%.(%d+)$")

        local fragment_path_part_cleaned = tag_name_no_character_offset or fragment_path_part

        local tag_name, tag_index_str = fragment_path_part_cleaned:match("([^[]+)%[(%d+)%]")

        if tag_name == nil then
            tag_name = fragment_path_part_cleaned
        end

        local character_offset = nil

        if character_offset_str ~= nil then
            character_offset = tonumber(character_offset_str)
        end

        local tag_index = 1

        if tag_index_str ~= nil then
            tag_index = tonumber(tag_index_str) or 1
        end

        table.insert(
            fragment_path,
            {
                tag_name = tag_name:lower(),
                tag_index = tag_index,
                character_offset = character_offset,
            }
        )
    end

    return fragment_index, fragment_path
end

---@param cfi string
---@return string cfi_start
---@return string cfi_end
local function split_local_range_cfi_path(cfi)
    local root, path_a, path_b = cfi:match("^([^,]+),([^,]+),([^,]+)$")

    if root == nil or path_a == nil or path_b == nil then
        error("invalid CFI range")
    end

    return root .. path_a, root .. path_b
end

---@param fragment_html any
---@param cfi_local_path any
local function cfi_local_path_to_fragment_path(fragment_html, cfi_local_path)
    local tokens = tokenize_html(fragment_html)

    for token in tokens do
        -- Enter HTML
        if token.type == "tag" and token.text == "html" then
            break
        end
    end

    local fragment_path_parts = {}
    local target_text = nil

    for part in cfi_local_path:gmatch("([^/]+)") do
        local part_node_index = tonumber(part:match("^(%d+)"))
        -- For each CFI part
        -- Iterate through children in HTML for local path

        local ok, token_type, text, match_index = get_child(tokens, part_node_index)

        if not ok then
            error("could not translate from local path to xpointer")
        end

        local fragment_path_suffix = ""
        if match_index ~= 1 then
            fragment_path_suffix = "[" .. tostring(match_index) .. "]"
        end

        if token_type == "tag" then
            table.insert(fragment_path_parts, text .. fragment_path_suffix)
        elseif token_type == "text" then
            table.insert(fragment_path_parts, "text()" .. fragment_path_suffix)
            target_text = text
        end
    end
    -- Get text and translate text to XPointer

    local character_offset = tonumber(cfi_local_path:match(":(%d+)%)$"))
    local character_offset_suffix = ""
    if character_offset ~= nil then
        if target_text ~= nil then
            character_offset = translate_character_offset_cfi_to_xpointer(target_text, character_offset)
        end
        character_offset_suffix = "." .. tostring(character_offset)
    end

    return "/" .. table.concat(fragment_path_parts, "/") .. character_offset_suffix
end

---@param fragment_html string
---@param fragment_path XPointerFragmentPart[]
---@return string cfi_local_path
local function fragment_path_to_cfi_local_path(fragment_html, fragment_path)
    if #fragment_path == 0 or #fragment_html == 0 then
        return "/1"
    end

    local tokens = tokenize_html(fragment_html)

    for token in tokens do
        -- Enter HTML
        if token.type == "tag" and token.text == "html" then
            break
        end
    end

    ---@type number[]
    local cfi_steps = {}
    local target_text = nil

    for _, part in ipairs(fragment_path) do
        ---@cast part XPointerFragmentPart

        -- Find text
        if part.tag_name == "text()" then
            table.insert(cfi_steps, part.tag_index * 2 - 1)

            local found_text, text = get_text(tokens, part.tag_index)

            if found_text then
                target_text = text
            end

            break
        end

        local found_ok, tag_counter = count_children(tokens, part.tag_index, part.tag_name)

        if not found_ok then
            error("Something has gone wrong")
        end

        table.insert(cfi_steps, tag_counter)
    end

    local character_offset_suffix = ""
    -- If last has a character offset we need to add a suffix for character offsets
    if #fragment_path > 0 then
        local character_offset = fragment_path[#fragment_path].character_offset

        if character_offset ~= nil then
            if target_text ~= nil then
                character_offset = translate_character_offset_xpointer_to_cfi(target_text, character_offset)
            end

            character_offset_suffix = ":" .. tostring(character_offset)
        end
    end

    return "/" .. table.concat(cfi_steps, "/") .. character_offset_suffix
end

---@class GrimmoryCFIResolver
---@field document string
---@field cache Cache
local GrimmoryCFIResolver = {}

---@param document CREDocument
---@param cache? Cache
function GrimmoryCFIResolver:new(document, cache)
    local o = {
        document = document,
        cache = cache or Cache:new({ slots = 8 })
    }
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryCFIResolver:init()
end

---@param cfi_a string
---@param cfi_b string
---@return string
function GrimmoryCFIResolver.asCFIRange(cfi_a, cfi_b)
    local bare_cfi_a = cfi_a:match("^epubcfi%((.+)%)$")
    local bare_cfi_b = cfi_b:match("^epubcfi%((.+)%)$")

    local root = ""

    for step in bare_cfi_a:gmatch("([^/]+)") do
        local next = root .. "/" .. step .. "/"

        if next ~= bare_cfi_b:sub(1, #next) then
            break
        end

        root = root .. "/" .. step
    end

    return "epubcfi(" .. root .. "," .. bare_cfi_a:sub(#root + 1) .. "," .. bare_cfi_b:sub(#root + 1) .. ")"
end

---@private
---@param fragment_index integer
---@return string | nil html
function GrimmoryCFIResolver:getFragmentHTML(fragment_index)
    local html

    html = self.cache:get(fragment_index)
    if html ~= nil then
        return html
    end

    -- There has to be a better way to get this..

    local source
    local fragment_html = self.document:getHTMLFromXPointer("/body/DocFragment[" .. tostring(fragment_index) .. "]")
    for token in tokenize_html(fragment_html) do
        if token.type == "tag" and token.text == "docfragment" then
            source = token.raw:match("Source=\"([^\"]+)\"")
            break
        end
    end

    if source then
        html = self.document:getDocumentFileContent(source)
    end

    self.cache:insert(fragment_index, html)

    return html
end

---@param cfi string
---@return string xpointer
function GrimmoryCFIResolver:cfiToXpointer(cfi)
    -- Split global / local path
    local global_path, local_path = cfi:match("^epubcfi%(([^!]+)!(.+)")

    if global_path == nil then
        global_path = ""
    end

    if local_path == nil then
        local_path = cfi
    end

    -- Look up fragment HTML based on global path
    local fragment_index = 1

    local global_path_fragment_index = tonumber(global_path:match("^/6/(%d+)"))
    if global_path_fragment_index ~= nil then
        fragment_index = math.floor(tonumber(global_path_fragment_index) / 2)
    end

    local fragment_html = self:getFragmentHTML(fragment_index)

    if fragment_html == nil then
        logger:err("Unable to load fragment HTML for CFI:", cfi)
        error("Unable to load fragment HTML for CFI")
    end

    local fragment_path = cfi_local_path_to_fragment_path(fragment_html, local_path)

    return "/body/DocFragment[" .. tostring(fragment_index) .. "]" .. fragment_path
end

---@param cfi string
---@return string xpointer_start
---@return string xpointer_end
function GrimmoryCFIResolver:cfiRangeToXPointers(cfi)
    local cfi_start, cfi_end = split_local_range_cfi_path(cfi)

    return self:cfiToXpointer(cfi_start), self:cfiToXpointer(cfi_end)
end

---@param xpointer string
---@return string cfi
function GrimmoryCFIResolver:xpointerToCFI(xpointer)
    logger:dbg("Converting xpointer to CFI:", xpointer)

    -- Decompose XPointer to parts
    local fragment_index, fragment_path = decompose_xpointer(xpointer)

    -- Read HTML for fragment index
    local fragment_html = self:getFragmentHTML(fragment_index)

    if fragment_html == nil then
        logger:err("Unable to load fragment HTML for XPointer:", xpointer)
        error("Unable to load fragment HTML for XPointer")
    end

    -- DOM to CFI steps
    local local_path = fragment_path_to_cfi_local_path(fragment_html, fragment_path)

    logger:dbg("Local path for CFI:", local_path)

    -- Format
    return format_cfi(fragment_index, local_path)
end

---@param xpointer_start string
---@param xpointer_end string
---@return string cfi
function GrimmoryCFIResolver:xpointerRangeToCFI(xpointer_start, xpointer_end)
    local cfi_start = self:xpointerToCFI(xpointer_start)
    local cfi_end = self:xpointerToCFI(xpointer_end)

    return self.asCFIRange(cfi_start, cfi_end)
end

return GrimmoryCFIResolver