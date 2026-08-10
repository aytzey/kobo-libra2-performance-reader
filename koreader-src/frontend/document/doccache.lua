--[[
"Global" LRU cache used by Document & friends.
--]]

local Cache = require("cache")
local CanvasContext = require("document/canvascontext")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local xxh3_64_hex = require("ffi/xxhash").xxh3_64_hex
local util = require("util")

local DHINTCOUNT = G_defaults:readSetting("DHINTCOUNT")

local function calcCacheMemSize()
    local min = G_defaults:readSetting("DGLOBAL_CACHE_SIZE_MINIMUM")
    local max = G_defaults:readSetting("DGLOBAL_CACHE_SIZE_MAXIMUM")
    local memfree, _ = util.calcFreeMem() or 0, 0
    local calc = memfree * G_defaults:readSetting("DGLOBAL_CACHE_FREE_PROPORTION")
    return math.min(max, math.max(min, calc))
end
local doccache_size = calcCacheMemSize()

local function computeCacheSize()
    local mb_size = doccache_size / 1024 / 1024

    -- If we end up with a not entirely ridiculous cache size, use that...
    if mb_size >= 8 then
        logger.dbg(string.format("Allocating a %dMB budget for the global document cache", mb_size))
        return doccache_size
    else
        return nil
    end
end

local function computeCacheSlots()
    local mb_size = doccache_size / 1024 / 1024

    --- ...otherwise, effectively disable the cache by making it single slot...
    if mb_size < 8 then
        logger.dbg("Setting up a minimal single slot global document cache")
        return 1
    else
        return nil
    end
end

-- NOTE: This is a singleton!
local DocCache = Cache:new{
    slots = computeCacheSlots(),
    size = computeCacheSize(),
    -- Average item size is a screen's worth of bitmap, mixed with a few much smaller tables (pgdim, pglinks, etc.), hence the / 3
    avg_itemsize = math.floor(CanvasContext:getWidth() * CanvasContext:getHeight() * (CanvasContext.is_color_rendering_enabled and 4 or 1) / 3),
    -- Rely on CacheItem's eviction callback to free resources *immediately* on eviction.
    enable_eviction_cb = true,
    disk_cache = true,
    cache_path = DataStorage:getDataDir() .. "/cache/",
}

function DocCache:serialize(doc_path)
    if not self.disk_cache then
        return
    end

    -- Calculate the current disk cache size
    local cached_size = 0
    local cache_files = {}
    for _, file in pairs(self.cached) do
        local attr = lfs.attributes(file)
        if attr then
            local size = attr.size or 0
            cache_files[#cache_files + 1] = {file=file, time=attr.access or 0, size=size}
            cached_size = cached_size + size
        end
    end

    -- Rewind a bit in order to serialize the currently *displayed* page for the current document,
    -- as the actual MRU item would be the most recently *hinted* page, which wouldn't be helpful ;).
    if doc_path then
        local mru_key
        local mru_found = 0
        for key, item in self.cache:pairs() do
            -- Only dump items that actually request persistence and match the current document.
            if item.persistent and item.dump and item.doc_path == doc_path then
                mru_key = key
                mru_found = mru_found + 1
                if mru_found >= (1 + DHINTCOUNT) then
                    -- We found the right item, i.e., the *displayed* page
                    break
                end
            end
        end
        if mru_key then
            local cache_full_path = self.cache_path .. xxh3_64_hex(mru_key)
            local legacy_cache_file = self.cached[md5(mru_key)]
            local cache_file_exists = lfs.attributes(cache_full_path) or legacy_cache_file

            if not cache_file_exists then
                logger.dbg("Dumping cache item", mru_key)
                local cache_item = self.cache:get(mru_key)
                local cache_size = cache_item:dump(cache_full_path)
                if cache_size then
                    cached_size = cached_size + cache_size
                end
            end
        end
    end

    -- Allocate the same amount of storage to the disk cache than the memory cache
    local max_cache_size = self.size or doccache_size
    if cached_size > max_cache_size then
        table.sort(cache_files, function(v1, v2) return v1.time > v2.time end)
    end
    while cached_size > max_cache_size do
        -- discard the least recently used cache
        local discarded = table.remove(cache_files)
        if discarded then
            cached_size = cached_size - discarded.size
            os.remove(discarded.file)
        else
            logger.warn("Cache accounting is broken")
            break
        end
    end
    -- We may have updated the disk cache's content, so refresh its state
    self:refreshSnapshot()
end

return DocCache
