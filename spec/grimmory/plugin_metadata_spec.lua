package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_package_meta = {

}

package.preload["_meta"] = function()
    return fake_package_meta
end

package.preload["cache"] = function()
    return {
        new = function()
            local cache = {}

            return {
                get = function(key)
                    return cache[key]
                end,
                insert = function(key, value)
                    cache[key] = value
                end
            }
        end,
    }
end

local GrimmoryPluginMetadata = require("grimmory/plugin_metadata")

describe("GrimmoryPluginMetadata", function()
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