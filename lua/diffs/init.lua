local runtime = require('diffs.runtime')

return {
  attach = runtime.attach,
  detach = runtime.detach,
  refresh = runtime.refresh,
  highlight_options = runtime.get_highlight_opts,
  diff_options = require('diffs.diffopt').resolve,
  compute_intra_hunks = require('diffs.diff').compute_intra_hunks,
  whitespace_only_lines = require('diffs.diff').whitespace_only_lines,
}
