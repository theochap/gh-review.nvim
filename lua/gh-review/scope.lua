--- PR list scopes: which PRs the PR and stack pickers show. A scope maps to one
--- or more GitHub search queries; the results of all of them are merged.
local M = {}

---@alias GHReviewScopeKind "all"|"mine"|"review"|"author"

---@class GHReviewScope
---@field kind GHReviewScopeKind
---@field login? string Author login, for the "author" kind
---@field filters? GHReviewFilter[] Extra search qualifiers, ANDed with the scope

---@class GHReviewFilter
---@field kind string Filter kind (see `FILTERS`); one filter per kind, except "custom"
---@field qualifier string GitHub search qualifier, e.g. "review:required"
---@field text string Shown in picker titles, e.g. "review required"

---@class GHReviewFilterDef
---@field kind string
---@field label string Menu entry
---@field choices? { [1]: string, [2]: string }[] Fixed values: { text, qualifier }
---@field input? string Prompt for a free value
---@field qualifier? fun(value: string): string Qualifier for a free value
---@field text? fun(value: string): string Title text for a free value

--- Filters offered by the filter menu. Each maps to GitHub search qualifiers,
--- so they work the same for the PR list and the stack list.
---@type GHReviewFilterDef[]
M.FILTERS = {
  {
    kind = "author",
    label = "Author",
    input = "PR author (login): ",
    qualifier = function(v) return "author:" .. v end,
    text = function(v) return "by @" .. v end,
  },
  {
    kind = "status",
    label = "Status",
    choices = { { "ready for review", "draft:false" }, { "draft", "draft:true" } },
  },
  {
    kind = "review",
    label = "Review decision",
    choices = {
      { "review required", "review:required" },
      { "approved", "review:approved" },
      { "changes requested", "review:changes_requested" },
      { "no review yet", "review:none" },
    },
  },
  {
    kind = "my_review",
    label = "My review",
    choices = {
      { "not reviewed by me", "-reviewed-by:@me" },
      { "reviewed by me", "reviewed-by:@me" },
      { "my review requested", "review-requested:@me" },
    },
  },
  {
    kind = "checks",
    label = "Checks",
    choices = { { "checks passing", "status:success" }, { "checks failing", "status:failure" }, { "checks pending", "status:pending" } },
  },
  {
    kind = "label",
    label = "Label",
    input = "Label: ",
    qualifier = function(v) return v:find("%s") and ('label:"' .. v .. '"') or ("label:" .. v) end,
    text = function(v) return "label " .. v end,
  },
  {
    kind = "base",
    label = "Base branch",
    input = "Base branch: ",
    qualifier = function(v) return "base:" .. v end,
    text = function(v) return "into " .. v end,
  },
  {
    kind = "custom",
    label = "Search qualifier…",
    input = "GitHub search qualifiers: ",
    qualifier = function(v) return v end,
    text = function(v) return v end,
  },
}

---@type table<string, string> Qualifier key -> filter kind, for parsing
local QUALIFIER_KINDS = {
  author = "author",
  draft = "status",
  review = "review",
  ["reviewed-by"] = "my_review",
  ["-reviewed-by"] = "my_review",
  ["review-requested"] = "my_review",
  status = "checks",
  label = "label",
  base = "base",
}

--- Filter for a raw search qualifier such as "draft:false" (command line).
---@param qualifier string
---@return GHReviewFilter
function M.filter_from_qualifier(qualifier)
  local key = qualifier:match("^(%-?[%w-]+):")
  local kind = key and QUALIFIER_KINDS[key] or "custom"
  for _, def in ipairs(M.FILTERS) do
    if def.kind == kind and def.choices then
      for _, choice in ipairs(def.choices) do
        if choice[2] == qualifier then return { kind = kind, qualifier = qualifier, text = choice[1] } end
      end
    end
  end
  return { kind = kind, qualifier = qualifier, text = qualifier }
end

