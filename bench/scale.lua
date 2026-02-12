local repos = {}
for _, n in ipairs({ 50, 200, 500, 1000, 2000 }) do
  local path = '/tmp/diffs-bench-' .. n
  local ok = vim.fn.isdirectory(path) == 1
  if ok then
    table.insert(repos, { commits = n, path = path })
  end
end

if #repos == 0 then
  io.stderr:write('no shim repos found at /tmp/diffs-bench-*\n')
  vim.cmd('cquit!')
end

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
local viewport = tonumber(os.getenv('BENCH_VIEWPORT')) or 60
local iters = tonumber(os.getenv('BENCH_ITERS')) or 5

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

printf('diffs.nvim scaling benchmark')
printf('============================')
printf('viewport: %d lines, iterations: %d', viewport, iters)
printf('')
printf(
  '%-10s %8s %8s   %12s %12s   %12s %12s   %12s %12s',
  'commits',
  'lines',
  'hunks',
  'parse(med)',
  'parse/line',
  'viewport(med)',
  'vp hunks',
  'inval(med)',
  'cache hit'
)
printf(string.rep('-', 130))

for _, repo in ipairs(repos) do
  local output = vim.fn.system({ 'git', '-C', repo.path, 'log', '-p', '--no-color' })
  local lines = vim.split(output, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_var(buf, 'diffs_repo_root', repo.path)
  vim.api.nvim_buf_set_var(buf, 'git_dir', repo.path .. '/.git')

  local hunks = parser.parse_buffer(buf)
  local line_count = #lines
  local hunk_count = #hunks

  local r_parse = measure(function()
    hunk_cache[buf] = nil
    parser.parse_buffer(buf)
  end, iters)

  local r_vp = measure(function()
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

  local vp_first, vp_last = find_visible_hunks(hunks, 0, viewport)
  local vp_hunk_count = vp_first > 0 and (vp_last - vp_first + 1) or 0

  ensure_cache(buf)
  local r_inval = measure(function()
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

  ensure_cache(buf)
  local r_cache = measure(function()
    local entry = hunk_cache[buf]
    if entry then
      local first, last = find_visible_hunks(entry.hunks, 0, viewport)
      _ = first + last
    end
  end, iters)

  printf(
    '%-10d %8d %8d   %10.1fms %10.3fus   %10.1fms %10d   %10.1fms %10.3fms',
    repo.commits,
    line_count,
    hunk_count,
    r_parse.median,
    (r_parse.median / line_count) * 1000,
    r_vp.median,
    vp_hunk_count,
    r_inval.median,
    r_cache.median
  )

  vim.api.nvim_buf_delete(buf, { force = true })
end

printf('')
printf('parse/line = microseconds per line (lower is better)')
printf('vp hunks   = hunks visible in %d-line viewport', viewport)

vim.cmd('qa!')
