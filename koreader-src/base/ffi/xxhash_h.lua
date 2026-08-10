-- Minimal xxHash declarations used by Lua cache hotpaths.

local ffi = require("ffi")

ffi.cdef[[
typedef unsigned long long XXH64_hash_t;
typedef struct {
    unsigned char digest[8];
} XXH64_canonical_t;
XXH64_hash_t XXH3_64bits(const void *input, size_t length);
void XXH64_canonicalFromHash(XXH64_canonical_t *dst, XXH64_hash_t hash);
]]
