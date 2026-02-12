local repo = os.getenv('BENCH_REPO') or '/tmp/diffs-shim-f'
local profile = os.getenv('BENCH_PROFILE') == '1'
local profile_out = os.getenv('BENCH_PROFILE_OUT') or '/tmp/diffs.prof'
local viewport = tonumber(os.getenv('BENCH_VIEWPORT')) or 60
local iters = tonumber(os.getenv('BENCH_ITERS')) or 10

local diffs = require('diffs')
local parser = require('diffs.parser')
local highlight = require('diffs.highlight')
local diff = require('diffs.diff')

local test = diffs._test
local hunk_cache = test.hunk_cache
local warmed_langs = test.warmed_langs
local ensure_cache = test.ensure_cache
local invalidate_cache = test.invalidate_cache
local find_visible_hunks = test.find_visible_hunks

local ns = vim.api.nvim_create_namespace('diffs')

local hrtime = vim.uv.hrtime

local function printf(fmt, ...)
  io.write(string.format(fmt, ...) .. '\n')
end

local function measure(fn, n)
  local samples = {}
  for i = 1, n do
    local t0 = hrtime()
    fn()
    samples[i] = (hrtime() - t0) / 1e6
  end
  table.sort(samples)
  local sum = 0
  for _, v in ipairs(samples) do
    sum = sum + v
  end
  return {
    min = samples[1],
    max = samples[n],
    median = n % 2 == 1 and samples[math.ceil(n / 2)]
      or (samples[n / 2] + samples[n / 2 + 1]) / 2,
    mean = sum / n,
    samples = samples,
  }
end

local function fmt_row(label, r)
  printf('%-30s %9.3fms %9.3fms %9.3fms %9.3fms', label, r.min, r.median, r.mean, r.max)
end

local function section(title)
  printf('')
  printf('--- %s ---', title)
  printf('%-30s %10s %10s %10s %10s', '', 'min', 'median', 'mean', 'max')
end

local output = vim.fn.system({ 'git', '-C', repo, 'log', '-p', '--no-color' })
if vim.v.shell_error ~= 0 then
  io.stderr:write('failed to run git log in ' .. repo .. '\n')
  vim.cmd('cquit!')
end