--- A copy of `scope` with `filter` added. A filter replaces the one of the
--- same kind (two review decisions would match nothing); custom ones add up.
---@param scope GHReviewScope
---@param filter GHReviewFilter
---@return GHReviewScope
function M.with_filter(scope, filter)
  local filters = {}
  for _, f in ipairs(scope.filters or {}) do
    if f.kind ~= filter.kind or filter.kind == "custom" then table.insert(filters, f) end
  end
  table.insert(filters, filter)
  return vim.tbl_extend("force", scope, { filters = filters })
end

--- A copy of `scope` without filters.
---@param scope GHReviewScope
---@return GHReviewScope
function M.without_filters(scope)
  return vim.tbl_extend("force", scope, { filters = {} })
end

--- The filter a value entered for `def` gives, or nil for an empty value.
---@param def GHReviewFilterDef A filter that takes a free value
---@param value string?
---@return GHReviewFilter?
function M.filter_from_value(def, value)
  value = value and vim.trim(value) or ""
  if def.kind == "author" then value = value:gsub("^@", "") end
  if value == "" then return nil end
  return { kind = def.kind, qualifier = def.qualifier(value), text = def.text(value) }
end

---@param kind string
---@return GHReviewFilterDef?
local function filter_def(kind)
  for _, def in ipairs(M.FILTERS) do
    if def.kind == kind then return def end
  end
  return nil
end

---@class GHReviewFilterOption
---@field label string Menu text, e.g. "Review decision: approved"
---@field active boolean Whether the scope has this filter now
---@field filter? GHReviewFilter The filter the option is (active) or adds
---@field def? GHReviewFilterDef Set on "enter a value" options, which have no filter yet

--- Every filter that can be toggled on `scope`: its active filters first,
--- then each fixed choice it lacks, then one "enter a value" option per
--- filter that takes a free value (author, label, base, qualifier).
---@param scope GHReviewScope
---@return GHReviewFilterOption[]
function M.filter_options(scope)
  local options, active = {}, {}
  for _, f in ipairs(scope.filters or {}) do
    active[f.qualifier] = true
    local def = filter_def(f.kind)
    local label = def and def.kind ~= "custom" and (def.label .. ": " .. f.text) or ("Qualifier: " .. f.qualifier)
    table.insert(options, { label = label, active = true, filter = f })
  end
  for _, def in ipairs(M.FILTERS) do
    if def.choices then
      for _, c in ipairs(def.choices) do
        if not active[c[2]] then
          table.insert(options, {
            label = def.label .. ": " .. c[1],
            active = false,
            filter = { kind = def.kind, qualifier = c[2], text = c[1] },
          })
        end
      end
    else
      table.insert(options, { label = def.label:gsub("…$", "") .. ": enter a value…", active = false, def = def })
    end
  end
  return options
end

--- Toggle the `picked` options on `scope`: active filters are removed, the
--- others added. Returns the new scope, and the filters that still need a
--- value from the user (the "enter a value" options picked).
---@param scope GHReviewScope
---@param picked GHReviewFilterOption[]
---@return GHReviewScope scope, GHReviewFilterDef[] prompts
function M.toggle_filters(scope, picked)
  local removed = {}
  for _, opt in ipairs(picked) do
    if opt.active and opt.filter then removed[opt.filter.qualifier] = true end
  end
  local kept = {}
  for _, f in ipairs(scope.filters or {}) do
    if not removed[f.qualifier] then table.insert(kept, f) end
  end
  local new = vim.tbl_extend("force", scope, { filters = kept })
  local prompts = {}
  for _, opt in ipairs(picked) do
    if not opt.active then
      if opt.filter then
        new = M.with_filter(new, opt.filter)
      elseif opt.def then
        table.insert(prompts, opt.def)
      end
    end
  end
  return new, prompts
end

--- Ask a value for each of `defs` in turn, adding a filter for each answer,
--- then call `on_scope`. An empty answer skips that filter.
---@param scope GHReviewScope
---@param defs GHReviewFilterDef[]
---@param on_scope fun(scope: GHReviewScope)
function M.prompt_values(scope, defs, on_scope)
  local function step(i, current)
    local def = defs[i]
    if not def then
      on_scope(current)
      return
    end
    vim.ui.input({ prompt = def.input }, function(value)
      local filter = M.filter_from_value(def, value)
      step(i + 1, filter and M.with_filter(current, filter) or current)
    end)
  end
  step(1, scope)
