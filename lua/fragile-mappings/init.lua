local M = {}

local function flag(v)
  return v == 1 or v == true
end

local function to_list(value)
  if value == nil then
    return {}
  end

  if type(value) == 'table' then
    return value
  end

  return { value }
end

local function notify(msg, level)
  vim.notify('[override_mappings] ' .. msg, level or vim.log.levels.INFO)
end

local function buffer_from_maparg(m)
  if m.buffer == nil or m.buffer == 0 or m.buffer == false then
    return nil
  end

  -- Чаще всего maparg возвращает флаг для buffer-local маппинга.
  -- Если вдруг там реальный номер буфера > 1, можно передать его.
  -- Иначе используем текущий буфер через true.
  if type(m.buffer) == 'number' and m.buffer > 1 then
    return m.buffer
  end

  return true
end

local function copy_mapping(old, new, mode)
  local m = vim.fn.maparg(old, mode, false, true)

  if vim.tbl_isempty(m) then
    return false, ('mapping not found: %s (%s)'):format(old, mode), true
  end

  local buf = buffer_from_maparg(m)

  local opts = {
    remap = not flag(m.noremap),
    silent = flag(m.silent),
    expr = flag(m.expr),
    nowait = flag(m.nowait),
    desc = (m.desc ~= nil and m.desc ~= '' and m.desc) or ('Moved from ' .. old),
  }

  if buf ~= nil then
    opts.buffer = buf
  end

  local ok, err = pcall(function()
    if m.rhs and m.rhs ~= '' then
      vim.keymap.set(mode, new, m.rhs, opts)
    elseif m.callback then
      vim.keymap.set(mode, new, m.callback, opts)
    else
      error(
        ('empty rhs/callback for %s (%s); run :verbose %smap %s'):format(
          old,
          mode,
          mode,
          old
        )
      )
    end
  end)

  if not ok then
    return false, tostring(err), false
  end

  local del_opts = buf and { buffer = buf } or nil
  pcall(vim.keymap.del, mode, old, del_opts)

  return true, nil, false
end

local function schedule(fn, delay)
  if delay and delay > 0 then
    vim.defer_fn(fn, delay)
  else
    vim.schedule(fn)
  end
end

function M.override(item)
  local old = item.old or item.lhs
  local new = item.new
  local modes = to_list(item.mode or 'n')

  if not old or not new then
    notify('old/new are required', vim.log.levels.ERROR)
    return
  end

  local retry = tonumber(item.retry or 0) or 0
  local retry_delay = tonumber(item.retry_delay or 100) or 100

  local attempt = 0
  local pending = modes

  local function run()
    local retry_modes = {}

    for _, mode in ipairs(pending) do
      local ok, err, not_found = copy_mapping(old, new, mode)

      if not ok then
        if not_found then
          table.insert(retry_modes, mode)
        else
          notify(err, vim.log.levels.ERROR)
        end
      end
    end

    if #retry_modes == 0 then
      return
    end

    if attempt < retry then
      attempt = attempt + 1
      pending = retry_modes
      vim.defer_fn(run, retry_delay)
    else
      for _, mode in ipairs(retry_modes) do
        notify(
          ('mapping still not found: %s (%s)'):format(old, mode),
          vim.log.levels.WARN
        )
      end
    end
  end

  run()
end

function M.setup(user_opts)
  local defaults = {
    delay = 0,
    retry = 0,
    retry_delay = 100,
    force_now = false,
  }

  local opts = vim.tbl_extend('force', defaults, user_opts or {})

  local mappings = opts.mappings or opts

  -- Если передали один маппинг напрямую:
  -- { old = ..., new = ... }
  if mappings.old or mappings.new then
    mappings = { mappings }
  end

  if type(mappings) ~= 'table' or vim.tbl_isempty(mappings) then
    return
  end

  local function run()
    for _, item in ipairs(mappings) do
      local merged = vim.tbl_extend('keep', item, {
        retry = opts.retry,
        retry_delay = opts.retry_delay,
      })

      M.override(merged)
    end
  end

  if vim.v.vim_did_enter == 1 or opts.force_now then
    schedule(run, opts.delay)
  else
    local group = vim.api.nvim_create_augroup('OverrideMappings', { clear = false })

    vim.api.nvim_create_autocmd('VimEnter', {
      group = group,
      once = true,
      callback = function()
        schedule(run, opts.delay)
      end,
    })
  end
end

return M
