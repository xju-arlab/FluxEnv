-- FluxEnv installation helper, not part of the user's NeoVim configuration.
-- The check mode runs with -u NONE and never starts plugins or downloads.
local manifest_path = vim.fn.stdpath("data") .. "/fluxenv-ready.json"

local function check()
    local manifest = vim.json.decode(table.concat(vim.fn.readfile(manifest_path), "\n"))
    assert(manifest.schema == 1 and #manifest.paths > 0, "Invalid NeoVim installation record")
    for _, path in ipairs(manifest.paths) do
        assert(vim.uv.fs_stat(path), "Missing NeoVim resource: " .. path)
    end
    for _, path in ipairs(manifest.executables) do
        assert(vim.fn.executable(path) == 1, "Missing NeoVim executable: " .. path)
    end
end

local function install()
    assert(vim.v.errmsg == "", "NeoVim startup failed: " .. vim.v.errmsg)
    local lazy = require("lazy")
    local lockfile = require("lazy.core.config").options.lockfile
    -- Lazy's initial automatic install can rewrite the lock file. The runner
    -- captures its contents before startup so the requested commits survive.
    local lock = vim.json.decode(table.concat(vim.g.fluxenv_install_lock or vim.fn.readfile(lockfile), "\n"))
    lazy.install({ wait = true, show = false })
    local plugins = require("lazy.core.config").plugins
    local restore = false
    for name, plugin in pairs(plugins) do
        if lock[name] and lock[name].commit then
            local commit = vim.fn.system({ "git", "-C", plugin.dir, "rev-parse", "HEAD" }):gsub("%s+$", "")
            restore = restore or commit ~= lock[name].commit
        end
    end
    if restore then
        local manager = require("lazy.manage.lock")
        manager.load()
        for name, entry in pairs(lock) do
            manager.lock[name] = entry
        end
        lazy.restore({ wait = true, show = false })
    end
    local paths = {}
    for name, plugin in pairs(plugins) do
        assert(vim.uv.fs_stat(plugin.dir), "Plugin installation failed: " .. name)
        for _, task in ipairs(plugin._.tasks or {}) do
            assert(not task:has_errors(), "Plugin build failed: " .. name)
        end
        paths[#paths + 1] = plugin.dir
    end

    lazy.load({ plugins = { "mason.nvim", "mason-lspconfig.nvim", "nvim-treesitter" } })
    local registry = require("mason-registry")
    local refreshed, refresh_ok = false, false
    registry.refresh(function(ok)
        refresh_ok, refreshed = ok, true
    end)
    assert(vim.wait(120000, function() return refreshed end, 100), "Mason registry refresh timed out")
    assert(refresh_ok, "Mason registry download failed")

    local package_names = {}
    local function add_package(name)
        package_names[name] = true
    end
    for _, name in ipairs(LazyVim.opts("mason.nvim").ensure_installed or {}) do
        add_package(name)
    end
    local mappings = require("mason-lspconfig.mappings").get_mason_map().lspconfig_to_package
    for server, opts in pairs(LazyVim.opts("nvim-lspconfig").servers or {}) do
        if mappings[server] and opts ~= false and (type(opts) ~= "table" or (opts.enabled ~= false and opts.mason ~= false)) then
            add_package(mappings[server])
        end
    end
    local packages = {}
    local failures = {}
    local forced = {}
    local mason_root = require("mason.settings").current.install_root_dir
    local function package_ready(package)
        if not package:is_installed() then
            return false
        end
        local receipt = package:get_receipt():or_else(nil)
        if not receipt then
            return false
        end
        for name in pairs(receipt.links.bin or {}) do
            if vim.fn.executable(mason_root .. "/bin/" .. name) ~= 1 then
                return false
            end
        end
        return true
    end
    for name in pairs(package_names) do
        local package = registry.get_package(name)
        packages[#packages + 1] = package
        package:on("install:failed", function()
            -- LazyVim may have started an automatic install before this helper.
            -- Retry it once with force to repair leftover links after a failure.
            if not forced[name] then
                forced[name] = true
                vim.schedule(function() package:install({ force = true }) end)
            else
                failures[name] = true
            end
        end)
        if not package_ready(package) and not package:is_installing() then
            print("Installing language tool: " .. name)
            forced[name] = true
            package:install({ force = true })
        end
    end
    assert(vim.wait(1800000, function()
        if next(failures) then
            return true
        end
        for _, package in ipairs(packages) do
            if not package_ready(package) then
                return false
            end
        end
        return true
    end, 200), "Language tool installation timed out")
    assert(not next(failures), "Language tool installation failed: " .. table.concat(vim.tbl_keys(failures), ", "))

    local executables = {}
    for _, package in ipairs(packages) do
        assert(package:is_installed(), "Language tool missing: " .. package.name)
        paths[#paths + 1] = mason_root .. "/packages/" .. package.name .. "/mason-receipt.json"
        local receipt = assert(package:get_receipt():or_else(nil), "Language tool receipt missing: " .. package.name)
        for name in pairs(receipt.links.bin or {}) do
            executables[#executables + 1] = mason_root .. "/bin/" .. name
        end
    end

    local treesitter = require("nvim-treesitter")
    local parsers = vim.deepcopy(LazyVim.opts("nvim-treesitter").ensure_installed or {})
    if not vim.tbl_contains(parsers, "cpp") then
        parsers[#parsers + 1] = "cpp"
    end
    treesitter.install(parsers, { summary = true }):wait(600000)
    local installed = treesitter.get_installed()
    local parser_dir = require("nvim-treesitter.config").get_install_dir("parser")
    for _, lang in ipairs(parsers) do
        assert(vim.tbl_contains(installed, lang), "Tree-sitter parser installation failed: " .. lang)
        paths[#paths + 1] = parser_dir .. "/" .. lang .. ".so"
    end

    vim.fn.writefile({ vim.json.encode({ schema = 1, paths = paths, executables = executables }) }, manifest_path)
    check()
    print("NeoVim ready: plugins, language tools and " .. #parsers .. " parsers")
end

local ok, err = xpcall(function()
    if vim.env.FLUXENV_NVIM_MODE == "check" then
        check()
    else
        install()
    end
end, debug.traceback)
if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit 1")
end
