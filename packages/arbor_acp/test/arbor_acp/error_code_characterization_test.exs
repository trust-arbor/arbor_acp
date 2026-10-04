defmodule Arbor.ACP.ErrorCodeCharacterizationTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Types

  test "ACP error constants preserve their published wire values" do
    assert %{
             auth_required: Types.auth_required_code(),
             resource_not_found: Types.resource_not_found_code(),
             request_cancelled: Types.request_cancelled_code()
           } == %{auth_required: -32000, resource_not_found: -32002, request_cancelled: -32800}
  end
end
