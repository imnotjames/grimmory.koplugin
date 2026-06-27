local assert = require 'luassert'
local match = require 'luassert.match'
local spy = require 'luassert.spy'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path


local fake_document = stub.new()
local mock_has_provider = spy.new(function() return true end)
local mock_open_document = spy.new(function() return fake_document end)

package.preload["document/documentregistry"] = function()
    return {
        hasProvider = mock_has_provider,
        openDocument = mock_open_document,
    }
end

local fake_cfi_resolver = stub.new()
local mock_cfi_resolver_new = spy.new(function() return fake_cfi_resolver end)

package.preload["grimmory/cfi_resolver"] = function()
    return {
        new = mock_cfi_resolver_new,
    }
end

local fake_doc_metadata = stub.new()

local GrimmoryReadingAnnotations = require("grimmory/reading/annotations")


local remote_grimmory_annotation = {
    ["id"] = 27,
    ["chapter"] = "Logical Reading Order",
    ["color"] = "",
    ["created_at"] = 1781321340,
    ["style"] = "highlight",
    ["page"] = "start",
    ["pos0"] = "start",
    ["pos1"] = "end",
    ["text"] = "Although you’ll hear that all EPUB 3s have a default reading order",
}

local local_grimmory_annotation = {
    ["chapter"] = "Logical Reading Order",
    ["color"] = "yellow",
    ["datetime"] = "2026-06-13 03:29:00Z",
    ["drawer"] = "lighten",
    ["grimmory_id"] = 27,
    ["page"] = "start",
    ["pos0"] = "start",
    ["pos1"] = "end",
    ["text"] = "Although you’ll hear that all EPUB 3s have a default reading order",
}

local local_annotation = {
    ["chapter"] = "Lists",
    ["color"] = "yellow",
    ["datetime"] = "2026-06-13 03:20:33Z",
    ["drawer"] = "lighten",
    ["page"] = "/body/DocFragment[12]/body/section/section/section[8]/p[3]/text()",
    ["pageno"] = 44,
    ["pos0"] = "/body/DocFragment[12]/body/section/section/section[8]/p[3]/text()",
    ["pos1"] = "/body/DocFragment[12]/body/section/section/section[8]/p[3]/text().163",
    ["text"] = "element, on the other hand, provides the ability both to move quickly " ..
                "from item to item and to escape the list entirely. It also allows a " ..
                "reading system to",
}


describe("GrimmoryReadingAnnotations", function()
    before_each(function()
        fake_document.loadDocument = spy.new(function() return true end)
        fake_document.close = spy.new(function() end)

        fake_cfi_resolver.cfiRangeToXPointers = spy.new(function() return "start", "end" end)
        fake_cfi_resolver.xpointerRangeToCFI = spy.new(function() return "cfi" end)

        stub(fake_doc_metadata, "getAnnotations").returns({})
        stub(fake_doc_metadata, "setAnnotations")
    end)

    describe("mergeAnnotations", function()
        it("removes missing grimmory annotations", function()
            local expected = {}

            fake_doc_metadata.getAnnotations.returns({
                local_grimmory_annotation,
            })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {})

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same(expected)
            )
        end)

        it("retains non-grimmory annotations", function()
            local expected = { local_annotation }
            fake_doc_metadata.getAnnotations.returns({ local_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {})

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same(expected)
            )
        end)

        it("appends grimmory annotations", function()
            local expected = {
                local_annotation,
                local_grimmory_annotation,
            }
            fake_doc_metadata.getAnnotations.returns({ local_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {
                remote_grimmory_annotation
            })

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                fake_doc_metadata,
                "book_path",
                expected
            )
        end)
    end)

    describe("getAnnotations", function()
        it("translates colors and styles for local annotations", function()
            fake_doc_metadata.getAnnotations.returns({ local_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            local actual = annotations:getAnnotations("book_path")

            assert.equal(1, #actual)
            assert.equal("#FFC107", actual[1].color)
            assert.equal("highlight", actual[1].style)
        end)
    end)
end)
