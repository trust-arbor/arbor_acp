defmodule Arbor.ACP.RequestValidationTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.RequestValidation

  @session_id "session-1"

  test "accepts each ACP v1 session update discriminator with its required shape" do
    updates = [
      %{
        "sessionUpdate" => "user_message_chunk",
        "messageId" => nil,
        "content" => %{"type" => "text", "text" => "hello", "annotations" => %{}}
      },
      %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "image", "data" => "AA==", "mimeType" => "image/png"}
      },
      %{
        "sessionUpdate" => "agent_thought_chunk",
        "content" => %{"type" => "text", "text" => "thinking"}
      },
      %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "tool-1",
        "title" => "Read file",
        "kind" => "read",
        "status" => "in_progress",
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "started"}}
        ]
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "tool-1",
        "status" => "completed",
        "locations" => [%{"path" => "/tmp/file", "line" => 1}]
      },
      %{
        "sessionUpdate" => "plan",
        "entries" => [%{"content" => "Audit", "priority" => "high", "status" => "pending"}]
      },
      %{
        "sessionUpdate" => "plan_update",
        "plan" => %{"type" => "markdown", "planId" => "plan-1", "content" => "# Plan"}
      },
      %{"sessionUpdate" => "plan_removed", "planId" => "plan-1"},
      %{
        "sessionUpdate" => "available_commands_update",
        "availableCommands" => [
          %{"name" => "audit", "description" => "Audit code", "input" => %{"hint" => "path"}}
        ]
      },
      %{
        "sessionUpdate" => "current_mode_update",
        "currentModeId" => "auto"
      },
      %{
        "sessionUpdate" => "config_option_update",
        "configOptions" => [
          %{
            "id" => "mode",
            "name" => "Mode",
            "type" => "select",
            "currentValue" => "safe",
            "options" => [%{"value" => "safe", "name" => "Safe"}]
          },
          %{
            "id" => "verbose",
            "name" => "Verbose",
            "type" => "boolean",
            "currentValue" => false
          }
        ]
      },
      %{"sessionUpdate" => "session_info_update", "title" => nil},
      %{
        "sessionUpdate" => "usage_update",
        "used" => 10,
        "size" => 100,
        "cost" => %{"amount" => 0.01, "currency" => "USD"}
      }
    ]

    for update <- updates do
      assert :ok =
               RequestValidation.validate_session_update(%{
                 "sessionId" => @session_id,
                 "update" => update
               })
    end
  end

  test "rejects unknown discriminators and malformed variant fields" do
    invalid_updates = [
      %{"sessionUpdate" => "unknown"},
      %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text"}},
      %{"sessionUpdate" => "tool_call", "toolCallId" => "tool-1"},
      %{"sessionUpdate" => "tool_call_update", "toolCallId" => "", "status" => "done"},
      %{"sessionUpdate" => "plan", "entries" => [%{"content" => "missing fields"}]},
      %{"sessionUpdate" => "usage_update", "used" => -1, "size" => 100},
      %{"sessionUpdate" => "session_info_update", "_meta" => "not-an-object"}
    ]

    for update <- invalid_updates do
      assert {:error, :invalid_params} =
               RequestValidation.validate_session_update(%{
                 "sessionId" => @session_id,
                 "update" => update
               })
    end

    assert {:error, :invalid_params} = RequestValidation.validate_session_update(%{})
  end

  describe "opt-in notice and compaction updates (ACP SDK 1.9.0 v1 schema)" do
    test "accept every schema-valid shape, including open severity and status strings" do
      text = %{"type" => "text", "text" => "Kept the failing test names"}

      updates = [
        %{"sessionUpdate" => "notice", "severity" => "info", "title" => "Indexed"},
        %{
          "sessionUpdate" => "notice",
          "severity" => "warning",
          "title" => "Rate limited",
          "description" => "Retrying in 5 seconds",
          "_meta" => %{"vendor" => true}
        },
        %{
          "sessionUpdate" => "notice",
          "severity" => "error",
          "title" => "Quota",
          "description" => nil,
          "_meta" => nil
        },
        %{"sessionUpdate" => "notice", "severity" => "_vendor.debug", "title" => "Custom"},
        %{"sessionUpdate" => "notice", "severity" => "", "title" => "Future severity"},
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "compact-1",
          "status" => "in_progress"
        },
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "compact-1",
          "status" => "completed",
          "summary" => [
            text,
            %{"type" => "resource_link", "name" => "notes", "uri" => "file:///n"}
          ],
          "error" => nil,
          "_meta" => %{"tokensBefore" => 1200}
        },
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "compact-1",
          "status" => "failed",
          "summary" => nil,
          "error" => "Model unavailable",
          "_meta" => nil
        },
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "compact-2",
          "status" => "cancelled",
          "summary" => []
        },
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "",
          "status" => "_vendor.paused"
        },
        %{
          "sessionUpdate" => "compaction_summary_chunk",
          "compactionId" => "compact-1",
          "content" => text
        },
        %{
          "sessionUpdate" => "compaction_summary_chunk",
          "compactionId" => "compact-1",
          "content" => %{"type" => "image", "data" => "AA==", "mimeType" => "image/png"},
          "_meta" => nil
        }
      ]

      for update <- updates do
        assert :ok =
                 RequestValidation.validate_session_update(%{
                   "sessionId" => @session_id,
                   "update" => update
                 }),
               "expected #{inspect(update)} to be valid"
      end
    end

    test "reject missing, mistyped or malformed fields" do
      text = %{"type" => "text", "text" => "summary"}

      invalid_updates = [
        %{"sessionUpdate" => "notice", "title" => "No severity"},
        %{"sessionUpdate" => "notice", "severity" => nil, "title" => "Null severity"},
        %{"sessionUpdate" => "notice", "severity" => :info, "title" => "Atom severity"},
        %{"sessionUpdate" => "notice", "severity" => 1, "title" => "Numeric severity"},
        %{"sessionUpdate" => "notice", "severity" => "info"},
        %{"sessionUpdate" => "notice", "severity" => "info", "title" => ""},
        %{"sessionUpdate" => "notice", "severity" => "info", "title" => nil},
        %{"sessionUpdate" => "notice", "severity" => "info", "title" => ["Title"]},
        %{"sessionUpdate" => "notice", "severity" => "info", "title" => "T", "description" => 1},
        %{"sessionUpdate" => "notice", "severity" => "info", "title" => "T", "_meta" => []},
        %{"sessionUpdate" => "compaction_update", "status" => "completed"},
        %{"sessionUpdate" => "compaction_update", "compactionId" => "c-1"},
        %{"sessionUpdate" => "compaction_update", "compactionId" => 1, "status" => "completed"},
        %{"sessionUpdate" => "compaction_update", "compactionId" => nil, "status" => "completed"},
        %{"sessionUpdate" => "compaction_update", "compactionId" => "c-1", "status" => nil},
        %{"sessionUpdate" => "compaction_update", "compactionId" => "c-1", "status" => 2},
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "c-1",
          "status" => "completed",
          "summary" => text
        },
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "c-1",
          "status" => "completed",
          "summary" => [text, %{"type" => "text"}]
        },
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "c-1",
          "status" => "failed",
          "error" => %{"message" => "structured"}
        },
        %{
          "sessionUpdate" => "compaction_update",
          "compactionId" => "c-1",
          "status" => "completed",
          "_meta" => "not-an-object"
        },
        %{"sessionUpdate" => "compaction_summary_chunk", "content" => text},
        %{"sessionUpdate" => "compaction_summary_chunk", "compactionId" => "c-1"},
        %{
          "sessionUpdate" => "compaction_summary_chunk",
          "compactionId" => "c-1",
          "content" => nil
        },
        %{
          "sessionUpdate" => "compaction_summary_chunk",
          "compactionId" => "c-1",
          "content" => [text]
        },
        %{
          "sessionUpdate" => "compaction_summary_chunk",
          "compactionId" => "c-1",
          "content" => %{"type" => "text"}
        },
        %{"sessionUpdate" => "compaction_summary_chunk", "compactionId" => 7, "content" => text},
        %{
          "sessionUpdate" => "compaction_summary_chunk",
          "compactionId" => "c-1",
          "content" => text,
          "_meta" => 1
        }
      ]

      for update <- invalid_updates do
        assert {:error, :invalid_params} =
                 RequestValidation.validate_session_update(%{
                   "sessionId" => @session_id,
                   "update" => update
                 }),
               "expected #{inspect(update)} to be rejected"
      end
    end
  end

  test "validates form and URL elicitation scopes and responses" do
    form = %{
      "mode" => "form",
      "sessionId" => @session_id,
      "toolCallId" => "tool-1",
      "message" => "Choose a color",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{
          "color" => %{
            "type" => "string",
            "oneOf" => [%{"const" => "blue", "title" => "Blue"}]
          }
        }
      }
    }

    assert :ok = RequestValidation.validate_agent_request("elicitation/create", form)

    url = %{
      "mode" => "url",
      "requestId" => 9,
      "message" => "Authorize",
      "url" => "https://example.com/oauth",
      "elicitationId" => "oauth-1"
    }

    assert :ok = RequestValidation.validate_agent_request("elicitation/create", url)

    assert {:error, :invalid_params} =
             RequestValidation.validate_agent_request(
               "elicitation/create",
               Map.put(url, "url", "https://user:password@example.com/oauth")
             )

    assert {:error, :invalid_params} =
             RequestValidation.validate_agent_request(
               "elicitation/create",
               Map.put(form, "requestId", 9)
             )

    password_form =
      put_in(form, ["requestedSchema", "properties", "color"], %{
        "type" => "string",
        "format" => "password"
      })

    assert {:error, :invalid_params} =
             RequestValidation.validate_agent_request("elicitation/create", password_form)

    codex_secret_form =
      put_in(form, ["requestedSchema", "properties", "color"], %{
        "type" => "string",
        "_meta" => %{"codex" => %{"isSecret" => true}}
      })

    assert {:error, :invalid_params} =
             RequestValidation.validate_agent_request("elicitation/create", codex_secret_form)

    assert :ok =
             RequestValidation.validate_elicitation_response(%{
               "action" => "accept",
               "content" => %{"color" => "blue"}
             })

    assert {:error, :invalid_params} =
             RequestValidation.validate_elicitation_response(%{
               "action" => "accept",
               "content" => "not an object"
             })
  end
end
