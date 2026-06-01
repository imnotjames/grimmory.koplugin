local assert = require 'luassert'
local match = require 'luassert.match'
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
                get = function(key)
                    return fake_cache[key]
                end,
                insert = function(key, value)
                    fake_cache[key] = value
                end
            }
        end,
    }
end

local fake_doc_settings = {}

package.preload["docsettings"] = function()
    return {
        open = function()
            return fake_doc_settings
        end
    }
end

package.preload["document/documentregistry"] = function()
    return {
        hasProvider = spy.new(function() return false end),
    }
end

package.preload["util"] = function()
    return {
        partialMD5 = function() return "example" end
    }
end

local GrimmoryDocMetadata = require("grimmory/doc_metadata")

describe("GrimmoryDocMetadata", function()
    before_each(function()
        fake_doc_settings["readSetting"] = stub:new({}, "readSetting")
    end)

    describe("getIdentifier", function()
        it("reads value", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "foo:bar"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getIdentifier("example", "foo")
            assert.are.equal("bar", actual)
        end)

        it("allows special characters in key", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "^foo*:b ar:baz"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getIdentifier("example", "^foo*:b ar")
            assert.are.equal("baz", actual)
        end)

        it("uses last value when duplicates", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "foo:bar\nfoo:baz"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getIdentifier("example", "foo")
            assert.are.equal("baz", actual)
        end)

        it("handles missing identifiers doc prop", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({})

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getISBN("example")
            assert.are.equal(nil, actual)
        end)
    end)

    describe("getISBN", function()
        it("is nil when no ISBN", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = ""
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getISBN("example")
            assert.are.equal(nil, actual)
        end)

        it("reads urn:isbn identifier", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "urn:isbn:1234"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getISBN("example")
            assert.are.equal("1234", actual)
        end)

        it("prioritizes isbn13 identifier", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "isbn:4567\nisbn13:1234"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getISBN("example")
            assert.are.equal("1234", actual)
        end)
    end)

    describe("getASIN", function()
        it("reads urn:amazon", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "urn:amazon:ABC123"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getASIN("example")
            assert.are.equal("ABC123", actual)
        end)

        it("prioritizes amazon over urn:amazon", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "mobi-asin:DEF456\namazon:ABC123"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getASIN("example")
            assert.are.equal("ABC123", actual)
        end)

        it("reads amazon asin", function()
            fake_doc_settings.readSetting
                .on_call_with(match._, "doc_props")
                .returns({
                    identifiers = "amazon:ABC123"
                })

            local metadata = GrimmoryDocMetadata:new()

            local actual = metadata:getASIN("example")
            assert.are.equal("ABC123", actual)
        end)
    end)
end)