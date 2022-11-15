local M = {}

local features = require "bigfile.features"

---@class rule
---@field size integer file size in MiB
---@field pattern string|string[] see |autocmd-pattern|
---@field features string[] array of features

---@class config
---@field rules rule[] rules
local config = {
  rules = {
    {
      size = 1,
      pattern = { "*" },
      features = {
        "indent_blankline",
        "illuminate",
        "lsp",
        "treesitter",
        "syntax",
        "matchparen",
        "vimopts",
      },
    },
    { size = 5, pattern = { "*" }, features = { "filetype" } },
  },
}

---@param bufnr number
---@return integer|nil size in MiB if buffer is valid, nil otherwise
local function get_buf_size(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, stats = pcall(function()
    return vim.loop.fs_stat(vim.api.nvim_buf_get_name(bufnr))
  end)
  if not (ok and stats) then
    return
  end
  return math.floor(0.5 + (stats.size / (1024 * 1024)))
end

---@param bufnr number buffer id to match against
---@return feature[] features Features from rules that match the `filesize`
local function get_features(bufnr, rule)
  local matched_features = {}
  local filesize = get_buf_size(bufnr)
  if not filesize then
    return matched_features
  end
  if filesize >= rule.size then
    for _, raw_feature in ipairs(rule.features) do
      matched_features[#matched_features + 1] = features.get_feature(raw_feature)
    end
  else -- since rules should be sorted, we can exit early
    return matched_features
  end
  return matched_features
end

local function pre_bufread_callback(bufnr, rule)
  local status_ok, detected = pcall(vim.api.nvim_buf_get_var, bufnr, "bigfile_detected")
  if status_ok and detected == 1 then
    return -- buffer has already been processed
  end

  local matched_features = get_features(bufnr, rule)

  -- Categorize features and disable features that don't need deferring
  local matched_deferred_features = {}
  for _, feature in ipairs(matched_features) do
    if feature.opts.defer then
      table.insert(matched_deferred_features, feature)
    else
      feature.disable(bufnr)
    end
  end

  -- Schedule disabling deferred features
  vim.api.nvim_create_autocmd({ "BufReadPost" }, {
    callback = function()
      if #matched_features > 0 then
        vim.api.nvim_buf_set_var(bufnr, "bigfile_detected", 1)
      end

      for _, feature in ipairs(matched_deferred_features) do
        feature.disable(bufnr)
      end
    end,
    buffer = bufnr,
  })

  vim.api.nvim_buf_set_var(bufnr, "bigfile_detected", 0)
end

---@param user_config config|nil
function M.setup(user_config)
  if type(user_config) == "table" then
    if user_config.rules then
      config.rules = user_config.rules
    end
  end

  local treesitter_configs = require "nvim-treesitter.configs"
  treesitter_configs.setup {
    highlight = {
      disable = function(_, buf)
        return pcall(vim.api.nvim_buf_get_var, buf, "bigfile_treesitter_disabled")
      end,
    },
  }

  vim.api.nvim_create_augroup("bigfile", {})

  for _, rule in ipairs(config.rules) do
    vim.api.nvim_create_autocmd("BufReadPre", {
      pattern = rule.pattern,
      group = "bigfile",
      callback = function(args)
        pre_bufread_callback(args.buf, rule)
      end,
      desc = string.format("Performance rule for handling files over %sMiB", rule.size),
    })
  end
end

return M
