local floats = require("dbee.floats")
local utils = require("dbee.utils")

local M = {}

---@param handler Handler
---@param conn connection_details
---@return Layout[]
local function connection_layout(handler, conn)
  ---@param structs DBStructure[]
  ---@param parent_id string
  ---@return Layout[]
  local function to_layout(structs, parent_id)
    if not structs then
      return {}
    end

    table.sort(structs, function(k1, k2)
      return k1.type .. k1.name < k2.type .. k2.name
    end)

    local new_layouts = {}
    for _, struct in ipairs(structs) do
      local layout_id = (parent_id or "") .. "__connection_" .. struct.name .. struct.schema .. struct.type .. "__"
      ---@type Layout
      local layout = {
        id = layout_id,
        name = struct.name,
        schema = struct.schema,
        type = struct.type,
        pick_items = struct.pick_items,
        children = to_layout(struct.children, layout_id),
      }

      if struct.type == "table" or struct.type == "view" then
        local helper_opts = { table = struct.name, schema = struct.schema, materialization = struct.type }
        layout.action_1 = function(cb, selection)
          local helpers = handler:helpers_get(conn.type, helper_opts)
          handler:connection_execute(conn.id, helpers[selection])
          cb()
        end
        layout.pick_items = function()
          return handler:helpers_get(conn.type, helper_opts)
        end
        layout.pick_title = "Select a Query"
      end

      table.insert(new_layouts, layout)
    end

    return new_layouts
  end

  -- recursively parse structure to drawer layout
  local layouts = to_layout(handler:connection_get_structure(conn.id), conn.id)

  -- call history
  local calls = handler:connection_get_calls(conn.id)
  if #calls > 0 then
    ---@type Layout
    local ly = {
      id = conn.id .. "_call_history__",
      name = "log",
      type = "history",
      action_1 = function(cb)
        floats.call_log(function()
          return handler:connection_get_calls(conn.id)
        end, {
          on_select = function(call)
            if call.state == "archived" or call.state == "retrieving" then
              -- TODO: display to result
            end
            cb()
          end,
          on_cancel = function(call)
            handler:call_cancel(call.id)
            cb()
          end,
        })
      end,
    }
    table.insert(layouts, 1, ly)
  end

  local current_db, _ = handler:connection_list_databases(conn.id)
  if current_db ~= "" then
    ---@type Layout
    local ly = {
      id = conn.id .. "_database_switch__",
      name = current_db,
      type = "database_switch",
      action_1 = function(cb, selection)
        handler:connection_select_database(conn.id, selection)
        cb()
      end,
      pick_title = "Select a Database",
    }
    table.insert(layouts, 1, ly)
  end

  return layouts
end

---@param handler Handler
---@return Layout[]
local function handler_layout_real(handler)
  ---@type Layout[]
  local layout = {}

  for _, source in ipairs(handler:get_sources()) do
    local source_id = source:name()

    local children = {}

    -- source can save edits
    if type(source.save) == "function" then
      table.insert(children, {
        id = "__source_add_connection__" .. source_id,
        name = "add",
        type = "add",
        action_1 = function(cb)
          local prompt = {
            { name = "name" },
            { name = "type" },
            { name = "url" },
            { name = "page size" },
          }
          floats.prompt(prompt, {
            title = "Add Connection",
            callback = function(result)
              local spec = {
                id = result.id,
                name = result.name,
                url = result.url,
                type = result.type,
                page_size = tonumber(result["page size"]),
              }
              pcall(handler.source_add_connections, handler, source_id, { spec })
              cb()
            end,
          })
        end,
      })
    end
    -- source has an editable source
    if type(source.file) == "function" then
      table.insert(children, {
        id = "__source_edit_connections__" .. source_id,
        name = "edit source",
        type = "edit",
        action_1 = function(cb)
          floats.editor(source:file(), {
            title = "Add Connection",
            callback = function()
              handler:source_reload(source_id)
              cb()
            end,
          })
        end,
      })
    end

    -- get connections of that source
    for _, conn in ipairs(handler:source_get_connections(source_id)) do
      ---@type Layout
      local ly = {
        id = conn.id,
        name = conn.name,
        type = "connection",
        -- set connection as active manually
        action_1 = function(cb)
          handler:set_current_connection(conn.id)
          cb()
        end,
        -- edit connection
        action_2 = function(cb)
          local original_details = conn:original_details()
          local prompt = {
            { name = "name", default = original_details.name },
            { name = "type", default = original_details.type },
            { name = "url", default = original_details.url },
            { name = "page size", default = tostring(original_details.page_size or "") },
          }
          floats.prompt(prompt, {
            title = "Edit Connection",
            callback = function(result)
              local spec = {
                -- keep the old id
                id = original_details.id,
                name = result.name,
                url = result.url,
                type = result.type,
                page_size = tonumber(result["page size"]),
              }
              pcall(handler.source_add_connections, handler, source_id, { spec })
              cb()
            end,
          })
        end,
        pick_title = "Confirm Deletion",
        pick_items = { "Yes", "No" },
        -- remove connection
        action_3 = function(cb, selection)
          if selection == "Yes" then
            handler:source_remove_connections(source_id, conn)
          end
          cb()
        end,
        children = function()
          return connection_layout(handler, conn)
        end,
      }

      table.insert(children, ly)
    end

    if #children > 0 then
      table.insert(layout, {
        id = "__source__" .. source_id,
        name = source_id,
        default_expand = utils.once:new("handler_expand_once_id" .. source_id),
        type = "source",
        children = children,
      })
    end
  end

  return layout
end

---@return Layout[]
local function handler_layout_help()
  return {
    {
      id = "__handler_help_id__",
      name = "No sources :(",
      default_expand = utils.once:new("handler_expand_once_helper_id"),
      type = "",
      children = {
        {
          id = "__handler_help_id_child_1__",
          name = 'Type ":h dbee.txt"',
          type = "",
        },
        {
          id = "__handler_help_id_child_2__",
          name = "to define your first source!",
          type = "",
        },
      },
    },
  }
end

---@return Layout[]
function M.handler_layout(handler)
  -- in case there are no sources defined, return a helper layout
  if #handler:get_sources() < 1 then
    return handler_layout_help()
  end
  return handler_layout_real(handler)
end

return M
