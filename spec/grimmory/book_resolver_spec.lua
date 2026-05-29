package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["grimmory/logger"] = function()
    return {
        new = function()
            return {
                dbg = function() end
            }
        end
    }
end

package.preload["grimmory/doc_metadata"] = function()
    return {
        getISBN = function()
            return "example-isbn"
        end,
        getASIN = function()
            return "example-asin"
        end,
        getTitle = function()
            return "example-title"
        end,
        getAuthor = function()
            return "example-author"
        end,
        getGrimmoryId = function()
            return nil
        end
    }
end
package.preload["util"] = function()
    return {
        partialMD5 = function()
            return "example-md5"
        end,
        splitFilePathName = function()
            return "example-path", "example-filename"
        end
    }
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

local GrimmoryBookResolver = require("grimmory/book_resolver")

describe("GrimmoryBookResolver", function()
    it("returns nil with no match", function()
        local resolver = GrimmoryBookResolver:new()

        local actual = resolver:getBookId("example-path")

        assert.is_nil(actual)
    end)

    it("returns book ID with ISBN match", function()
        local resolver = GrimmoryBookResolver:new()

        resolver:refreshBooks({
            {
                id = 1,
                metadata = {
                    isbn10 = "example-isbn"
                }
            }
        })

        local actual = resolver:getBookId("example-path")

        assert.are.equal(actual, 1)
    end)
end)