local lines = vim.split(output, '\n', { plain = true })
if lines[#lines] == '' then
  lines[#lines] = nil
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_buf_set_var(buf, 'diffs_repo_root', repo)
vim.api.nvim_buf_set_var(buf, 'git_dir', repo .. '/.git')

local throwaway = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(throwaway, 0, -1, false, { 'diff --git a/x b/x', '@@ -1 +1 @@', '-a', '+b' })
diffs.attach(throwaway)

local hunks = parser.parse_buffer(buf)
local line_count = #lines
local hunk_count = #hunks

local lang_set = {}
for _, h in ipairs(hunks) do
  if h.lang and not lang_set[h.lang] then
    lang_set[h.lang] = true
  end
end

local lang_list = {}
for lang in pairs(lang_set) do
  local ok = pcall(vim.treesitter.get_string_parser, 'x', lang)
  table.insert(lang_list, lang .. (ok and '(Y)' or '(N)'))
end
table.sort(lang_list)

printf('diffs.nvim benchmark')
printf('====================')
printf('neovim:     %s', tostring(vim.version()))
printf('luajit:     %s', jit and jit.version or 'N/A')
printf('repo:       %s', repo)
printf('lines:      %d', line_count)
printf('hunks:      %d', hunk_count)
printf('languages:  %s', table.concat(lang_list, ' '))
printf('viewport:   %d lines', viewport)
printf('iterations: %d', iters)

section('parse_buffer')

local r = measure(function()
  hunk_cache[buf] = nil
  parser.parse_buffer(buf)
end, iters)
fmt_row(string.format('cold (%d lines)', line_count), r)

r = measure(function()
  hunk_cache[buf] = nil
  parser.parse_buffer(buf)
end, iters)
fmt_row(string.format('warm (%d lines)', line_count), r)

section('highlight_hunk (per language)')

local hl_opts = {
  hide_prefix = false,
  highlights = {
    background = true,
    gutter = true,
    context = { enabled = true, lines = 25 },
    treesitter = { enabled = true, max_lines = 500 },
    vim = { enabled = false, max_lines = 200 },
    intra = { enabled = true, algorithm = 'default', max_lines = 500 },
    priorities = { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 },
  },
  defer_vim_syntax = true,
}

local by_lang = {}
for _, h in ipairs(hunks) do
  if h.lang and not by_lang[h.lang] then
    by_lang[h.lang] = h
  end
end

local sorted_langs = {}
for lang in pairs(by_lang) do
  table.insert(sorted_langs, lang)
end
table.sort(sorted_langs)

for _, lang in ipairs(sorted_langs) do
  local h = by_lang[lang]

  for k in pairs(warmed_langs) do
    if k ~= 'diff' then
      warmed_langs[k] = nil
    end
  end

  r = measure(function()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    highlight.highlight_hunk(buf, ns, h, hl_opts)
  end, iters)
  fmt_row(string.format('%s (cold)', lang), r)

  r = measure(function()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    highlight.highlight_hunk(buf, ns, h, hl_opts)
  end, iters)
  fmt_row(string.format('%s (warm)', lang), r)
end

section('intra-line diff')

local intra_count = 0
for _, h in ipairs(hunks) do
  local groups = diff.extract_change_groups(h.lines)
  if #groups > 0 and intra_count < 5 then
    r = measure(function()
      diff.compute_intra_hunks(h.lines, 'default')
    end, iters)
    local label = string.format('%s:%d (%d lines)', h.filename or '?', h.start_line, #h.lines)
    if #label > 30 then
      label = '...' .. label:sub(-27)
    end
    fmt_row(label, r)
    intra_count = intra_count + 1
  end
end

if intra_count == 0 then
  printf('  (no change groups found)')
end

section('viewport cycle')

hunk_cache[buf] = nil
for k in pairs(warmed_langs) do
  if k ~= 'diff' then
    warmed_langs[k] = nil
  end
end

r = measure(function()
  hunk_cache[buf] = nil
  for k in pairs(warmed_langs) do
    if k ~= 'diff' then
      warmed_langs[k] = nil
    end
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  ensure_cache(buf)
  local entry = hunk_cache[buf]
  if entry then
    entry.highlighted = {}
    entry.pending_clear = false
    local first, last = find_visible_hunks(entry.hunks, 0, viewport)
    if first > 0 then
      for i = first, last do
        highlight.highlight_hunk(buf, ns, entry.hunks[i], hl_opts)
        entry.highlighted[i] = true
      end
    end
  end
end, iters)
fmt_row('cold (parse+highlight)', r)

r = measure(function()
  hunk_cache[buf] = nil
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  ensure_cache(buf)
  local entry = hunk_cache[buf]
  if entry then
    entry.highlighted = {}
    entry.pending_clear = false
    local first, last = find_visible_hunks(entry.hunks, 0, viewport)
    if first > 0 then
      for i = first, last do
        highlight.highlight_hunk(buf, ns, entry.hunks[i], hl_opts)
        entry.highlighted[i] = true
      end
    end
  end
end, iters)
fmt_row('warm (parse+highlight)', r)

ensure_cache(buf)
r = measure(function()
  local entry = hunk_cache[buf]
  if entry then
    local first, last = find_visible_hunks(entry.hunks, 0, viewport)
    _ = first + last
  end
end, iters)
fmt_row('cache hit', r)

section('cache invalidation')

ensure_cache(buf)
r = measure(function()
  invalidate_cache(buf)
  ensure_cache(buf)
  local entry = hunk_cache[buf]
  if entry then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    entry.highlighted = {}
    entry.pending_clear = false
    local first, last = find_visible_hunks(entry.hunks, 0, viewport)
    if first > 0 then
      for i = first, last do
        highlight.highlight_hunk(buf, ns, entry.hunks[i], hl_opts)
        entry.highlighted[i] = true
      end
    end
  end
end, iters)
fmt_row('invalidate+reparse+hl', r)

section('find_visible_hunks')

ensure_cache(buf)
local cached_hunks = hunk_cache[buf].hunks
r = measure(function()
  find_visible_hunks(cached_hunks, 0, viewport)
end, iters)
fmt_row(string.format('binary search (%d hunks)', #cached_hunks), r)

if profile then
  printf('')
  printf('--- jit.p profiling ---')
  printf('output: %s', profile_out)

  ensure_cache(buf)

  require('jit.p').start('pli1', profile_out)
  local profile_iters = iters * 10
  for _ = 1, profile_iters do
    hunk_cache[buf] = nil
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    ensure_cache(buf)
    local entry = hunk_cache[buf]
    if entry then
      entry.highlighted = {}
      entry.pending_clear = false
      local first, last = find_visible_hunks(entry.hunks, 0, viewport)
      if first > 0 then
        for i = first, last do
          highlight.highlight_hunk(buf, ns, entry.hunks[i], hl_opts)
          entry.highlighted[i] = true
        end
      end
    end
  end
  require('jit.p').stop()

  printf('completed %d warm viewport iterations', profile_iters)
end

vim.cmd('qa!')
