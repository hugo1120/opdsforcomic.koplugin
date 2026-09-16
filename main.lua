local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local LuaSettings = require("luasettings")
local OPDSBrowser = require("opdsforcomic_browser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDS = WidgetContainer:extend{
    name = "opdsforcomic",
    settings_file = DataStorage:getSettingsDir() .. "/opdsforcomic.lua",
    settings = nil,
    opds_settings = nil,
    servers = nil,
    downloads = nil,
    pending_syncs = nil,
    updated = nil,
    default_servers = {
        {
            title = "Project Gutenberg",
            url = "https://m.gutenberg.org/ebooks.opds/?format=opds",
        },
        {
            title = "Standard Ebooks",
            url = "https://standardebooks.org/feeds/opds",
        },
        {
            title = "ManyBooks",
            url = "http://manybooks.net/opds/index.php",
        },
        {
            title = "Internet Archive",
            url = "https://bookserver.archive.org/",
        },
        {
            title = "textos.info (Spanish)",
            url = "https://www.textos.info/catalogo.atom",
        },
        {
            title = "Gallica (French)",
            url = "https://gallica.bnf.fr/opds",
        },
    },
}

--- The extension that turns a file into a door into this plugin.
---
--- Chosen to be one nothing else claims: registering a provider for it is what
--- tells the file browser the file can be opened at all, so borrowing a
--- supported extension would hijack whatever owns it.
---
--- The file is made by the reader, not by the plugin: any empty file named
--- `<anything>.opdscomic` works, and there is no button for it because it is
--- done once per device. That is also why nothing here reads the file -- the
--- extension is the whole of the mechanism, and the name is the reader's own
--- label for the shortcut.
local SHORTCUT_EXT = "opdscomic"

-- Registration is a process-wide, once-only thing but init() runs twice --
-- KOReader builds one instance of every plugin for the file manager and
-- another for the reader. A second addProvider() would only leave a duplicate
-- in the registry's array, which getProviders() collapses anyway, but one entry
-- is what was meant.
local shortcut_provider_registered = false

function OPDS:init()
    self:onDispatcherRegisterActions()
    self:registerShortcutProvider()
    self.ui.menu:registerToMainMenu(self)
end

--- Makes `<anything>.opdscomic` a file that opens this plugin.
---
--- KOReader has a mechanism for this and it involves neither a document nor the
--- reader. `FileManager:openFile` inspects the provider's `order` field, and
--- when it is set the provider counts as *auxiliary*: instead of building a
--- ReaderUI it simply calls `file_manager[provider.provider]:openFile(file)`.
--- That method is below, and `provider = self.name` is the join -- the file
--- manager registers this instance under the plugin's own name, so
--- "opdsforcomic" resolves back to us. The same trick is what makes
--- archiveviewer.koplugin and texteditor.koplugin open their own file types.
---
--- addProvider does both jobs here, which is why addAuxProvider -- the call the
--- built-in auxiliary providers make -- is absent. It marks the extension known,
--- which is what makes the browser list the file instead of hiding it behind
--- "Show unsupported files"; and it records the provider under its key, which is
--- what getAuxProviders() and the per-file-type association read. The built-in
--- ones need the extra call because the extensions they answer for (zip, txt)
--- belong to other providers already, so addProvider is not theirs to make.
function OPDS:registerShortcutProvider()
    if shortcut_provider_registered then return end
    shortcut_provider_registered = true
    DocumentRegistry:addProvider(SHORTCUT_EXT, "application/x-opds-comic", {
        provider_name = _("OPDS catalog (Comic)"),
        provider = self.name,
        -- The presence of `order` is the whole signal that this is auxiliary;
        -- its value only orders the "Open with" list.
        order = 30,
        disable_file = true,
        disable_type = false,
    }, 100)
end

--- Where a tap on a shortcut ends up, instead of on a document.
---
--- `file` goes unused: every shortcut opens the same catalog browser, and the
--- file's name is the reader's own label for it. Reading the file's contents to
--- pick a server -- one shortcut per catalog -- is the obvious next step and is
--- deliberately not taken until somebody wants it.
function OPDS:openFile(file)
    self:onShowOPDSForComicCatalog()
end

function OPDS:loadSettings()
    if self.settings then return end
    self.settings = LuaSettings:open(self.settings_file)
    if next(self.settings.data) == nil then
        self.updated = true -- first run, force flush
    end
    self.opds_settings = self.settings:readSetting("settings", {})
    self.servers = self.settings:readSetting("servers", self.default_servers)
    self.downloads = self.settings:readSetting("downloads", {})
    self.pending_syncs = self.settings:readSetting("pending_syncs", {})
end

function OPDS:onDispatcherRegisterActions()
    Dispatcher:registerAction("opdsforcomic_show_catalog",
        {category="none", event="ShowOPDSForComicCatalog", title=_("OPDS Catalog (Comic)"), filemanager=true,}
    )
end

function OPDS:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        menu_items.opdsforcomic = {
            text = _("OPDS catalog (Comic)"),
            sorting_hint = "search",
            callback = function()
                self:onShowOPDSForComicCatalog()
            end,
        }
        -- Making a shortcut is deliberately not offered here, or anywhere: it
        -- is done once to set a device up, and this menu is opened on the way
        -- to reading. A file named `<anything>.opdscomic` is all it takes --
        -- see SHORTCUT_EXT.
    end
end

function OPDS:onShowOPDSForComicCatalog()
    self:loadSettings()
    self.opds_browser = OPDSBrowser:new{
        settings = self.opds_settings,
        servers = self.servers,
        downloads = self.downloads,
        pending_syncs = self.pending_syncs,
        title = _("OPDS catalog (Comic)"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        _manager = self,
        file_downloaded_callback = function(file)
            self:showFileDownloadedDialog(file)
        end,
        close_callback = function()
            if self.opds_browser.download_list then
                self.opds_browser.download_list.close_callback()
            end
            UIManager:close(self.opds_browser)
            self.opds_browser = nil
            if self.last_downloaded_file then
                if self.ui.file_chooser then
                    local pathname = util.splitFilePathName(self.last_downloaded_file)
                    self.ui.file_chooser:changeToPath(pathname, self.last_downloaded_file)
                end
                self.last_downloaded_file = nil
            end
        end,
    }
    UIManager:show(self.opds_browser)
end

function OPDS:showFileDownloadedDialog(file)
    self.last_downloaded_file = file
    local confirm_box = ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"), BD.filepath(file)),
        ok_text = _("Read now"),
        ok_callback = function()
            self.last_downloaded_file = nil
            self.opds_browser.close_callback()
            if self.ui.document then
                self.ui:switchDocument(file)
            else
                self.ui:openFile(file)
            end
        end,
    }
    -- As the InfoMessage "Downloading" is getting closed, show this ConfirmBox on the next UI tick to avoid e-Ink rendering congestion
    UIManager:nextTick(function()
        UIManager:show(confirm_box)
    end)
end

function OPDS:onFlushSettings()
    if self.updated then
        self.settings:flush()
        self.updated = nil
    end
end

return OPDS
