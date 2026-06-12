require('spec.helpers')

describe('diffs public API', function()
  it('keeps the root module narrow', function()
    local diffs = require('diffs')
    local keys = {}

    for key, _ in pairs(diffs) do
      keys[#keys + 1] = key
    end
    table.sort(keys)

    assert.same({
      'attach',
      'refresh',
      'review_current',
      'review_files',
      'review_goto',
      'review_next_file',
      'review_prev_file',
      'select_review_file',
    }, keys)
    assert.is_function(diffs.attach)
    assert.is_function(diffs.refresh)
    assert.is_function(diffs.review_files)
    assert.is_function(diffs.review_current)
    assert.is_function(diffs.review_goto)
    assert.is_function(diffs.review_next_file)
    assert.is_function(diffs.review_prev_file)
    assert.is_function(diffs.select_review_file)
  end)
end)
