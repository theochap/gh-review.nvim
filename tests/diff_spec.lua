---@module 'luassert'

local diff = require("gh-review.diff")

-- Sample unified diff for testing
local SAMPLE_DIFF = table.concat({
  "diff --git a/src/main.lua b/src/main.lua",
  "--- a/src/main.lua",
  "+++ b/src/main.lua",
  "@@ -5,7 +5,8 @@ local M = {}",
  " function M.hello()",
  "-  print('old')",
  "+  print('new')",
  "+  print('extra')",
  "   return true",
  " end",
  " ",
  " function M.other()",
  "diff --git a/src/utils.lua b/src/utils.lua",
  "--- a/src/utils.lua",
  "+++ b/src/utils.lua",
  "@@ -1,3 +1,4 @@",
  "+-- header comment",
  " local U = {}",
  " U.version = 1",
  " return U",
}, "\n")

describe("diff.parse", function()
  it("parses multiple files from a unified diff", function()
    local files = diff.parse(SAMPLE_DIFF)
    assert.is_not_nil(files["src/main.lua"])
    assert.is_not_nil(files["src/utils.lua"])
  end)

  it("extracts hunk headers correctly", function()
    local files = diff.parse(SAMPLE_DIFF)
    local main = files["src/main.lua"]
    assert.are.equal(1, #main.hunks)
    assert.are.equal(5, main.hunks[1].old_start)
    assert.are.equal(7, main.hunks[1].old_count)
    assert.are.equal(5, main.hunks[1].new_start)
    assert.are.equal(8, main.hunks[1].new_count)
  end)

  it("collects hunk lines", function()
    local files = diff.parse(SAMPLE_DIFF)
    local main = files["src/main.lua"]
    -- " function M.hello()", "- print('old')", "+ print('new')", "+ print('extra')",
    -- "   return true", " end", " ", " function M.other()"
    assert.are.equal(8, #main.hunks[1].lines)
  end)

  it("handles empty diff", function()
    local files = diff.parse("")
    assert.are.same({}, files)
  end)

  it("handles hunk count omitted (single line)", function()
    local single_line_diff = table.concat({
      "diff --git a/f.lua b/f.lua",
      "--- a/f.lua",
      "+++ b/f.lua",
      "@@ -1 +1 @@",
      "-old",
      "+new",
    }, "\n")
    local files = diff.parse(single_line_diff)
    local hunk = files["f.lua"].hunks[1]
    assert.are.equal(1, hunk.old_start)
    assert.are.equal(1, hunk.old_count)
    assert.are.equal(1, hunk.new_start)
    assert.are.equal(1, hunk.new_count)
  end)
end)

describe("diff.map_to_working_tree", function()
  local files

  before_each(function()
    files = diff.parse(SAMPLE_DIFF)
  end)

  describe("RIGHT side", function()
    it("returns the line number as-is", function()
      assert.are.equal(42, diff.map_to_working_tree(files["src/main.lua"], 42, "RIGHT"))
    end)
  end)

  describe("LEFT side", function()
    it("maps context line to corresponding new line", function()
      -- " function M.hello()" is old line 5, new line 5 (context)
      local result = diff.map_to_working_tree(files["src/main.lua"], 5, "LEFT")
      assert.are.equal(5, result)
    end)

    it("maps deleted line to nearest new line", function()
      -- "- print('old')" is old line 6, maps to new line 6 (nearest)
      local result = diff.map_to_working_tree(files["src/main.lua"], 6, "LEFT")
      assert.are.equal(6, result)
    end)

    it("maps line after additions correctly", function()
      -- "   return true" is old line 7, new line 8 (after +1 net addition)
      local result = diff.map_to_working_tree(files["src/main.lua"], 7, "LEFT")
      assert.are.equal(8, result)
    end)

    it("maps line outside hunk with cumulative offset", function()
      -- main.lua hunk: old_count=7, new_count=8, so offset = +1
      -- old line 50 -> new line 51
      local result = diff.map_to_working_tree(files["src/main.lua"], 50, "LEFT")
      assert.are.equal(51, result)
    end)

    it("maps line before hunk with no offset", function()
      -- old line 1 is before the hunk starting at line 5
      local result = diff.map_to_working_tree(files["src/main.lua"], 1, "LEFT")
      assert.are.equal(1, result)
    end)
  end)
end)

describe("diff.map_threads", function()
  it("sets mapped_line on threads with diff data", function()
    local files = diff.parse(SAMPLE_DIFF)
    local threads = {
      { id = "t1", path = "src/main.lua", line = 5, side = "LEFT" },
      { id = "t2", path = "src/main.lua", line = 7, side = "RIGHT" },
    }
    diff.map_threads(threads, files)
    assert.are.equal(5, threads[1].mapped_line)
    assert.are.equal(7, threads[2].mapped_line)
  end)

  it("uses line as-is when no diff data for file", function()
    local threads = {
      { id = "t1", path = "unknown.lua", line = 42, side = "RIGHT" },
    }
    diff.map_threads(threads, {})
    assert.are.equal(42, threads[1].mapped_line)
  end)

  it("handles thread with nil line", function()
    local threads = {
      { id = "t1", path = "src/main.lua", line = nil, side = "RIGHT" },
    }
    diff.map_threads(threads, diff.parse(SAMPLE_DIFF))
    assert.is_nil(threads[1].mapped_line)
  end)
end)
