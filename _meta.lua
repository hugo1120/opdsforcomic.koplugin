local _ = require("gettext")
return {
    version = "0.0.8",
    fullname = _("OPDS for Comic"),
    description = _([[OPDS catalog reader for comic/manga servers. Fork of the stock OPDS plugin with page-stream prefetching, auto crop, dual-page spreads, and splitting two-page scans back into single pages.]]),
}
