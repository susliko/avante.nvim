local api = vim.api
local fn = vim.fn
local uv = vim.uv

local curl = require("plenary.curl")

local Utils = require("avante.utils")
local Config = require("avante.config")
local Path = require("avante.path")
local P = require("avante.providers")

---@class avante.LLM
local M = {}

M.CANCEL_PATTERN = "AvanteLLMEscape"

------------------------------Prompt and type------------------------------

local group = api.nvim_create_augroup("avante_llm", { clear = true })

---@alias LlmMode "planning" | "editing" | "suggesting"
---
---@class TemplateOptions
---@field use_xml_format boolean
---@field ask boolean
---@field question string
---@field code_lang string
---@field file_content string
---@field selected_code string | nil
---@field project_context string | nil
---@field memory_context string | nil
---
---@class StreamOptions: TemplateOptions
---@field ask boolean
---@field bufnr integer
---@field instructions string
---@field mode LlmMode
---@field provider AvanteProviderFunctor | nil
---@field on_chunk AvanteChunkParser
---@field on_complete AvanteCompleteParser

---@param opts StreamOptions
M.stream = function(opts)
  local mode = opts.mode or "planning"
  ---@type AvanteProviderFunctor
  local Provider = opts.provider or P[Config.provider]

  -- Check if the instructions contains an image path
  local image_paths = {}
  local original_instructions = opts.instructions
  if opts.instructions:match("image: ") then
    local lines = vim.split(opts.instructions, "\n")
    for i, line in ipairs(lines) do
      if line:match("^image: ") then
        local image_path = line:gsub("^image: ", "")
        table.insert(image_paths, image_path)
        table.remove(lines, i)
      end
    end
    original_instructions = table.concat(lines, "\n")
  end

  Path.prompts.initialize(Path.prompts.get(opts.bufnr))

  local filepath = Utils.relative_path(api.nvim_buf_get_name(opts.bufnr))

  local template_opts = {
    use_xml_format = Provider.use_xml_format,
    ask = opts.ask, -- TODO: add mode without ask instruction
    question = original_instructions,
    code_lang = opts.code_lang,
    filepath = filepath,
    file_content = opts.file_content,
    selected_code = opts.selected_code,
    project_context = opts.project_context,
    memory_context = opts.memory_context,
  }

  local user_prompts = vim
    .iter({
      Path.prompts.render_file("_project.avanterules", template_opts),
      Path.prompts.render_file("_memory.avanterules", template_opts),
      Path.prompts.render_file("_context.avanterules", template_opts),
      Path.prompts.render_mode(mode, template_opts),
    })
    :filter(function(k) return k ~= "" end)
    :totable()

  ---@type AvantePromptOptions
  local code_opts = {
    system_prompt = Config.system_prompt,
    user_prompts = user_prompts,
    image_paths = image_paths,
  }

  ---@type string
  local current_event_state = nil

  ---@type AvanteHandlerOptions
  local handler_opts = { on_chunk = opts.on_chunk, on_complete = opts.on_complete }
  ---@type AvanteCurlOutput
  local spec = Provider.parse_curl_args(Provider, code_opts)

  ---@param line string
  local function parse_stream_data(line)
    local event = line:match("^event: (.+)$")
    if event then
      current_event_state = event
      return
    end
    local data_match = line:match("^data: (.+)$")
    if data_match then Provider.parse_response(data_match, current_event_state, handler_opts) end
  end

  local function parse_response_without_stream(data)
    Provider.parse_response_without_stream(data, current_event_state, handler_opts)
  end

  local completed = false

  local active_job

  local curl_body_file = fn.tempname() .. ".json"
  local json_content = vim.json.encode(spec.body)
  fn.writefile(vim.split(json_content, "\n"), curl_body_file)

  Utils.debug("curl body file:", curl_body_file)

  local function cleanup()
    if Config.debug then return end
    vim.schedule(function() fn.delete(curl_body_file) end)
  end

  active_job = curl.post(spec.url, {
    headers = spec.headers,
    proxy = spec.proxy,
    insecure = spec.insecure,
    body = curl_body_file,
    stream = function(err, data, _)
      if err then
        completed = true
        opts.on_complete(err)
        return
      end
      if not data then return end
      vim.schedule(function()
        if Config.options[Config.provider] == nil and Provider.parse_stream_data ~= nil then
          if Provider.parse_response ~= nil then
            Utils.warn(
              "parse_stream_data and parse_response_data are mutually exclusive, and thus parse_response_data will be ignored. Make sure that you handle the incoming data correctly.",
              { once = true }
            )
          end
          Provider.parse_stream_data(data, handler_opts)
        else
          if Provider.parse_stream_data ~= nil then
            Provider.parse_stream_data(data, handler_opts)
          else
            parse_stream_data(data)
          end
        end
      end)
    end,
    on_error = function(err)
      if err.exit == 23 then
        local xdg_runtime_dir = os.getenv("XDG_RUNTIME_DIR")
        if fn.isdirectory(xdg_runtime_dir) == 0 then
          Utils.error(
            "$XDG_RUNTIME_DIR="
              .. xdg_runtime_dir
              .. " is set but does not exist. curl could not write output. Please make sure it exists, or unset.",
            { title = "Avante" }
          )
        elseif not uv.fs_access(xdg_runtime_dir, "w") then
          Utils.error(
            "$XDG_RUNTIME_DIR="
              .. xdg_runtime_dir
              .. " exists but is not writable. curl could not write output. Please make sure it is writable, or unset.",
            { title = "Avante" }
          )
        end
      end
      active_job = nil
      completed = true
      cleanup()
      opts.on_complete(nil)
    end,
    callback = function(result)
      active_job = nil
      cleanup()
      if result.status >= 400 then
        if Provider.on_error then
          Provider.on_error(result)
        else
          Utils.error("API request failed with status " .. result.status, { once = true, title = "Avante" })
        end
        vim.schedule(function()
          if not completed then
            completed = true
            opts.on_complete(
              "API request failed with status " .. result.status .. ". Body: " .. vim.inspect(result.body)
            )
          end
        end)
      end

      -- If stream is not enabled, then handle the response here
      if spec.body.stream == false and result.status == 200 then
        vim.schedule(function()
          completed = true
          parse_response_without_stream(result.body)
        end)
      end
    end,
  })

  api.nvim_create_autocmd("User", {
    group = group,
    pattern = M.CANCEL_PATTERN,
    once = true,
    callback = function()
      -- Error: cannot resume dead coroutine
      if active_job then
        xpcall(function() active_job:shutdown() end, function(err) return err end)
        Utils.debug("LLM request cancelled")
        active_job = nil
      end
    end,
  })

  return active_job
end

function M.cancel_inflight_request() api.nvim_exec_autocmds("User", { pattern = M.CANCEL_PATTERN }) end

return M
