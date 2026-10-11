-- FluxEnv appearance overlay; language tooling stays in Config-NeoVim.
local apple_terminal = vim.env.TERM_PROGRAM == "Apple_Terminal" and not vim.g.neovide and not vim.g.GuiLoaded
local color_cache = {}

if apple_terminal then
  vim.opt.termguicolors = false
end

-- Use the fixed 256-color cube and grayscale ramp, avoiding custom ANSI slots.
local function terminal_color(color)
  if type(color) == "string" then
    color = tonumber(color:gsub("^#", ""), 16)
  end
  if type(color) ~= "number" then
    return nil
  end
  if color_cache[color] then
    return color_cache[color]
  end
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256
  local levels = { 0, 95, 135, 175, 215, 255 }
  local best, distance = 16, math.huge
  for index = 16, 255 do
    local cr, cg, cb
    if index < 232 then
      local cube = index - 16
      cr = levels[math.floor(cube / 36) + 1]
      cg = levels[math.floor(cube / 6) % 6 + 1]
      cb = levels[cube % 6 + 1]
    else
      cr = 8 + (index - 232) * 10
      cg, cb = cr, cr
    end
    local delta = (r - cr) ^ 2 + (g - cg) ^ 2 + (b - cb) ^ 2
    if delta < distance then
      best, distance = index, delta
    end
  end
  color_cache[color] = best
  return best
end

local function add_terminal_colors(highlights)
  for _, hl in pairs(highlights) do
    if type(hl) == "table" and not hl.link then
      hl.ctermfg = terminal_color(hl.fg) or hl.ctermfg
      hl.ctermbg = terminal_color(hl.bg) or hl.ctermbg
    end
  end
end

local function adapt_terminal()
  if not apple_terminal then
    return
  end
  -- TokyoNight enables RGB on load; switch back after ColorScheme, before UI plugins.
  vim.opt.termguicolors = false
  local highlights = vim.api.nvim_get_hl(0, {})
  add_terminal_colors(highlights)
  for name, hl in pairs(highlights) do
    if not hl.link then
      vim.api.nvim_set_hl(0, name, hl)
    end
  end
end

return {
  {
    "LazyVim/LazyVim",
    opts = { colorscheme = "tokyonight" },
    init = function()
      vim.opt.background = "dark"
      local group = vim.api.nvim_create_augroup("FluxEnvAppearance", { clear = true })
      vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = adapt_terminal })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "VeryLazy",
        callback = function()
          vim.schedule(adapt_terminal)
        end,
      })
    end,
  },
  {
    "folke/tokyonight.nvim",
    opts = {
      on_colors = function(colors)
        colors.fg = "#dce4f2"
        colors.fg_dark = "#b6c2d9"
        colors.comment = "#909cb3"
        colors.dark3 = "#8796b0"
      end,
      on_highlights = function(hl, colors)
        hl.NormalNC = { fg = colors.fg, bg = colors.bg }
        hl.SnacksPickerGitStatusUntracked = { fg = colors.purple }
        if apple_terminal then
          add_terminal_colors(hl)
        end
      end,
    },
  },
}
