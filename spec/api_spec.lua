require('spec.helpers')

describe('diffs public API', function()
  it('keeps the root module narrow', function()
    local diffs = require('diffs')
    local keys = {}

    for key, _ in pairs(diffs) do
      keys[#keys + 1] = key
    end
    table.sort(keys)

    assert.same({ 'attach', 'refresh' }, keys)
    assert.is_function(diffs.attach)
    assert.is_function(diffs.refresh)
  end)
end)
