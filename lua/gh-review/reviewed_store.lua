--- On-disk persistence for "reviewed" file marks.
--- Stored per PR under stdpath('data')/gh-review/reviewed/<safe_key>.json
--- as a plain JSON array of PR-relative file paths. The path is derived
--- from "<owner>/<repo>#<number>" with non-alphanumerics substituted so
--- the resulting filename is portable.
local M = {}

--- Root data directory; created on demand.
---@return string
local function data_dir()
  local dir = vim.fn.stdpath("data") .. "/gh-review/reviewed"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Derive the persistence filename for a PR key.
---@param pr_key string e.g. "owner/repo#123"
---@return string
local function file_for(pr_key)
  local safe = pr_key:gsub("[^%w]", "_")
  return data_dir() .. "/" .. safe .. ".json"
end

--- Build a key from PR metadata. Returns nil when the PR doesn't have
--- enough info to scope persistence (e.g. synthesized test PR objects).
---@param pr table?
---@return string?
function M.key_for(pr)
  if not pr or not pr.repository or not pr.number then return nil end
  return pr.repository .. "#" .. pr.number
end

--- Load persisted reviewed paths for a PR key.
--- Missing / malformed files return an empty list.
---@param pr_key string
---@return string[]
function M.load(pr_key)
  local path = file_for(pr_key)
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if content == nil or content == "" then return {} end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for _, v in ipairs(data) do
    if type(v) == "string" then table.insert(out, v) end
  end
  return out
end

--- Save a list of reviewed paths for a PR key. Atomic via tmp-then-rename.
---@param pr_key string
---@param paths string[]
---@return boolean ok
function M.save(pr_key, paths)
  local path = file_for(pr_key)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  local ok, encoded = pcall(vim.json.encode, paths or {})
  if not ok then
    f:close()
    os.remove(tmp)
    return false
  end
  f:write(encoded)
  f:close()
  local renamed = os.rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return false
  end
  return true
end

--- Remove the persistence file for a PR key. Used by tests; not wired to
--- the session lifecycle (closing a review keeps marks for next time).
---@param pr_key string
function M.delete(pr_key)
  os.remove(file_for(pr_key))
end

return M
