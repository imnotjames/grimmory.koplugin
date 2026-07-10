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

package.preload["gettext"] = function()
    return function(text)
        return text
    end
end

package.preload["pluginloader"] = function()
    return {
        _discover = function() return {} end
    }
end

package.preload["datastorage"] = function()
    return {

    }
end

local fake_package_meta = {}

local GrimmoryPluginMetadata = require("grimmory/plugin_metadata")

describe("GrimmoryPluginMetadata", function()
    local original_get_meta = nil

    before_each(function()
        original_get_meta = GrimmoryPluginMetadata.getMeta

        GrimmoryPluginMetadata.getMeta = function()
            return fake_package_meta
        end
    end)

    after_each(function()
        GrimmoryPluginMetadata.getMeta = original_get_meta
    end)

    describe("hasRepository", function()
        it("returns false when repository field is missing", function()
            assert.are.equal(GrimmoryPluginMetadata:hasRepository(), false)
        end)

        it("returns true when field is a string", function()
            fake_package_meta.repository = "example"

            assert.are.equal(GrimmoryPluginMetadata:hasRepository(), true)
        end)
    end)

    describe("getVersion", function()
        it("uses fallback when missing", function()
            fake_package_meta.version = nil

            assert.are.equal(GrimmoryPluginMetadata:getVersion(), "0.0.0-snapshot")
        end)

        it("uses fallback when not string", function()
            fake_package_meta.version = true

            assert.are.equal(GrimmoryPluginMetadata:getVersion(), "0.0.0-snapshot")
        end)

        it("uses value when string", function()
            fake_package_meta.version = "example"

            assert.are.equal(GrimmoryPluginMetadata:getVersion(), "example")
        end)
    end)

    describe("getRepository", function()
        it("uses fallback when missing", function()
            fake_package_meta.repository = nil

            assert.are.equal(GrimmoryPluginMetadata:getRepository(), "unknown repository")
        end)

        it("uses fallback when not string", function()
            fake_package_meta.repository = true

            assert.are.equal(GrimmoryPluginMetadata:getRepository(), "unknown repository")
        end)

        it("uses value when string", function()
            fake_package_meta.repository = "example"

            assert.are.equal(GrimmoryPluginMetadata:getRepository(), "example")
        end)
    end)

end)