local M = {}

local dbg = require('diffs.log').dbg

---@type table?
local cached_handle = nil

---@type boolean
local download_in_progress = false

---@type fun(handle: table?)[]
local pending_callbacks = {}

---@return string
local function get_os()
  local os_name = jit.os:lower()
  if os_name == 'osx' then
    return 'macos'
  end
  return os_name
end

---@return string
local function get_arch()
  return jit.arch:lower()
end

---@return string
local function get_ext()
  local os_name = jit.os:lower()
  if os_name == 'windows' then
    return 'dll'
  elseif os_name == 'osx' then
    return 'dylib'
  end
  return 'so'
end

---@return string
local function lib_dir()
  return vim.fn.stdpath('data') .. '/diffs/lib'
end

---@return string
local function lib_path()
  return lib_dir() .. '/libvscode_diff.' .. get_ext()
end

---@return string
local function version_path()
  return lib_dir() .. '/version'
end

local EXPECTED_VERSION = '2.18.0'

---@return boolean
function M.has_lib()
  if cached_handle then
    return true
  end
  return vim.fn.filereadable(lib_path()) == 1
end

---@return string
function M.lib_path()
  return lib_path()
end

---@return table?
function M.load()
  if cached_handle then
    return cached_handle
  end

  local path = lib_path()
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ffi = require('ffi')

  ffi.cdef([[
    typedef struct {
      int start_line;
      int end_line;
    } DiffsLineRange;

    typedef struct {
      int start_line;
      int start_col;
      int end_line;
      int end_col;
    } DiffsCharRange;

    typedef struct {
      DiffsCharRange original;
      DiffsCharRange modified;
    } DiffsRangeMapping;

    typedef struct {
      DiffsLineRange original;
      DiffsLineRange modified;
      DiffsRangeMapping* inner_changes;
      int inner_change_count;
    } DiffsDetailedMapping;

    typedef struct {
      DiffsDetailedMapping* mappings;
      int count;
      int capacity;
    } DiffsDetailedMappingArray;

    typedef struct {
      DiffsLineRange original;
      DiffsLineRange modified;
    } DiffsMovedText;

    typedef struct {
      DiffsMovedText* moves;
      int count;
      int capacity;
    } DiffsMovedTextArray;

    typedef struct {
      DiffsDetailedMappingArray changes;
      DiffsMovedTextArray moves;
      bool hit_timeout;
    } DiffsLinesDiff;

    typedef struct {
      bool ignore_trim_whitespace;
      int max_computation_time_ms;
      bool compute_moves;
      bool extend_to_subwords;
    } DiffsDiffOptions;

    DiffsLinesDiff* compute_diff(
      const char** original_lines,
      int original_count,
      const char** modified_lines,
      int modified_count,
      const DiffsDiffOptions* options
    );

    void free_lines_diff(DiffsLinesDiff* diff);
  ]])

  local ok, handle = pcall(ffi.load, path)
  if not ok then
    dbg('failed to load libvscode_diff: %s', handle)
    return nil
  end

  cached_handle = handle
  return handle
end

---@param callback fun(handle: table?)
function M.ensure(callback)
  if cached_handle then
    callback(cached_handle)
    return
  end

  if M.has_lib() then
    callback(M.load())
    return
  end

  table.insert(pending_callbacks, callback)

  if download_in_progress then
    dbg('download already in progress, queued callback')
    return
  end

  download_in_progress = true

  local dir = lib_dir()
  vim.fn.mkdir(dir, 'p')

  local os_name = get_os()
  local arch = get_arch()
  local ext = get_ext()
  local filename = ('libvscode_diff_%s_%s_%s.%s'):format(os_name, arch, EXPECTED_VERSION, ext)
  local url = ('https://github.com/esmuellert/vscode-diff.nvim/releases/download/v%s/%s'):format(
    EXPECTED_VERSION,
    filename
  )

  local dest = lib_path()
  vim.notify('[diffs] downloading libvscode_diff...', vim.log.levels.INFO)

  local cmd = { 'curl', '-fSL', '-o', dest, url }

  vim.system(cmd, {}, function(result)
    download_in_progress = false
    vim.schedule(function()
      local handle = nil
      if result.code ~= 0 then
        vim.notify('[diffs] failed to download libvscode_diff', vim.log.levels.WARN)
        dbg('curl failed: %s', result.stderr or '')
      else
        local f = io.open(version_path(), 'w')
        if f then
          f:write(EXPECTED_VERSION)
          f:close()
        end
        vim.notify('[diffs] libvscode_diff downloaded', vim.log.levels.INFO)
        handle = M.load()
      end

      local cbs = pending_callbacks
      pending_callbacks = {}
      for _, cb in ipairs(cbs) do
        cb(handle)
      end
    end)
  end)
end

return M
