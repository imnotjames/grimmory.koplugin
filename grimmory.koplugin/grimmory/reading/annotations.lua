local DocumentRegistry = require("document/documentregistry")

local GrimmoryCFIResolver = require("grimmory/cfi_resolver")


---@param value integer
---@return string
local function to_annotation_datetime(value)
    if value == nil then
        return nil
    end

    local parsed = os.date("!*t", value)
    return string.format(
        "%04d-%02d-%02d %02d:%02d:%02dZ",
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.min,
        parsed.sec
    )
end

---@param value string
---@return integer timestamp
local function from_annotation_datetime(value)
    if value == nil then
        return nil
    end

    local year, month, day, hour, min, sec = value:match(
        "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)"
    )

    return os.time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec
    })
end

---@param document_path string
---@param callback (fun(resolver: GrimmoryCFIResolver): nil)
local function with_cfi_resolver(document_path, callback)
    local document = (
        DocumentRegistry:hasProvider(document_path) and
        DocumentRegistry:openDocument(document_path)
    )

    if document then
        local loaded = true
        if document.loadDocument then
            loaded = document:loadDocument(true)
        end

        if loaded then
            local cfi_resolver = GrimmoryCFIResolver:new(document)

            callback(cfi_resolver)
        end

        document:close()
    end
end

local KOREADER_COLOR_MAP = {
    yellow = "#FFC107",
    green = "#4ADE80",
    cyan = "#38BDF8",
    pink = "#F472B6",
    orange = "#FB923C",
    red = "#FB523C",
    purple = "#F452FC",
    blue = "#0248F8",
    gray = "#AAAAAA",
    white = "#FAFAFA",
}

local GRIMMORY_COLOR_MAP = {
    ["#FFC107"] = "yellow",
    ["#4ADE80"] = "green",
    ["#38BDF8"] = "cyan",
    ["#F472B6"] = "pink",
    ["#FB923C"] = "orange",
    ["#FB523C"] = "red",
    ["#F452FC"] = "purple",
    ["#0248F8"] = "blue",
    ["#AAAAAA"] = "gray",
    ["#FAFAFA"] = "white",
}

local KOREADER_STYLE_MAP = {
    lighten    = "highlight",
    underscore = "underline",
    strikeout  = "strikethrough",
}

local GRIMMORY_STYLE_MAP = {
    highlight = "lighten",
    underline = "underscore",
    strikethrough = "strikeout",
}

local DEFAULT_KOREADER_COLOR = "yellow"
local DEFAULT_KOREADER_STYLE = "lighten"
local DEFAULT_GRIMMORY_COLOR = KOREADER_COLOR_MAP[DEFAULT_KOREADER_COLOR]
local DEFAULT_GRIMMORY_STYLE = KOREADER_STYLE_MAP[DEFAULT_KOREADER_STYLE]

---@class GrimmoryReadingAnnotations
---@field doc_metadata GrimmoryDocMetadata
local GrimmoryReadingAnnotations = {}

