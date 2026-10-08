defmodule Arbor.ACP.Types do
  @moduledoc """
  Type specifications and builder functions for the Agent Client Protocol (ACP).

  ACP uses JSON-RPC 2.0 as its wire format (same as MCP). Protocol objects are plain maps with string keys and string discriminators,
  such as `%{"type" => "text", "text" => "Hello"}`. Builders produce those
  wire shapes. Elixir typespecs cannot express individual literal binary keys
  or string enum values. Named object types describe JSON maps; the field shapes
  below document protocol requirements and allow additional extension fields.

  ## Content Blocks

  ACP supports text and image content blocks in prompts and responses:

      text_block("Hello, world!")
      image_block("image/png", "base64data...")

  ## Session Management

  Sessions track agent conversations. Create with `new_session_params/2`,
  send prompts with `prompt_params/2`.
  """

  alias Arbor.ACP.Envelope
  alias Arbor.ACP.Maps
  alias Arbor.ACP.NameValue

  @typedoc "A JSON-compatible value; protocol maps have binary keys."
  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()

  @typedoc "A protocol JSON object with string keys, including extension fields."
  @type json_object :: %{optional(String.t()) => json_value()}

  # Content blocks

  @typedoc """
  String-keyed JSON object for content block. Wire field/variant shape:

  ```text
  text_block()
  | image_block()
  | audio_block()
  | resource_link_block()
  | resource_block()
  ```
  """
  @type content_block :: json_object()

  @typedoc """
  String-keyed JSON object for text block. Wire field/variant shape:

  ```text
  %{
  required "type" => "text",
  required "text" => String.t()
  }
  ```
  """
  @type text_block :: json_object()

  @typedoc """
  String-keyed JSON object for image block. Wire field/variant shape:

  ```text
  %{
  required "type" => "image",
  required "mimeType" => String.t(),
  required "data" => String.t()
  }
  ```
  """
  @type image_block :: json_object()

  @typedoc """
  String-keyed JSON object for audio block. Wire field/variant shape:

  ```text
  %{
  required "type" => "audio",
  required "mimeType" => String.t(),
  required "data" => String.t()
  }
  ```
  """
  @type audio_block :: json_object()

  @typedoc """
  String-keyed JSON object for resource link block. Wire field/variant shape:

  ```text
  %{
  required "type" => "resource_link",
  required "uri" => String.t(),
  required "name" => String.t(),
  optional "mimeType" => String.t(),
  optional "title" => String.t(),
  optional "description" => String.t(),
  optional "size" => non_neg_integer()
  }
  ```
  """
  @type resource_link_block :: json_object()

  @typedoc """
  String-keyed JSON object for resource block. Wire field/variant shape:

  ```text
  %{
  required "type" => "resource",
  required "resource" => embedded_resource()
  }
  ```
  """
  @type resource_block :: json_object()

  @typedoc """
  String-keyed JSON object for embedded resource. Wire field/variant shape:

  ```text
  %{
  required "uri" => String.t(),
  required "text" => String.t(),
  optional "mimeType" => String.t()
  }
  | %{
  required "uri" => String.t(),
  required "blob" => String.t(),
  optional "mimeType" => String.t()
  }
  ```
  """
  @type embedded_resource :: json_object()

  # Capabilities

  @typedoc """
  String-keyed JSON object for client capabilities. Wire field/variant shape:

  ```text
  %{
  optional "fs" => %{
  optional "readTextFile" => boolean(),
  optional "writeTextFile" => boolean()
  },
  optional "terminal" => boolean(),
  optional "elicitation" => %{
  optional "form" => map() | nil,
  optional "url" => map() | nil
  }
  }
  ```
  """
  @type client_capabilities :: json_object()

  @typedoc """
  String-keyed JSON object for form elicitation request. Wire field/variant shape:

  ```text
  %{
  required "mode" => "form",
  required "message" => String.t(),
  required "requestedSchema" => map(),
  optional "sessionId" => String.t(),
  optional "toolCallId" => String.t() | nil,
  optional "requestId" => integer() | String.t(),
  optional "_meta" => map() | nil
  }
  ```
  """
  @type form_elicitation_request :: json_object()

  @typedoc """
  String-keyed JSON object for url elicitation request. Wire field/variant shape:

  ```text
  %{
  required "mode" => "url",
  required "message" => String.t(),
  required "elicitationId" => String.t(),
  required "url" => String.t(),
  optional "sessionId" => String.t(),
  optional "toolCallId" => String.t() | nil,
  optional "requestId" => integer() | String.t(),
  optional "_meta" => map() | nil
  }
  ```
  """
  @type url_elicitation_request :: json_object()

  @typedoc """
  String-keyed JSON object for elicitation request. Wire field/variant shape:

  ```text
  form_elicitation_request() | url_elicitation_request()
  ```
  """
  @type elicitation_request :: json_object()

  @typedoc """
  String-keyed JSON object for elicitation response. Wire field/variant shape:

  ```text
  %{
  required "action" => "accept" | "decline" | "cancel",
  optional "content" => map() | nil,
  optional "_meta" => map() | nil
  }
  ```
  """
  @type elicitation_response :: json_object()

  @typedoc """
  String-keyed JSON object for agent capabilities. Wire field/variant shape:

  ```text
  %{
  optional "auth" => %{
  optional "logout" => map() | nil
  },
  optional "loadSession" => boolean(),
  optional "promptCapabilities" => %{
  optional "image" => boolean(),
  optional "audio" => boolean(),
  optional "embeddedContext" => boolean()
  },
  optional "mcpCapabilities" => %{
  optional "acp" => boolean(),
  optional "http" => boolean(),
  optional "sse" => boolean(),
  optional "_meta" => map()
  },
  optional "sessionCapabilities" => %{
  optional "list" => session_list_capabilities() | nil,
  optional "resume" => session_resume_capabilities() | nil,
  optional "close" => session_close_capabilities() | nil,
  optional "delete" => session_delete_capabilities() | nil,
  optional "fork" => session_fork_capabilities() | nil,
  optional "additionalDirectories" => map() | nil
  }
  }
  ```
  """
  @type agent_capabilities :: json_object()

  @typedoc """
  String-keyed JSON object for session list capabilities. Wire field/variant shape:

  ```text
  map()
  ```
  """
  @type session_list_capabilities :: json_object()
  @typedoc """
  String-keyed JSON object for session resume capabilities. Wire field/variant shape:

  ```text
  map()
  ```
  """
  @type session_resume_capabilities :: json_object()
  @typedoc """
  String-keyed JSON object for session close capabilities. Wire field/variant shape:

  ```text
  map()
  ```
  """
  @type session_close_capabilities :: json_object()
  @typedoc """
  String-keyed JSON object for session delete capabilities. Wire field/variant shape:

  ```text
  map()
  ```
  """
  @type session_delete_capabilities :: json_object()
  @typedoc """
  String-keyed JSON object for session fork capabilities. Wire field/variant shape:

  ```text
  map()
  ```
  """
  @type session_fork_capabilities :: json_object()

  @typedoc """
  String-keyed JSON object for mode. Wire field/variant shape:

  ```text
  %{
  required "id" => String.t(),
  required "name" => String.t(),
  optional "description" => String.t()
  }
  ```
  """
  @type mode :: json_object()

  @typedoc """
  String-keyed JSON object for config option. Wire field/variant shape:

  ```text
  %{
  required "id" => String.t(),
  required "name" => String.t(),
  required "type" => String.t(),
  required "currentValue" => String.t(),
  required "options" => list(),
  optional "description" => String.t(),
  optional "category" => String.t()
  }
  ```
  """
  @type config_option :: json_object()

  # ACP Error Codes
  # Standard JSON-RPC: -32700 (parse), -32600 (invalid request), -32601 (method not found),
  #                    -32602 (invalid params), -32603 (internal error)
  # ACP-specific:
  @auth_required_code -32_000
  @resource_not_found_code -32_002
  @request_cancelled_code -32_800

  @doc "Error code indicating authentication is required."
  @spec auth_required_code() :: integer()
  def auth_required_code, do: @auth_required_code

  @doc "Error code indicating a resource was not found."
  @spec resource_not_found_code() :: integer()
  def resource_not_found_code, do: @resource_not_found_code

  @doc "Error code indicating a request was cancelled."
  @spec request_cancelled_code() :: integer()
  def request_cancelled_code, do: @request_cancelled_code

  # Initialize

  @typedoc """
  String-keyed JSON object for client info. Wire field/variant shape:

  ```text
  %{
  required "name" => String.t(),
  required "version" => String.t(),
  optional "title" => String.t()
  }
  ```
  """
  @type client_info :: json_object()

  @typedoc """
  String-keyed JSON object for agent info. Wire field/variant shape:

  ```text
  %{
  required "name" => String.t(),
  required "version" => String.t(),
  optional "title" => String.t()
  }
  ```
  """
  @type agent_info :: json_object()

  @typedoc """
  String-keyed JSON object for initialize request. Wire field/variant shape:

  ```text
  %{
  required "clientInfo" => client_info(),
  optional "clientCapabilities" => client_capabilities(),
  optional "protocolVersion" => pos_integer()
  }
  ```
  """
  @type initialize_request :: json_object()

  @typedoc """
  String-keyed JSON object for initialize response. Wire field/variant shape:

  ```text
  %{
  required "agentInfo" => agent_info(),
  optional "agentCapabilities" => agent_capabilities(),
  optional "authMethods" => [auth_method()],
  optional "protocolVersion" => pos_integer()
  }
  ```
  """
  @type initialize_response :: json_object()

  @typedoc """
  String-keyed JSON object for auth method. Wire field/variant shape:

  ```text
  %{
  required "id" => String.t(),
  required "name" => String.t(),
  optional "description" => String.t(),
  optional "type" => String.t()
  }
  ```
  """
  @type auth_method :: json_object()

  # Sessions

  @typedoc """
  String-keyed JSON object for mcp server. Wire field/variant shape:

  ```text
  stdio_mcp_server() | http_mcp_server() | sse_mcp_server()
  ```
  """
  @type mcp_server :: json_object()

  @typedoc """
  String-keyed JSON object for stdio mcp server. Wire field/variant shape:

  ```text
  %{
  required "type" => "stdio",
  required "name" => String.t(),
  required "command" => String.t(),
  required "args" => [String.t()],
  required "env" => [env_variable()]
  }
  ```
  """
  @type stdio_mcp_server :: json_object()

  @typedoc """
  String-keyed JSON object for http mcp server. Wire field/variant shape:

  ```text
  %{
  required "type" => "http",
  required "name" => String.t(),
  required "url" => String.t(),
  required "headers" => [http_header()]
  }
  ```
  """
  @type http_mcp_server :: json_object()

  @typedoc """
  String-keyed JSON object for sse mcp server. Wire field/variant shape:

  ```text
  %{
  required "type" => "sse",
  required "name" => String.t(),
  required "url" => String.t(),
  required "headers" => [http_header()]
  }
  ```
  """
  @type sse_mcp_server :: json_object()

  @typedoc """
  String-keyed JSON object for env variable. Wire field/variant shape:

  ```text
  %{
  required "name" => String.t(),
  required "value" => String.t()
  }
  ```
  """
  @type env_variable :: json_object()

  @typedoc """
  String-keyed JSON object for http header. Wire field/variant shape:

  ```text
  %{
  required "name" => String.t(),
  required "value" => String.t()
  }
  ```
  """
  @type http_header :: json_object()

  @typedoc """
  String-keyed JSON object for new session request. Wire field/variant shape:

  ```text
  %{
  required "cwd" => String.t(),
  required "mcpServers" => [mcp_server()],
  optional "additionalDirectories" => [String.t()]
  }
  ```
  """
  @type new_session_request :: json_object()

  @typedoc """
  String-keyed JSON object for new session response. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t()
  }
  ```
  """
  @type new_session_response :: json_object()

  @typedoc """
  String-keyed JSON object for list sessions request. Wire field/variant shape:

  ```text
  %{
  optional "cursor" => String.t(),
  optional "cwd" => String.t()
  }
  ```
  """
  @type list_sessions_request :: json_object()

  @typedoc """
  String-keyed JSON object for list sessions response. Wire field/variant shape:

  ```text
  %{
  required "sessions" => [session_info()],
  optional "nextCursor" => String.t()
  }
  ```
  """
  @type list_sessions_response :: json_object()

  @typedoc """
  String-keyed JSON object for session info. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "cwd" => String.t(),
  optional "title" => String.t(),
  optional "updatedAt" => String.t(),
  optional "additionalDirectories" => [String.t()]
  }
  ```
  """
  @type session_info :: json_object()

  @typedoc """
  String-keyed JSON object for load session request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "cwd" => String.t(),
  required "mcpServers" => [mcp_server()],
  optional "additionalDirectories" => [String.t()]
  }
  ```
  """
  @type load_session_request :: json_object()

  @typedoc """
  String-keyed JSON object for resume session request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "cwd" => String.t(),
  optional "mcpServers" => [mcp_server()],
  optional "additionalDirectories" => [String.t()]
  }
  ```
  """
  @type resume_session_request :: json_object()

  @typedoc """
  String-keyed JSON object for close session request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t()
  }
  ```
  """
  @type close_session_request :: json_object()

  @typedoc """
  String-keyed JSON object for delete session request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t()
  }
  ```
  """
  @type delete_session_request :: json_object()

  @typedoc """
  String-keyed JSON object for fork session request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "cwd" => String.t(),
  optional "mcpServers" => [mcp_server()],
  optional "additionalDirectories" => [String.t()]
  }
  ```
  """
  @type fork_session_request :: json_object()

  @typedoc """
  String-keyed JSON object for fork session response. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  optional "modes" => map() | nil,
  optional "configOptions" => [config_option()] | nil
  }
  ```
  """
  @type fork_session_response :: json_object()

  @typedoc """
  String-keyed JSON object for prompt request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "prompt" => [content_block()]
  }
  ```
  """
  @type prompt_request :: json_object()

  @typedoc """
  String-keyed JSON object for prompt response. Wire field/variant shape:

  ```text
  %{
  required "stopReason" => String.t()
  }
  ```
  """
  @type prompt_response :: json_object()

  # Session updates — nested under "update" with "sessionUpdate" discriminator
  #
  # Official ACP spec types (https://agentclientprotocol.com/protocol/schema):
  #   user_message_chunk, agent_message_chunk, tool_call, tool_call_update, plan,
  #   available_commands_update, config_option_update, current_mode_update,
  #   session_info_update, usage_update, agent_thought_chunk

  @typedoc """
  String-keyed JSON object for session update params. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "update" => session_update()
  }
  ```
  """
  @type session_update_params :: json_object()

  @typedoc """
  String-keyed JSON object for session update. Wire field/variant shape:

  ```text
  user_message_chunk_update()
  | agent_message_chunk_update()
  | agent_thought_chunk_update()
  | tool_call()
  | tool_call_update()
  | plan()
  | available_commands_update()
  | config_option_update()
  | current_mode_update()
  | session_info_update()
  | usage_update()
  ```
  """
  @type session_update :: json_object()

  # ── Spec-defined session update types ──────────────────────────

  @typedoc """
  String-keyed JSON object for user message chunk update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "user_message_chunk",
  required "content" => content_block()
  }
  ```
  """
  @type user_message_chunk_update :: json_object()

  @typedoc """
  String-keyed JSON object for agent message chunk update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "agent_message_chunk",
  required "content" => content_block()
  }
  ```
  """
  @type agent_message_chunk_update :: json_object()

  @typedoc """
  String-keyed JSON object for agent thought chunk update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "agent_thought_chunk",
  required "content" => content_block()
  }
  ```
  """
  @type agent_thought_chunk_update :: json_object()

  @typedoc """
  String-keyed JSON object for tool call. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "tool_call",
  required "toolCallId" => String.t(),
  required "title" => String.t(),
  optional "status" => String.t(),
  optional "content" => [map()]
  }
  ```
  """
  @type tool_call :: json_object()

  @typedoc """
  String-keyed JSON object for tool call update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "tool_call_update",
  required "toolCallId" => String.t(),
  optional "title" => String.t(),
  optional "status" => String.t(),
  optional "content" => [map()]
  }
  ```
  """
  @type tool_call_update :: json_object()

  @typedoc """
  String-keyed JSON object for plan. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "plan",
  required "entries" => [plan_entry()]
  }
  ```
  """
  @type plan :: json_object()

  @typedoc """
  String-keyed JSON object for plan entry. Wire field/variant shape:

  ```text
  %{
  required "content" => String.t(),
  required "priority" => "high" | "medium" | "low",
  required "status" => "pending" | "in_progress" | "completed"
  }
  ```
  """
  @type plan_entry :: json_object()

  @typedoc """
  String-keyed JSON object for available commands update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "available_commands_update",
  required "availableCommands" => [map()]
  }
  ```
  """
  @type available_commands_update :: json_object()

  @typedoc """
  String-keyed JSON object for config option update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "config_option_update",
  required "configOptions" => [config_option()]
  }
  ```
  """
  @type config_option_update :: json_object()

  @typedoc """
  String-keyed JSON object for current mode update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "current_mode_update",
  required "currentModeId" => String.t()
  }
  ```
  """
  @type current_mode_update :: json_object()

  @typedoc """
  String-keyed JSON object for session info update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "session_info_update",
  optional "title" => String.t(),
  optional "updatedAt" => String.t()
  }
  ```
  """
  @type session_info_update :: json_object()

  @typedoc """
  String-keyed JSON object for usage update. Wire field/variant shape:

  ```text
  %{
  required "sessionUpdate" => "usage_update",
  required "used" => non_neg_integer(),
  required "size" => non_neg_integer(),
  optional "cost" => map()
  }
  ```
  """
  @type usage_update :: json_object()

  # Permission handling

  @typedoc """
  String-keyed JSON object for permission option. Wire field/variant shape:

  ```text
  %{
  required "optionId" => String.t(),
  required "name" => String.t(),
  required "kind" => String.t(),
  optional "description" => String.t()
  }
  ```
  """
  @type permission_option :: json_object()

  @typedoc """
  String-keyed JSON object for permission outcome. Wire field/variant shape:

  ```text
  %{
  required "outcome" => String.t(),
  optional "optionId" => String.t()
  }
  ```
  """
  @type permission_outcome :: json_object()

  @typedoc """
  String-keyed JSON object for permission request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "toolCall" => tool_call_info(),
  required "options" => [permission_option()]
  }
  ```
  """
  @type permission_request :: json_object()

  @typedoc """
  String-keyed JSON object for tool call info. Wire field/variant shape:

  ```text
  %{
  required "toolName" => String.t(),
  optional "toolCallId" => String.t(),
  optional "arguments" => map()
  }
  ```
  """
  @type tool_call_info :: json_object()

  # File operations

  @typedoc """
  String-keyed JSON object for file read request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "path" => String.t(),
  optional "line" => non_neg_integer(),
  optional "limit" => non_neg_integer()
  }
  ```
  """
  @type file_read_request :: json_object()

  @typedoc """
  String-keyed JSON object for file write request. Wire field/variant shape:

  ```text
  %{
  required "sessionId" => String.t(),
  required "path" => String.t(),
  required "content" => String.t()
  }
  ```
  """
  @type file_write_request :: json_object()

  # Builder functions

  @doc "Creates a text content block."
  @spec text_block(String.t(), keyword()) :: text_block()
  def text_block(text, opts \\ []) when is_binary(text) do
    %{"type" => "text", "text" => text}
    |> maybe_put_kw("annotations", opts)
    |> maybe_put_kw("_meta", opts)
  end

  @doc "Creates an image content block."
  @spec image_block(String.t(), String.t(), keyword()) :: image_block()
  def image_block(mime_type, data, opts \\ []) when is_binary(mime_type) and is_binary(data) do
    %{"type" => "image", "mimeType" => mime_type, "data" => data}
    |> maybe_put_kw("uri", opts)
    |> maybe_put_kw("annotations", opts)
    |> maybe_put_kw("_meta", opts)
  end

  @doc "Creates an audio content block."
  @spec audio_block(String.t(), String.t(), keyword()) :: audio_block()
  def audio_block(mime_type, data, opts \\ []) when is_binary(mime_type) and is_binary(data) do
    %{"type" => "audio", "mimeType" => mime_type, "data" => data}
    |> maybe_put_kw("annotations", opts)
    |> maybe_put_kw("_meta", opts)
  end

  @doc "Creates a resource link content block."
  @spec resource_link_block(String.t(), keyword()) :: resource_link_block()
  def resource_link_block(uri, opts \\ []) when is_binary(uri) do
    name = Keyword.get(opts, :name, Path.basename(uri))

    %{"type" => "resource_link", "uri" => uri, "name" => name}
    |> maybe_put_kw("mimeType", opts)
    |> maybe_put_kw("title", opts)
    |> maybe_put_kw("description", opts)
    |> maybe_put_kw("size", opts)
    |> maybe_put_kw("annotations", opts)
    |> maybe_put_kw("_meta", opts)
  end

  @doc "Creates a resource content block."
  @spec resource_block(String.t(), keyword()) :: resource_block()
  def resource_block(uri, opts \\ []) when is_binary(uri) do
    resource =
      %{"uri" => uri}
      |> maybe_put_kw("mimeType", opts)
      |> maybe_put_kw("_meta", opts)

    resource =
      case Keyword.fetch(opts, :blob) do
        {:ok, blob} -> Map.put(resource, "blob", blob)
        :error -> Map.put(resource, "text", Keyword.get(opts, :text, ""))
      end

    %{"type" => "resource", "resource" => resource}
    |> maybe_put_kw("annotations", opts)
    |> maybe_put_kw("_meta", opts)
  end

  @doc "Creates client info for the initialize handshake."
  @spec client_info(String.t(), String.t(), keyword()) :: client_info()
  def client_info(name, version, opts \\ []) when is_binary(name) and is_binary(version) do
    %{"name" => name, "version" => version}
    |> maybe_put_kw("title", opts)
    |> maybe_put_kw("_meta", opts)
  end

  @doc "Creates an authentication method advertised by an agent."
  @spec auth_method(String.t(), String.t(), keyword()) :: auth_method()
  def auth_method(id, name, opts \\ []) when is_binary(id) and is_binary(name) do
    %{"id" => id, "name" => name}
    |> maybe_put_kw("description", opts)
    |> maybe_put_kw("type", opts)
  end

  @doc """
  Creates ACP agent capabilities.

  Supported options: `:load_session`, `:acp_mcp`, `:http_mcp`, `:sse_mcp`,
  `:beam_mcp`, `:image`, `:audio`, `:embedded_context`,
  `:session_list`, `:session_resume`, `:session_close`, `:session_delete`,
  `:session_fork`, `:additional_directories`, and `:logout`.
  """
  @spec agent_capabilities(keyword()) :: agent_capabilities()
  def agent_capabilities(opts \\ []) do
    %{}
    |> maybe_put_bool("loadSession", opts, :load_session)
    |> Maps.put_unless("promptCapabilities", prompt_capabilities(opts), %{})
    |> Maps.put_unless("mcpCapabilities", mcp_capabilities(opts), %{})
    |> Maps.put_unless("sessionCapabilities", session_capabilities(opts), %{})
    |> Maps.put_unless("auth", auth_capabilities(opts), %{})
  end

  @doc "Creates session capability metadata."
  @spec session_capabilities(keyword()) :: json_object()
  def session_capabilities(opts \\ []) do
    %{}
    |> maybe_put_capability("list", Keyword.get(opts, :list, Keyword.get(opts, :session_list)))
    |> maybe_put_capability(
      "resume",
      Keyword.get(opts, :resume, Keyword.get(opts, :session_resume))
    )
    |> maybe_put_capability("close", Keyword.get(opts, :close, Keyword.get(opts, :session_close)))
    |> maybe_put_capability(
      "delete",
      Keyword.get(opts, :delete, Keyword.get(opts, :session_delete))
    )
    |> maybe_put_capability("fork", Keyword.get(opts, :fork, Keyword.get(opts, :session_fork)))
    |> maybe_put_capability(
      "additionalDirectories",
      Keyword.get(
        opts,
        :session_additional_directories,
        Keyword.get(opts, :additional_directories)
      )
    )
  end

  @doc "Creates a plan entry."
  @spec plan_entry(String.t(), String.t(), String.t()) :: plan_entry()
  def plan_entry(content, priority \\ "medium", status \\ "pending") do
    %{"content" => content, "priority" => priority, "status" => status}
  end

  @doc "Creates a stable ACP `plan` session update notification."
  @spec plan(String.t(), [map()]) :: plan()
  def plan(session_id, entries) when is_list(entries) do
    session_update(session_id, %{
      "sessionUpdate" => "plan",
      "entries" => entries
    })
  end

  @doc "Creates a stable ACP `plan` session update notification."
  @spec plan_update(String.t(), [map()]) :: json_object()
  def plan_update(session_id, entries) when is_list(entries) do
    plan(session_id, entries)
  end

  @doc "Creates an available_commands_update session update notification."
  @spec available_commands_update(String.t(), [map()]) :: available_commands_update()
  def available_commands_update(session_id, commands) when is_list(commands) do
    session_update(session_id, %{
      "sessionUpdate" => "available_commands_update",
      "availableCommands" => commands
    })
  end

  @doc "Creates a config_option_update session update notification."
  @spec config_option_update(String.t(), [map()]) :: config_option_update()
  def config_option_update(session_id, config_options) when is_list(config_options) do
    session_update(session_id, %{
      "sessionUpdate" => "config_option_update",
      "configOptions" => config_options
    })
  end

  @doc "Creates a current_mode_update session update notification."
  @spec current_mode_update(String.t(), String.t()) :: current_mode_update()
  def current_mode_update(session_id, current_mode_id) do
    session_update(session_id, %{
      "sessionUpdate" => "current_mode_update",
      "currentModeId" => current_mode_id
    })
  end

  @doc "Creates a session_info_update session update notification."
  @spec session_info_update(String.t(), keyword()) :: session_info_update()
  def session_info_update(session_id, opts \\ []) do
    update =
      %{"sessionUpdate" => "session_info_update"}
      |> maybe_put_kw("title", opts)
      |> maybe_put_kw("updatedAt", opts)

    session_update(session_id, update)
  end

  @doc "Creates a usage_update session update notification."
  @spec usage_update(String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          usage_update()
  def usage_update(session_id, used, size, opts \\ []) do
    update =
      %{"sessionUpdate" => "usage_update", "used" => used, "size" => size}
      |> maybe_put_kw("cost", opts)

    session_update(session_id, update)
  end

  @doc "Creates a config option value for select-style session config."
  @spec config_option_value(String.t(), String.t(), keyword()) :: json_object()
  def config_option_value(value, name, opts \\ []) do
    %{"value" => value, "name" => name}
    |> maybe_put_kw("description", opts)
  end

  @doc "Creates a select-style session config option."
  @spec select_config_option(String.t(), String.t(), String.t(), [map()], keyword()) ::
          json_object()
  def select_config_option(id, name, current_value, options, opts \\ []) do
    %{
      "id" => id,
      "name" => name,
      "type" => "select",
      "currentValue" => current_value,
      "options" => options
    }
    |> maybe_put_kw("description", opts)
    |> maybe_put_kw("category", opts)
  end

  @doc "Creates a session info entry returned by session/list."
  @spec session_info(String.t(), String.t(), keyword()) :: session_info()
  def session_info(session_id, cwd, opts \\ []) do
    %{"sessionId" => session_id, "cwd" => cwd}
    |> maybe_put_kw("title", opts)
    |> maybe_put_kw("updatedAt", opts)
    |> maybe_put_kw("additionalDirectories", opts, :additional_directories)
  end

  @doc "Creates an environment variable entry for a stdio MCP server."
  @spec env_variable(String.t(), String.t()) :: env_variable()
  def env_variable(name, value), do: %{"name" => name, "value" => value}

  @doc "Creates an HTTP header entry for a Streamable HTTP MCP server."
  @spec http_header(String.t(), String.t()) :: http_header()
  def http_header(name, value), do: %{"name" => name, "value" => value}

  @doc "Creates a stdio MCP server config for ACP session setup."
  @spec stdio_mcp_server(String.t(), String.t(), keyword()) :: stdio_mcp_server()
  def stdio_mcp_server(name, command, opts \\ []) do
    %{
      "type" => "stdio",
      "name" => name,
      "command" => command,
      "args" => Keyword.get(opts, :args, []),
      "env" => normalize_env(Keyword.get(opts, :env, []))
    }
  end

  @doc "Creates an HTTP MCP server config for ACP session setup."
  @spec http_mcp_server(String.t(), String.t(), keyword()) :: http_mcp_server()
  def http_mcp_server(name, url, opts \\ []) do
    %{
      "type" => "http",
      "name" => name,
      "url" => url,
      "headers" => normalize_headers(Keyword.get(opts, :headers, []))
    }
  end

  @doc "Creates an SSE MCP server config for ACP session setup."
  @spec sse_mcp_server(String.t(), String.t(), keyword()) :: sse_mcp_server()
  def sse_mcp_server(name, url, opts \\ []) do
    %{
      "type" => "sse",
      "name" => name,
      "url" => url,
      "headers" => normalize_headers(Keyword.get(opts, :headers, []))
    }
  end

  @doc """
  Creates params for a new session request.

  ## Options

  - `:mcp_servers` - list of MCP server maps, preferably from
    `stdio_mcp_server/3`, `http_mcp_server/3`, or `sse_mcp_server/3`
  - `:additional_directories` - extra absolute workspace root paths
  """
  @spec new_session_params(String.t(), keyword()) :: json_object()
  def new_session_params(cwd, opts \\ []) when is_binary(cwd) do
    %{"cwd" => cwd}
    |> then(fn params ->
      case Keyword.get(opts, :mcp_servers) do
        nil -> Map.put(params, "mcpServers", [])
        servers -> Map.put(params, "mcpServers", servers)
      end
    end)
    |> maybe_put_kw("additionalDirectories", opts, :additional_directories)
  end

  @doc """
  Creates params for a prompt request.

  Content can be a string (auto-wrapped as text block) or a list of content block maps.
  """
  @spec prompt_params(String.t(), String.t() | [map()]) :: json_object()
  def prompt_params(session_id, content) when is_binary(session_id) do
    blocks =
      case content do
        text when is_binary(text) -> [text_block(text)]
        blocks when is_list(blocks) -> blocks
      end

    %{"sessionId" => session_id, "prompt" => blocks}
  end

  # Private helpers

  defp prompt_capabilities(opts) do
    %{}
    |> maybe_put_bool("image", opts, :image)
    |> maybe_put_bool("audio", opts, :audio)
    |> maybe_put_bool("embeddedContext", opts, :embedded_context)
  end

  defp mcp_capabilities(opts) do
    %{}
    |> maybe_put_bool("acp", opts, :acp_mcp)
    |> maybe_put_bool("http", opts, :http_mcp)
    |> maybe_put_bool("sse", opts, :sse_mcp)
    |> maybe_put_beam_mcp_meta(opts)
  end

  defp maybe_put_beam_mcp_meta(map, opts) do
    beam? = Keyword.get(opts, :beam_mcp)

    meta =
      %{}
      |> maybe_put_bool("beam", [beam: beam?], :beam)

    if map_size(meta) > 0 do
      Map.put(map, "_meta", %{"ex_mcp.mcpCapabilities" => meta})
    else
      map
    end
  end

  defp auth_capabilities(opts) do
    %{}
    |> maybe_put_capability("logout", Keyword.get(opts, :logout))
  end

  defp session_update(session_id, update) do
    Envelope.notification("session/update", %{
      "sessionId" => session_id,
      "update" => update
    })
  end

  defp maybe_put_bool(map, key, opts, opt_key) do
    case Keyword.get(opts, opt_key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_capability(map, _key, nil), do: map
  defp maybe_put_capability(map, _key, false), do: map
  defp maybe_put_capability(map, key, true), do: Map.put(map, key, %{})
  defp maybe_put_capability(map, key, value) when is_map(value), do: Map.put(map, key, value)
  defp maybe_put_capability(map, key, _value), do: Map.put(map, key, %{})

  defp normalize_env(env) when is_map(env) do
    NameValue.list(env, &env_variable/2)
  end

  defp normalize_env(env) when is_list(env) do
    NameValue.list(env, &env_variable/2)
  end

  defp normalize_headers(headers) when is_map(headers) do
    NameValue.list(headers, &http_header/2)
  end

  defp normalize_headers(headers) when is_list(headers) do
    NameValue.list(headers, &http_header/2)
  end

  defp maybe_put_kw(map, key, opts) do
    atom_key = String.to_existing_atom(key)

    case Keyword.get(opts, atom_key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  rescue
    ArgumentError -> map
  end

  defp maybe_put_kw(map, key, opts, opt_key) do
    case Keyword.get(opts, opt_key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
