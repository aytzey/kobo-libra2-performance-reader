--[[--
LuaJIT FFI wrapper for xxHash.

@module ffi.xxhash
--]]

local ffi = require("ffi")
local bin_to_hex = require("ffi/sha2").bin_to_hex

require("ffi/xxhash_h")

local xxh = ffi.loadlib("xxhash", "0")
local canonical = ffi.new("XXH64_canonical_t[1]")

local xxhash = {}

function xxhash.xxh3_64_hex(str)
    xxh.XXH64_canonicalFromHash(canonical, xxh.XXH3_64bits(str, #str))
    return bin_to_hex(ffi.string(canonical[0].digest, 8))
end

return xxhash
