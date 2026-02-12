local repo = os.getenv('BENCH_REPO') or '/tmp/diffs-shim-f'
local iters = tonumber(os.getenv('BENCH_ITERS')) or 20
local viewport = tonumber(os.getenv('BENCH_VIEWPORT')) or 60

local diffs = require('diffs')
local parser = require('diffs.parser')
local highlight = require('diffs.highlight')

local test = diffs._test
local hunk_cache = test.hunk_cache
local warmed_langs = test.warmed_langs
local ensure_cache = test.ensure_cache
local invalidate_cache = test.invalidate_cache
local find_visible_hunks = test.find_visible_hunks

local ns = vim.api.nvim_create_namespace('diffs')
local hrtime = vim.uv.hrtime

local throwaway = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(throwaway, 0, -1, false, { 'diff --git a/x b/x', '@@ -1 +1 @@', '-a', '+b' })
diffs.attach(throwaway)

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
  }
end

local status_out = vim.fn.system({ 'git', '-C', repo, 'diff', '--cached', '--stat' })
local status_files = {}
for line in status_out:gmatch('[^\n]+') do
  local f = line:match('^%s*(%S+)%s+|')
  if f then
    table.insert(status_files, f)
  end
end

local header_lines = {
  'Head: master',
  'Push: origin/master',
  '',
  'Staged (' .. #status_files .. ')',
}

for _, f in ipairs(status_files) do
  table.insert(header_lines, 'M ' .. f)
end