end

--- Ask which filter to add, then its value, then call `on_scope` with the
--- filtered scope. Fallback of the filter manager without snacks.nvim.
---@param scope GHReviewScope
---@param on_scope fun(scope: GHReviewScope)
function M.prompt_filter(scope, on_scope)
  vim.ui.select(M.FILTERS, {
    prompt = "Filter PRs by",
    format_item = function(def) return def.label end,
  }, function(def)
    if not def then return end
    if def.choices then
      vim.ui.select(def.choices, {
        prompt = def.label,
        format_item = function(c) return c[1] end,
      }, function(choice)
        if not choice then return end
        on_scope(M.with_filter(scope, { kind = def.kind, qualifier = choice[2], text = choice[1] }))
      end)
      return
    end
    vim.ui.input({ prompt = def.input }, function(value)
      local filter = M.filter_from_value(def, value)
      if filter then on_scope(M.with_filter(scope, filter)) end
    end)
  end)
end

--- Scope kinds in the order they are offered.
M.KINDS = { "all", "mine", "review", "author" }

--- Build a scope from command-line style arguments, e.g. `{ "author", "alice" }`.
---@param args? string[]
---@return GHReviewScope? scope, string? err
function M.parse(args)
  args = args or {}
  local scope, rest
  local kind = args[1]
  if kind == nil or kind:find(":") then
    -- Only filters: they apply to all open PRs.
    scope, rest = { kind = "all" }, 1
  elseif not vim.tbl_contains(M.KINDS, kind) then
    return nil, "unknown scope '" .. kind .. "' (expected " .. table.concat(M.KINDS, "|") .. ", or search qualifiers)"
  elseif kind == "author" then
    local login = args[2] and args[2]:gsub("^@", "") or ""
    if login == "" or login:find(":") then
      return nil, "the author scope needs a login"
    end
    scope, rest = { kind = "author", login = login }, 3
  else
    scope, rest = { kind = kind }, 2
  end
  for i = rest, #args do
    if not args[i]:find(":") then
      return nil, "expected a search qualifier like draft:false, got '" .. args[i] .. "'"
    end
    scope = M.with_filter(scope, M.filter_from_qualifier(args[i]))
  end
  return scope
end

--- Short label for picker titles.
---@param scope GHReviewScope
---@return string
function M.label(scope)
  local label
  if scope.kind == "mine" then
    label = "mine"
  elseif scope.kind == "review" then
    label = "review requested, reviewed or assigned to me"
  elseif scope.kind == "author" then
    label = "author @" .. (scope.login or "?")
  else
    label = "all open"
  end
  for _, f in ipairs(scope.filters or {}) do
    label = label .. " · " .. f.text
  end
  return label
end

--- GitHub search qualifiers for a scope, one string per query to run. GitHub
--- search has no OR between qualifiers, so "involved in review" is two queries:
--- PRs that still wait for my review, and PRs I already reviewed. Both leave out
--- my own PRs.
---@param scope GHReviewScope
---@return string[]
function M.search_terms(scope)
  local terms
  if scope.kind == "mine" then
    terms = { "author:@me" }
  elseif scope.kind == "review" then
    terms = { "review-requested:@me -author:@me", "reviewed-by:@me -author:@me", "assignee:@me -author:@me" }
  elseif scope.kind == "author" then
    terms = { "author:" .. scope.login }
  else
    terms = { "" }
  end
  local quals = vim.tbl_map(function(f) return f.qualifier end, scope.filters or {})
  if #quals == 0 then return terms end
  local extra = table.concat(quals, " ")
  return vim.tbl_map(function(t) return vim.trim(t .. " " .. extra) end, terms)
end

