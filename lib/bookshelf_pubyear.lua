-- bookshelf_pubyear.lua
-- Publication year for a book, for the %published_year token.
--
-- Why this exists rather than a field read off Calibre: the metadata.calibre
-- that Calibre writes ONTO a device is a short form (title / authors /
-- author_sort / series / series_index / tags / lpath / uuid / size /
-- last_modified) -- no publication date. Nor does KOReader have one to offer:
-- crengine's document properties (DOC_PROP_* in lvtinydom.h) cover title,
-- authors, language, description, keywords, identifiers and series, and stop
-- there, so <dc:date> is never parsed out of the OPF at all.
--
-- The date IS in the book, though: every EPUB carries <dc:date> in its OPF.
-- So we read it from the file itself, which also means it works for libraries
-- that never met Calibre.
--
-- The pure parsers below are separated from the archive access on purpose:
-- they carry the fiddly bits (which date wins, what a year even looks like)
-- and are unit-testable without libarchive or a device.

local PubYear = {}

-- A year we're willing to believe. Calibre stamps unknown dates with its
-- UNDEFINED_DATE sentinel -- year 101 -- and unfiltered every dateless book
-- would claim to be from antiquity. The oldest printed book in a real library
-- postdates 1000 by centuries, so the floor costs nothing real. The ceiling
-- catches a nonsense parse rather than showing a book from the year 9999.
local YEAR_MIN, YEAR_MAX = 1000, 2200

--- Year out of an ISO-8601-ish date string ("2019-09-16T23:00:00+00:00",
--- "1997-04-14", "2019"). Returns a string, or nil when there's no credible
--- year in there -- including Calibre's literal "None" and its year-101
--- sentinel.
function PubYear.yearFromISO(s)
    if type(s) ~= "string" then return nil end
    -- Leading year, optionally followed by -MM-DD and a time. Anchored so
    -- "None" and other free text can't accidentally yield a number.
    local y = s:match("^%s*(%d%d%d%d)%f[%D]") or s:match("^%s*(%d+)%-")
    local n = tonumber(y)
    if not n or n < YEAR_MIN or n > YEAR_MAX then return nil end
    return tostring(n)
end

--- Year out of an OPF (the EPUB metadata file), as a string or nil.
---
--- EPUB 2 may carry several <dc:date> elements distinguished by opf:event
--- ("publication", "modification", "creation"); EPUB 3 carries a single
--- <dc:date> (the publication date) plus a separate dcterms:modified meta.
--- So: prefer an explicit publication date, else the first date that is not a
--- modification -- taking "modification" would date a book to whenever its
--- file was last touched, which for a Calibre-converted library is often
--- today, and would make the token actively wrong rather than merely empty.
function PubYear.yearFromOPF(xml)
    if type(xml) ~= "string" then return nil end
    local first, publication
    -- Match each dc:date element with its attributes; namespace prefix varies
    -- (dc:date, DC:date, or bare date in sloppy files).
    for attrs, body in xml:gmatch("<[%w]*:?[Dd][Aa][Tt][Ee]([^>]*)>(.-)</[%w]*:?[Dd][Aa][Tt][Ee]>") do
        local event = attrs:match("[Ee][Vv][Ee][Nn][Tt]%s*=%s*[\"']([^\"']*)[\"']")
        local year = PubYear.yearFromISO(body)
        if year then
            if event and event:lower():find("publication", 1, true) then
                publication = publication or year
            elseif not (event and event:lower() == "modification") then
                first = first or year
            end
        end
    end
    return publication or first
end

--- The OPF's path inside an EPUB, given the container.xml. Falls back to nil
--- so the caller can go looking for a *.opf entry itself.
function PubYear.opfPathFromContainer(xml)
    if type(xml) ~= "string" then return nil end
    local path = xml:match("[Rr][Oo][Oo][Tt]%-?[Ff][Ii][Ll][Ee][^>]-[Ff][Uu][Ll][Ll]%-[Pp][Aa][Tt][Hh]%s*=%s*[\"']([^\"']+)[\"']")
    if path and path ~= "" then return path end
    return nil
end

-- filepath -> year string, or false for "looked, found nothing". Caching the
-- misses matters as much as the hits: without it every shelf repaint would
-- re-open the same dateless EPUBs. Cleared via PubYear.invalidate().
local _cache = {}

--- Publication year read out of an EPUB, as a string or nil.
--- Opens the file as an archive and reads only the OPF -- no full unpack.
function PubYear.fromEpub(filepath)
    if type(filepath) ~= "string" or filepath == "" then return nil end
    local hit = _cache[filepath]
    if hit ~= nil then return hit or nil end

    -- Only container formats we can read this way. PDFs and friends have no OPF.
    local lower = filepath:lower()
    if not (lower:match("%.epub$") or lower:match("%.kepub%.epub$")) then
        _cache[filepath] = false
        return nil
    end

    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not (ok_req and Archiver and Archiver.Reader) then
        -- No extractor (older core, or the desktop test harness): stay silent
        -- and leave the token empty rather than erroring on every book. NOT
        -- cached -- a later call on a device that has it should still work.
        return nil
    end

    local year
    local ok = pcall(function()
        local arc = Archiver.Reader:new()
        if not arc:open(filepath) then return end
        -- Reader:seek() resolves a path through the entry table, and that only
        -- fills while iterating -- so walk the entries first and note the OPF
        -- as we pass it. Stop at the first one: it is the package document in
        -- every EPUB seen in the wild, and walking on costs a full scan.
        local opf_path, container
        for entry in arc:iterate() do
            if entry.mode == "file" then
                local p = entry.path
                if p == "META-INF/container.xml" then
                    container = p
                elseif not opf_path and p:lower():match("%.opf$") then
                    opf_path = p
                    break
                end
            end
        end
        -- container.xml is the spec-sanctioned way to find the package
        -- document; the *.opf scan above is the fallback for the rare book
        -- whose OPF sorts after the content.
        if not opf_path and container then
            local cx = arc:extractToMemory(container)
            opf_path = cx and PubYear.opfPathFromContainer(cx)
        end
        if opf_path then
            local xml = arc:extractToMemory(opf_path)
            year = xml and PubYear.yearFromOPF(xml)
        end
        arc:close()
    end)
    if not ok then year = nil end

    _cache[filepath] = year or false
    return year
end

--- Drop the cache (a book's file changed, or the library was rescanned).
--- With no argument, drops everything.
function PubYear.invalidate(filepath)
    if filepath then _cache[filepath] = nil else _cache = {} end
end

return PubYear
