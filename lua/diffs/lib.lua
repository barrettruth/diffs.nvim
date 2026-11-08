local M = {}

local log = require('diffs.log')

local dbg = log.dbg

---@type table?
local cached_handle = nil

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

    const char* get_version(void);
  ]])

  local ok, handle = pcall(ffi.load, path)
  if not ok then
    dbg('failed to load libvscode_diff: %s', handle)
    return nil
  end

  cached_handle = handle
  return handle
end

return M
