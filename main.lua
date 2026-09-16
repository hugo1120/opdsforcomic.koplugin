local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
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
local SHORTCUT_EXT = "opdscomic"
local SHORTCUT_BASENAME = "OPDS for Comic"

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
--- addProvider is the half that makes the file *visible*: the browser hides
--- files whose extension no provider claims, unless the reader turns on "Show
--- unsupported files", and registering the extension is what marks it known.
--- addAuxProvider is the half that makes it findable by key, which is the path
--- the "Open with" dialog and the per-file association take.
function OPDS:registerShortcutProvider()
    if shortcut_provider_registered then return end
    shortcut_provider_registered = true
    local provider = {
        provider_name = _("OPDS catalog (Comic)"),
        provider = self.name,
        -- The presence of `order` is the whole signal that this is auxiliary;
        -- its value only orders the "Open with" list.
        order = 30,
        disable_file = true,
        disable_type = false,
    }
    DocumentRegistry:addAuxProvider(provider)
    DocumentRegistry:addProvider(SHORTCUT_EXT, "application/x-opds-comic", provider, 100)
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

--- Puts a shortcut in the folder the reader is browsing.
---
--- Empty on purpose: the extension is the entire mechanism, and a file with no
--- contents cannot be mistaken for a document by anything else. An existing
--- file is left alone, since it may have been renamed on purpose.
function OPDS:createShortcut()
    local dir = self.ui.file_chooser and self.ui.file_chooser.path
    if not dir then return end
    local filename = SHORTCUT_BASENAME .. "." .. SHORTCUT_EXT
    local path = dir .. "/" .. filename
    local existing = io.open(path, "r")
    local notice
    if existing then
        existing:close()
        notice = T(_("%1 is already here"), BD.filename(filename))
    else
        local created = io.open(path, "w")
        if not created then
            Notification:notify(_("Could not create the shortcut."))
            return
        end
        created:close()
        notice = T(_("Created %1 -- tap it to open the catalog"), BD.filename(filename))
    end
    self.ui.file_chooser:refreshPath()
    Notification:notify(notice)
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
        -- Next to the entry above on purpose: one opens the catalog now, the
        -- other leaves a file behind that opens it later without the menu.
        menu_items.opdsforcomic_shortcut = {
            text = _("Create an OPDS shortcut here"),
            sorting_hint = "search",
            callback = function()
                self:createShortcut()
            end,
        }
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