local diff_out = vim.fn.system({ 'git', '-C', repo, 'diff', '--cached', '--no-color' })
local diff_lines = vim.split(diff_out, '\n', { plain = true })
if diff_lines[#diff_lines] == '' then
  diff_lines[#diff_lines] = nil
end

local all_lines = {}
for _, line in ipairs(header_lines) do
  table.insert(all_lines, line)
end
for _, line in ipairs(diff_lines) do
  table.insert(all_lines, line)
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
vim.api.nvim_buf_set_var(buf, 'diffs_repo_root', repo)
vim.api.nvim_buf_set_var(buf, 'git_dir', repo .. '/.git')

local hunks = parser.parse_buffer(buf)

local lang_set = {}
for _, h in ipairs(hunks) do
  if h.lang then
    lang_set[h.lang] = (lang_set[h.lang] or 0) + 1
  end
end
local lang_list = {}
for lang, count in pairs(lang_set) do
  table.insert(lang_list, string.format('%s(%d)', lang, count))
end
table.sort(lang_list)

printf('diffs.nvim real-world profile: fugitive staged expand-all')
printf(string.rep('=', 60))
printf('repo:       %s', repo)
printf('lines:      %d (%d header + %d diff)', #all_lines, #header_lines, #diff_lines)
printf('hunks:      %d', #hunks)
printf('languages:  %s', table.concat(lang_list, ' '))
printf('viewport:   %d lines', viewport)
printf('iterations: %d', iters)

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

local fast_opts = vim.deepcopy(hl_opts)
fast_opts.highlights.treesitter.enabled = false

printf('')
printf('--- parse ---')
printf('%-40s %10s %10s %10s', '', 'median', 'mean', 'max')

local r = measure(function()
  hunk_cache[buf] = nil
  parser.parse_buffer(buf)
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'parse_buffer', r.median, r.mean, r.max)

printf('')
printf('--- viewport highlight (lines 0-%d) ---', viewport)

local first, last = find_visible_hunks(hunks, 0, viewport)
local vp_count = first > 0 and (last - first + 1) or 0
printf('visible hunks: %d (indices %d..%d)', vp_count, first, last)
if first > 0 then
  for i = first, last do
    local h = hunks[i]
    printf('  [%d] %s:%d (%d lines, lang=%s)', i, h.filename or '?', h.start_line, #h.lines, h.lang or 'nil')
  end
end

r = measure(function()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i = first, last do
    highlight.highlight_hunk(buf, ns, hunks[i], hl_opts)
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'full (TS + bg + intra)', r.median, r.mean, r.max)

r = measure(function()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i = first, last do
    highlight.highlight_hunk(buf, ns, hunks[i], fast_opts)
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'fast (bg + intra only)', r.median, r.mean, r.max)

printf('')
printf('--- all hunks highlight (simulate expand-all, scrolled through) ---')

r = measure(function()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hunks) do
    highlight.highlight_hunk(buf, ns, h, hl_opts)
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms',
  string.format('all %d hunks full', #hunks), r.median, r.mean, r.max)

r = measure(function()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hunks) do
    highlight.highlight_hunk(buf, ns, h, fast_opts)
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms',
  string.format('all %d hunks fast', #hunks), r.median, r.mean, r.max)

printf('')
printf('--- end-to-end viewport cycle ---')

r = measure(function()
  hunk_cache[buf] = nil
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  ensure_cache(buf)
  local entry = hunk_cache[buf]
  if entry then
    entry.highlighted = {}
    entry.pending_clear = false
    local f, l = find_visible_hunks(entry.hunks, 0, viewport)
    if f > 0 then
      for i = f, l do
        highlight.highlight_hunk(buf, ns, entry.hunks[i], hl_opts)
        entry.highlighted[i] = true
      end
    end
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'parse + viewport full', r.median, r.mean, r.max)

r = measure(function()
  hunk_cache[buf] = nil
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  ensure_cache(buf)
  local entry = hunk_cache[buf]
  if entry then
    entry.highlighted = {}
    entry.pending_clear = false
    local f, l = find_visible_hunks(entry.hunks, 0, viewport)
    if f > 0 then
      for i = f, l do
        highlight.highlight_hunk(buf, ns, entry.hunks[i], fast_opts)
        entry.highlighted[i] = true
      end
    end
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'parse + viewport fast', r.median, r.mean, r.max)

printf('')
printf('--- two-pass simulation ---')

r = measure(function()
  hunk_cache[buf] = nil
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  ensure_cache(buf)
  local entry = hunk_cache[buf]
  if entry then
    entry.highlighted = {}
    entry.pending_clear = false
    local f, l = find_visible_hunks(entry.hunks, 0, viewport)
    if f > 0 then
      for i = f, l do
        highlight.highlight_hunk(buf, ns, entry.hunks[i], fast_opts)
        entry.highlighted[i] = true
      end
    end
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'pass 1: parse + bg + intra', r.median, r.mean, r.max)

ensure_cache(buf)
local entry = hunk_cache[buf]
entry.pending_clear = false
r = measure(function()
  local f, l = find_visible_hunks(entry.hunks, 0, viewport)
  if f > 0 then
    for i = f, l do
      local hunk = entry.hunks[i]
      local start_row = hunk.start_line - 1
      local end_row = start_row + #hunk.lines
      if hunk.header_start_line then
        start_row = hunk.header_start_line - 1
      end
      vim.api.nvim_buf_clear_namespace(buf, ns, start_row, end_row)
      highlight.highlight_hunk(buf, ns, hunk, hl_opts)
    end
  end
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'pass 2: clear + full reapply', r.median, r.mean, r.max)

printf('')
printf('--- fugitive churn (identity reload) ---')
ensure_cache(buf)
hunk_cache[buf].pending_clear = false
r = measure(function()
  vim.api.nvim_buf_set_lines(buf, -2, -1, false, { all_lines[#all_lines] })
  ensure_cache(buf)
end, iters)
printf('%-40s %8.3fms %8.3fms %8.3fms', 'fingerprint guard (no reparse)', r.median, r.mean, r.max)

printf('')
printf('--- jit.p: full viewport highlight ---')
local profile_out = os.getenv('BENCH_PROFILE_OUT') or '/tmp/diffs-real.prof'
printf('output: %s', profile_out)

require('jit.p').start('pli1', profile_out)
for _ = 1, iters * 5 do
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i = first, last do
    highlight.highlight_hunk(buf, ns, hunks[i], hl_opts)
  end
end
require('jit.p').stop()
printf('completed %d iterations', iters * 5)

vim.cmd('qa!')
