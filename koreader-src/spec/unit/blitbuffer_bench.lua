require("commonrequire")

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local util = require("ffi/util")

local function now()
    local secs, usecs = util.gettime()
    return secs + usecs / 1000000
end

local function elapsedMs(start_time)
    return (now() - start_time) * 1000
end

local function bench(name, iterations, fn)
    fn()
    local start_time = now()
    for _ = 1, iterations do
        fn()
    end
    local ms = elapsedMs(start_time)
    print(string.format("Blitbuffer benchmark: %s (%.3f ms)", name, ms))
end

local function fillBB8AAlphaPattern(bb)
    local data = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    for y = 0, bb:getHeight() - 1 do
        local row = y * stride
        for x = 0, bb:getWidth() - 1 do
            local off = row + x * 2
            data[off] = (x * 23 + y * 41) % 256
            data[off + 1] = ({0x00, 0x80, 0xFF})[(x + y) % 3 + 1]
        end
    end
end

local function fillRGB32AlphaPattern(bb)
    local data = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    for y = 0, bb:getHeight() - 1 do
        local row = y * stride
        for x = 0, bb:getWidth() - 1 do
            local off = row + x * 4
            data[off] = (x * 29 + y * 17) % 256
            data[off + 1] = (x * 47 + y * 11) % 256
            data[off + 2] = (x * 13 + y * 53) % 256
            data[off + 3] = ({0x00, 0x80, 0xFF})[(x + y) % 3 + 1]
        end
    end
end

describe("Blitbuffer benchmark:", function()
    setup(function()
        Blitbuffer:enableCBB(true)
    end)

    it("same type copy", function()
        local src = Blitbuffer.new(1404, 1872, Blitbuffer.TYPE_BB8)
        local dst = Blitbuffer.new(1404, 1872, Blitbuffer.TYPE_BB8)

        bench("bb8_to_bb8", 80, function()
            dst:blitFrom(src)
        end)
    end)

    it("color to grayscale", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BBRGB32)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)

        bench("rgb32_to_bb8", 40, function()
            dst:blitFrom(src)
        end)
    end)

    it("alpha grayscale to grayscale", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8A)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)

        bench("bb8a_to_bb8", 40, function()
            dst:blitFrom(src)
        end)
    end)

    it("grayscale to color", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BBRGB32)

        bench("bb8_to_rgb32", 40, function()
            dst:blitFrom(src)
        end)
    end)

    it("alpha grayscale to color", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8A)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BBRGB32)

        bench("bb8a_to_rgb32", 40, function()
            dst:blitFrom(src)
        end)
    end)

    it("alpha grayscale over grayscale", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8A)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)
        fillBB8AAlphaPattern(src)

        bench("bb8a_alpha_to_bb8", 20, function()
            dst:alphablitFrom(src)
        end)
    end)

    it("alpha color over grayscale", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BBRGB32)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)
        fillRGB32AlphaPattern(src)

        bench("rgb32_alpha_to_bb8", 20, function()
            dst:alphablitFrom(src)
        end)
    end)

    it("dithered color to grayscale", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BBRGB32)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)

        bench("rgb32_to_bb8_dither", 20, function()
            dst:ditherblitFrom(src)
        end)
    end)

    it("dithered grayscale to grayscale", function()
        local src = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)

        bench("bb8_to_bb8_dither", 20, function()
            dst:ditherblitFrom(src)
        end)
    end)

    it("grayscale blend rect", function()
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)

        bench("bb8_blend_rect", 800, function()
            dst:darkenRect(80, 160, 800, 80, 0.5)
        end)
    end)

    it("alpha grayscale blend rect", function()
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8A)

        bench("bb8a_blend_rect", 800, function()
            dst:darkenRect(80, 160, 800, 80, 0.5)
        end)
    end)

    it("grayscale multiply rect", function()
        local dst = Blitbuffer.new(960, 1280, Blitbuffer.TYPE_BB8)
        local color = Blitbuffer.ColorRGB24(140, 140, 140)

        bench("bb8_multiply_rect", 800, function()
            dst:multiplyRectRGB(80, 160, 800, 80, color)
        end)
    end)
end)
