defmodule LapsusAgent.UI.ErrorHTML do
  @moduledoc "Minimal error responses for the local UI (e.g. favicon 404)."
  use Phoenix.Component

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