function GrimmoryReadingAnnotations:new(doc_metadata)
    local o = {
        doc_metadata = doc_metadata,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

local function normalize_xpointer(xpointer)
    if xpointer == nil then
        return ""
    end

    -- /p[1]/ -> /p/
    xpointer = xpointer:gsub("%[1%]", "")

    -- /text().0 -> /text()
    xpointer = xpointer:gsub("%.0$", "")

    return xpointer
end

---@param a string
---@param b string
---@return bool
local function is_same_xpointer(a, b)
    return normalize_xpointer(a) == normalize_xpointer(b)
end

---@param book_path string
local function merge_annotations(local_annotations, remote_annotations)
    local remote_grimmory_ids = {}
    for _, a in ipairs(remote_annotations) do
        if a.grimmory_id ~= nil then
            remote_grimmory_ids[tostring(a.grimmory_id)] = a
        end
    end

    local local_grimmory_ids = {}
    local new_annotations = {}

    -- Filter out existing records with Grimmory IDs that do not
    -- exist on the Grimmory side anymore.
    for _, a in ipairs(local_annotations) do
        if a.grimmory_id ~= nil then
            local_grimmory_ids[tostring(a.grimmory_id)] = a
        end

        if a.grimmory_id == nil or remote_grimmory_ids[tostring(a.grimmory_id)] then
            table.insert(new_annotations, a)
        end
    end

    for grimmory_id, annotation in pairs(remote_grimmory_ids) do
        if local_grimmory_ids[grimmory_id] == nil then
            local found_annotation = false
            for _, existing_annotation in ipairs(new_annotations) do
                if (
                    existing_annotation.grimmory_id == nil and
                    existing_annotation.pos0 ~= nil and
                    existing_annotation.pos1 ~= nil and
                    is_same_xpointer(existing_annotation.pos0, annotation.pos0) and
                    is_same_xpointer(existing_annotation.pos1, annotation.pos1)
                ) then
                    found_annotation = true

                    -- Just apply, don't think too hard about it.
                    existing_annotation.grimmory_id = annotation.grimmory_id
                    existing_annotation.datetime = annotation.datetime
                    existing_annotation.datetime_updated = annotation.datetime_updated
                    existing_annotation.color = annotation.color
                    existing_annotation.drawer = annotation.drawer
                    existing_annotation.chapter = annotation.chapter
                    existing_annotation.text = annotation.text
                    existing_annotation.page = annotation.page
                end
            end

            if not found_annotation then
                -- This is a new annotation and can be added to the table
                table.insert(new_annotations, annotation)
            end
        else
            -- Apply to matching grimmory ID
            local existing_annotation = local_grimmory_ids[grimmory_id]

            existing_annotation.pos0 = annotation.pos0
            existing_annotation.pos1 = annotation.pos1
            existing_annotation.datetime = annotation.datetime
            existing_annotation.datetime_updated = annotation.datetime_updated
            existing_annotation.color = annotation.color
            existing_annotation.drawer = annotation.drawer
            existing_annotation.chapter = annotation.chapter
            existing_annotation.text = annotation.text
            existing_annotation.page = annotation.page
        end
    end

    -- TODO: Merge overlapping annotations
    -- If there are annotations that overlap exactly, select the "latest"
    -- and delete the older ones
    -- For imperfect overlap, combine and prioritize the later ones.

    return new_annotations
end

---@param book_path string
---@param annotations GrimmoryAnnotation[]
function GrimmoryReadingAnnotations:applyAnnotations(book_path, grimmory_annotations)
    local remote_annotations = {}

    with_cfi_resolver(
        book_path,
        function (cfi_resolver)
            for _, annotation in ipairs(grimmory_annotations) do
                local xpointer_start, xpointer_end = cfi_resolver:cfiRangeToXPointers(
                    annotation.cfi
                )

                local koreader_annotation = {
                    grimmory_id = annotation.id,

                    datetime = to_annotation_datetime(annotation.created_at),
                    datetime_updated = to_annotation_datetime(annotation.updated_at),

                    color = GRIMMORY_COLOR_MAP[annotation.color] or DEFAULT_KOREADER_COLOR,
                    drawer = GRIMMORY_STYLE_MAP[annotation.style] or DEFAULT_KOREADER_STYLE,

                    chapter = annotation.chapter,
                    text = annotation.text,

                    page = xpointer_start,

                    pos0 = xpointer_start,
                    pos1 = xpointer_end,
                }

                table.insert(remote_annotations, koreader_annotation)
            end
        end
    )

    local local_annotations = self.doc_metadata:getAnnotations(book_path)

    local new_annotations = merge_annotations(local_annotations, remote_annotations)

    self.doc_metadata:setAnnotations(book_path, new_annotations)
end

---@return GrimmoryAnnotation[] annotations
function GrimmoryReadingAnnotations:getAnnotations(book_path)
    -- Get annotations for book
    local annotations = self.doc_metadata:getAnnotations(book_path)

    local grimmory_annotations = {}

    with_cfi_resolver(
        book_path,
        function(cfi_resolver)
            for _, annotation in ipairs(annotations) do
                -- Annotations without pos0 / pos1 are bookmarks
                if annotation.pos0 ~= nil and annotation.pos1 ~= nil then
                    ---@type GrimmoryAnnotation
                    local grimmory_annotation = {
                        id = annotation.grimmory_id,
                        book_id = -1,
                        created_at = from_annotation_datetime(annotation.datetime),
                        updated_at = from_annotation_datetime(annotation.datetime_updated),
                        cfi = cfi_resolver:xpointerRangeToCFI(annotation.pos0, annotation.pos1),
                        chapter = annotation.chapter,
                        text = annotation.text,
                        note = annotation.note,
                        color = KOREADER_COLOR_MAP[annotation.color] or DEFAULT_GRIMMORY_COLOR,
                        style = KOREADER_STYLE_MAP[annotation.drawer] or DEFAULT_GRIMMORY_STYLE,
                    }

                    table.insert(grimmory_annotations, grimmory_annotation)
                end
            end
        end
    )

    return grimmory_annotations
end

return GrimmoryReadingAnnotations