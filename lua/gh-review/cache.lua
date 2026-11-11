--- Cache keyed by commit hashes, in memory and on disk. Every key must name the
--- commits its value was computed from, so a hit can never be stale: when a PR
--- gets new commits, its key changes and the old entry is ignored.
---
--- Stored under stdpath('cache')/gh-review/<namespace>/<safe key>.json.
local M = {}

---@type table<string, table<string, any>>
local memory = {}

--- Entries older than this are deleted by `prune`.
M.MAX_AGE_DAYS = 30

---@return string
function M.root()
  return vim.fn.stdpath("cache") .. "/gh-review"
end

---@param ns string
---@param key string
---@return string
local function file_for(ns, key)
  return M.root() .. "/" .. ns .. "/" .. key:gsub("[^%w%-]", "_") .. ".json"
end

--- Read a cached value.
---@param ns string Namespace, e.g. "status"
---@param key string
---@return any? value
function M.get(ns, key)
  local mem = memory[ns]
  if mem and mem[key] ~= nil then return mem[key] end
  local f = io.open(file_for(ns, key), "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, value = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok then return nil end
  memory[ns] = memory[ns] or {}
  memory[ns][key] = value
  return value
end

--- Store a value. Disk errors are ignored: the cache is an optimisation.
---@param ns string
---@param key string
---@param value any JSON-encodable
function M.set(ns, key, value)
  memory[ns] = memory[ns] or {}
  memory[ns][key] = value
  pcall(function()
    vim.fn.mkdir(M.root() .. "/" .. ns, "p")
    local f = assert(io.open(file_for(ns, key), "w"))
    f:write(vim.json.encode(value))
    f:close()
  end)
end

--- Drop the in-memory copy of a namespace (or all of them). Disk is untouched.
---@param ns? string
function M.forget(ns)
  if ns then memory[ns] = nil else memory = {} end
end

--- Delete every cached entry, in memory and on disk.
function M.clear()
  memory = {}
  vim.fn.delete(M.root(), "rf")
end

--- Delete disk entries older than `MAX_AGE_DAYS`.
function M.prune()
  local cutoff = os.time() - M.MAX_AGE_DAYS * 86400
  for _, path in ipairs(vim.fn.glob(M.root() .. "/*/*.json", true, true)) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.mtime.sec < cutoff then os.remove(path) end
  end
end

return M
