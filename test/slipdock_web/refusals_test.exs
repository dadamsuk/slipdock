defmodule SlipdockWeb.RefusalsTest do
  @moduledoc """
  `SlipdockWeb.Refusals.said/3` says a refusal the context answered while a
  LiveView's handler ran, however the handler took it (#3169, #3172): a
  crash on the refusal, or on what the handler made of it, is caught; a
  crash with no refusal behind it is the handler's own and is raised.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Policy
  alias Slipdock.Policy.Refused
  alias SlipdockWeb.Refusals

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  defp refuse do
    refused = %Refused{action: :own_group, by: :nobody, message: "Refused here."}
    Process.put({Policy, :refusal}, refused)
    {:error, refused}
  end

  defp say(socket, message), do: Phoenix.Component.assign(socket, said: message)

  test "a refusal the handler ignored is said" do
    assert {:noreply, %{assigns: %{said: "Refused here."}}} =
             Refusals.said(socket(), fn -> refuse() && {:noreply, socket()} end, &say/2)
  end

  test "a crash matching {:ok, _} on a refusal is said, not raised" do
    handler = fn ->
      {:ok, _} = refuse()
      {:noreply, socket()}
    end

    assert {:noreply, %{assigns: %{said: "Refused here."}}} =
             Refusals.said(socket(), handler, &say/2)
  end

  test "a crash on what the handler made of a refusal is said, not raised" do
    handler = fn ->
      # An error that doesn't carry the refusal: the handler read its words
      # as a number.
      {:error, refused} = refuse()
      _ = String.to_integer(refused.message)
      {:noreply, socket()}
    end

    assert {:noreply, %{assigns: %{said: "Refused here."}}} =
             Refusals.said(socket(), handler, &say/2)
  end

  test "a crash with no refusal behind it is the handler's own" do
    assert_raise KeyError, fn ->
      Refusals.said(socket(), fn -> Map.fetch!(%{}, :errors) end, &say/2)
    end
  end

  test "a refusal from an earlier event isn't said again" do
    refuse()

    assert {:noreply, socket} = Refusals.said(socket(), fn -> {:noreply, socket()} end, &say/2)
    refute Map.has_key?(socket.assigns, :said)
  end
end
