defmodule ExACP.MapsTest do
  use ExUnit.Case, async: true

  alias ExACP.Maps

  describe "get/2" do
    test "prefers present string keys even when the value is false" do
      map = %{"loadSession" => false, loadSession: true}

      refute Maps.get(map, "loadSession")
    end

    test "prefers present atom keys even when the value is false" do
      map = %{"loadSession" => true, loadSession: false}

      refute Maps.get(map, :loadSession)
    end

    test "falls back between string and atom keys" do
      assert Maps.get(%{loadSession: true}, "loadSession")
      assert Maps.get(%{"loadSession" => true}, :loadSession)
    end
  end
end