--- Merge result lists from several queries, keeping the first copy of each PR.
--- A single list keeps its order; several lists are sorted newest first.
---@param lists table[][] PR lists, each entry with a `number`
---@return table[]
function M.merge_results(lists)
  if #lists == 1 then return lists[1] end
  local seen, merged = {}, {}
  for _, list in ipairs(lists) do
    for _, pr in ipairs(list) do
      if not seen[pr.number] then
        seen[pr.number] = true
        table.insert(merged, pr)
      end
    end
  end
  table.sort(merged, function(a, b) return a.number > b.number end)
  return merged
end

--- Run `fetch` once per search term of `scope` in parallel and merge the results.
--- The first error wins and is reported once.
---@param scope GHReviewScope
---@param fetch fun(term: string, cb: fun(err: string?, prs: table[]?))
---@param callback fun(err: string?, prs: table[]?)
function M.fetch_all(scope, fetch, callback)
  local terms = M.search_terms(scope)
  local results, pending, failed = {}, #terms, false
  for i, term in ipairs(terms) do
    fetch(term, function(err, prs)
      if failed then return end
      if err then
        failed = true
        callback(err, nil)
        return
      end
      results[i] = prs or {}
      pending = pending - 1
      if pending == 0 then
        callback(nil, M.merge_results(results))
      end
    end)
  end
end

--- Key hint for picker titles, e.g. "<a-s> filters · <a-x> clear".
---@param scope GHReviewScope
---@return string
function M.title_hint(scope)
  local keys_cfg = require("gh-review.config").get().picker_keys
  local parts = {}
  if keys_cfg.filter and keys_cfg.filter ~= "" then table.insert(parts, keys_cfg.filter .. " filters") end
  if #(scope.filters or {}) > 0 and keys_cfg.clear_filters and keys_cfg.clear_filters ~= "" then
    table.insert(parts, keys_cfg.clear_filters .. " clear")
  end
  return table.concat(parts, " · ")
end

--- Picker title: `prefix`, the scope label, and the filter key hint.
---@param prefix string
---@param scope GHReviewScope
---@return string
function M.title(prefix, scope)
  local hint = M.title_hint(scope)
  return prefix .. " — " .. M.label(scope) .. (hint ~= "" and ("  (" .. hint .. ")") or "")
end

--- Ask for an author login, then call `on_scope` with the author scope.
---@param on_scope fun(scope: GHReviewScope)
function M.prompt_author(on_scope)
  vim.ui.input({ prompt = "PR author (login): " }, function(login)
    login = login and vim.trim(login):gsub("^@", "") or ""
    if login == "" then return end
    on_scope({ kind = "author", login = login })
  end)
end

--- Picker key actions that switch scope or edit filters. `reopen` is called
--- with the new scope; the picker is closed first. Switching scope keeps the
--- filters of `current`.
---@param reopen fun(scope: GHReviewScope)
---@param current? GHReviewScope
---@return table<string, fun(picker: table)> actions, table<string, table> keys
function M.picker_actions(reopen, current)
  local keys_cfg = require("gh-review.config").get().picker_keys
  local filters = current and current.filters or nil
  local actions, keys = {}, {}
  local function bind(lhs, name, desc)
    if lhs and lhs ~= "" then keys[lhs] = { name, mode = { "i", "n" }, desc = desc } end
  end
  for _, kind in ipairs(M.KINDS) do
    local name = "scope_" .. kind
    actions[name] = function(picker)
      picker:close()
      if kind == "author" then
        M.prompt_author(function(scope)
          reopen(vim.tbl_extend("force", scope, { filters = filters }))
        end)
      else
        reopen({ kind = kind, filters = filters })
      end
    end
    bind(keys_cfg[name], name, "Scope: " .. kind)
  end
  actions.add_filter = function(picker)
    picker:close()
    require("gh-review.ui.filters").show(current or { kind = "all" }, reopen)
  end
  actions.clear_filters = function(picker)
    picker:close()
    reopen(M.without_filters(current or { kind = "all" }))
  end
  bind(keys_cfg.filter, "add_filter", "Add or remove filters")
  bind(keys_cfg.clear_filters, "clear_filters", "Clear filters")
  return actions, keys
end

return M
