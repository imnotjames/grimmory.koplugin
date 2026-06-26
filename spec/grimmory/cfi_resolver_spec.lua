local assert = require 'luassert'
local spy = require 'luassert.spy'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = spy.new(function() end),
    info = spy.new(function() end),
    dbg = spy.new(function() end),
}

package.preload["grimmory/logger"] = function()
    return {
        new = function()
            return fake_logger
        end
    }
end

local fake_cache = {}

package.preload["cache"] = function()
    return {
        new = function()
            return {
                get = function(_, key)
                    return fake_cache[tostring(key)]
                end,
                insert = function(_, key, value)
                    fake_cache[tostring(key)] = value
                end
            }
        end,
    }
end

local fake_document = stub.new()

local GrimmoryCFIResolver = require("grimmory/cfi_resolver")

local EXAMPLE_HTML = [[CDATA
<html>
    <head>
    </head>
    <body>
        <div id="chapter2">
            <h1>Chapter 2</h1>
            <p>Content of chapter <code>two</code>.</p>
            <p>
                Second paragraph
                with
                <bold>more</bold> text.
            </p>
        </div>
    </body>
</html>
]]

describe("GrimmoryCFIResolver", function()
    before_each(function()
        fake_document.loadDocument = spy.new(function() return true end)
        fake_document.getNormalizedXPointer = spy.new(function(_, xp) return xp end)
        fake_document.getHTMLFromXPointer = spy.new(function() return "<DocFragment Source=\"example.html\">" end)
        fake_document.getDocumentFileContent = spy.new(function() return EXAMPLE_HTML end)
        fake_document.close = spy.new(function() end)

        for key in pairs(fake_cache) do
            fake_cache[key] = nil
        end
    end)

    describe("cfiToXpointer", function()
        it("handles self-ending tag", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
            <html>
                <head>
                </head>
                <body>
                    <h1>Chapter 2</h1>
                    <span self="ending" tag />
                    <p>Content of chapter <code>two</code>.</p>
                </body>
            </html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/6)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/p",
                actual
            )
        end)

        it("prevents entering self-ending tag", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
            <html>
                <head>
                </head>
                <body>
                    <h1>Chapter 2</h1>
                    <span self="ending" tag />
                    <p>Content of chapter <code>two</code>.</p>
                </body>
            </html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.has_error(
                function()
                    cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/4/2)")
                end,
                "impossible CFI for document: attempting to get children of void"
            )
        end)

        it("converts simple xpointer", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/4)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p",
                actual
            )
        end)

        it("converts xpointer referencing second occurrence", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/6)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p[2]",
                actual
            )
        end)

        it("converts xpointer referencing text", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/4/1:3)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p/text().3",
                actual
            )
        end)

        it("converts xpointer mapping text offsets", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/6/1:19)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p[2]/text().3",
                actual
            )
        end)

        it("converts xpointer referencing text in between elements", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/6/3:3)"
            )

            assert.are.equal(
            "/body/DocFragment[12]/body/div/p[2]/text()[2].3",
                actual
            )
        end)
    end)

    describe("xpointerToCFI", function()
        it("converts simple xpointer", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/4)",
                actual
            )
        end)

        it("converts xpointer referencing second occurrence", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p[2]"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/6)",
                actual
            )
        end)

        it("converts xpointer referencing text", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p/text().3"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/4/1:3)",
                actual
            )
        end)

        it("converts xpointer mapping text offsets", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p[2]/text().3"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/6/1:19)",
                actual
            )
        end)

        it("converts xpointer referencing text in between elements", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p[2]/text()[2].3"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/6/3:3)",
                actual
            )
        end)
    end)

    describe("cfiRangeToXPointers", function()
        it("handles start and end within text blocks", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual_start, actual_end = cfi_resolver:cfiRangeToXPointers(
                "epubcfi(/6/24!/4/2/6,/3:3,/3:5)"
            )

            assert.are.equal("/body/DocFragment[12]/body/div/p[2]/text()[2].3", actual_start)
            assert.are.equal("/body/DocFragment[12]/body/div/p[2]/text()[2].5", actual_end)
        end)
    end)

    describe("xpointerRangeToCFI", function()
        it("supports ranges between two block nodes", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerRangeToCFI(
                "/body/DocFragment[12]/body/div/p",
                "/body/DocFragment[12]/body/div/p[2]"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2,/4,/6)",
                actual
            )
        end)

        it("supports ranges between block and inline", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerRangeToCFI(
                "/body/DocFragment[12]/body/div/p/text()[1].2",
                "/body/DocFragment[12]/body/div/p/code[1]/text().2"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/4,/1:2,/2/1:2)",
                actual
            )
        end)
    end)
end)
