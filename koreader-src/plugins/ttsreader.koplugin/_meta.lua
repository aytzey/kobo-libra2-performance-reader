local _ = require("gettext")

return {
    name = "ttsreader",
    fullname = _("Audio reading"),
    description = _([[Generates cached Google Cloud Text-to-Speech audio for the current book in page chunks, then plays it back while keeping the visible page in sync.]]),
}
