-- tests/_test_pubyear.lua
-- The pure parsers behind %published_year. The archive access in
-- PubYear.fromEpub needs libarchive and a real file, so it is device-tested;
-- everything that decides WHICH date wins and WHAT counts as a year lives in
-- these functions and is checked here.
--
-- Sample values are taken from a real 559-book Calibre library.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq
local PubYear = dofile("lib/bookshelf_pubyear.lua")

-- ── yearFromISO ─────────────────────────────────────────────────────────────
t.test("ISO: full Calibre timestamp", function()
    eq(PubYear.yearFromISO("1997-04-14T22:00:00+00:00"), "1997")
end)

t.test("ISO: bare date and bare year", function()
    eq(PubYear.yearFromISO("2012-10-17"), "2012")
    eq(PubYear.yearFromISO("2019"), "2019")
end)

-- Calibre writes the STRING "None" for books with no date -- 120 of the 137
-- entries in the sample library. Yielding a number here would be worse than
-- yielding nothing.
t.test("ISO: Calibre's \"None\" is not a year", function()
    eq(PubYear.yearFromISO("None"), nil)
end)

-- Calibre's UNDEFINED_DATE sentinel. Unfiltered, every dateless book would
-- claim to come from antiquity.
t.test("ISO: year-101 sentinel is rejected", function()
    eq(PubYear.yearFromISO("0101-01-01T00:00:00+00:00"), nil)
end)

t.test("ISO: junk and wrong types yield nil", function()
    eq(PubYear.yearFromISO(""), nil)
    eq(PubYear.yearFromISO("undefined"), nil)
    eq(PubYear.yearFromISO(nil), nil)
    eq(PubYear.yearFromISO(1997), nil)
end)

-- A digit run that is not a year must not be sliced into one.
t.test("ISO: 8-digit run is not read as a year", function()
    eq(PubYear.yearFromISO("20190916"), nil)
end)

-- ── yearFromOPF ─────────────────────────────────────────────────────────────
t.test("OPF: EPUB 3 single dc:date", function()
    eq(PubYear.yearFromOPF([[
        <metadata><dc:title>X</dc:title>
        <dc:date>2019-09-16T23:00:00+00:00</dc:date></metadata>]]), "2019")
end)

-- The one that matters most: taking the modification date would date a
-- Calibre-converted book to whenever its file was last written -- often today.
t.test("OPF: publication wins over modification", function()
    eq(PubYear.yearFromOPF([[
        <dc:date opf:event="modification">2026-08-14</dc:date>
        <dc:date opf:event="publication">1983-08-15</dc:date>]]), "1983")
end)

t.test("OPF: modification alone yields nothing", function()
    eq(PubYear.yearFromOPF([[<dc:date opf:event="modification">2026-08-14</dc:date>]]), nil)
end)

t.test("OPF: undated element falls through to the next", function()
    eq(PubYear.yearFromOPF([[
        <dc:date>None</dc:date>
        <dc:date>2006-04-20T07:00:00+00:00</dc:date>]]), "2006")
end)

t.test("OPF: namespace prefix and case vary between producers", function()
    eq(PubYear.yearFromOPF([[<date>1990-12-01</date>]]), "1990")
    eq(PubYear.yearFromOPF([[<DC:DATE>1988-02-14</DC:DATE>]]), "1988")
end)

t.test("OPF: no date at all, and wrong types", function()
    eq(PubYear.yearFromOPF("<metadata><dc:title>X</dc:title></metadata>"), nil)
    eq(PubYear.yearFromOPF(nil), nil)
end)

-- ── opfPathFromContainer ────────────────────────────────────────────────────
t.test("container: reads the root-file path", function()
    eq(PubYear.opfPathFromContainer([[<?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf"
                      media-type="application/oebps-package+xml"/>
          </rootfiles></container>]]), "OEBPS/content.opf")
end)

t.test("container: single quotes and no folder", function()
    eq(PubYear.opfPathFromContainer([[<rootfile full-path='content.opf'/>]]), "content.opf")
end)

t.test("container: malformed yields nil, not a crash", function()
    eq(PubYear.opfPathFromContainer("<container></container>"), nil)
    eq(PubYear.opfPathFromContainer(nil), nil)
end)

-- ── fromEpub guards ─────────────────────────────────────────────────────────
-- The archive path can't run here (no libarchive), but the guards in front of
-- it must not blow up under a plain interpreter.
t.test("fromEpub: rejects non-EPUB and bad input without erroring", function()
    eq(PubYear.fromEpub("/books/manual.pdf"), nil)
    eq(PubYear.fromEpub(""), nil)
    eq(PubYear.fromEpub(nil), nil)
end)

t.done()
