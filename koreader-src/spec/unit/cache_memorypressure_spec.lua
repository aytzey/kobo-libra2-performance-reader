describe("Cache memory pressure", function()
    local Cache, util
    local old_calc_free_mem

    setup(function()
        require("commonrequire")
        Cache = require("cache")
        util = require("util")
    end)

    before_each(function()
        old_calc_free_mem = util.calcFreeMem
    end)

    after_each(function()
        util.calcFreeMem = old_calc_free_mem
    end)

    it("reports available memory without evicting when cache is healthy", function()
        local cache = Cache:new{ slots = 4 }
        cache.cache:set("a", true)
        cache.cache:set("b", true)
        util.calcFreeMem = function()
            return 300, 1000
        end

        local state = cache:memoryPressureCheck{ force = true, min_interval = 0 }

        assert.is_false(state.pressured)
        assert.is_false(state.critical)
        assert.are.equal(2, cache.cache:used_slots())
    end)

    it("keeps only the hottest quarter when memory pressure is critical", function()
        local cache = Cache:new{ slots = 8 }
        for i = 1, 8 do
            cache.cache:set("key" .. i, i)
        end
        util.calcFreeMem = function()
            return 100, 1000
        end

        local state = cache:memoryPressureCheck{ force = true, min_interval = 0 }

        assert.is_true(state.pressured)
        assert.is_true(state.critical)
        assert.are.equal(2, cache.cache:used_slots())
    end)
end)
