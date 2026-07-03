defmodule LapsusAgent.UI.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {LapsusAgent.UI.Layouts, :root}
  end

  # Stateless JSON pipeline for the local OpenAI-compatible gateway — no session/CSRF.
  pipeline :api do
    plug :accepts, ["json"]
  end

  # OpenAI-compatible gateway (protocol.md §7). Localhost-only; spends your credits.
  scope "/v1", LapsusAgent.API do
    pipe_through :api
    post "/chat/completions", GatewayController, :chat_completions
    get "/models", GatewayController, :models
  end

  scope "/" do
    pipe_through :browser
    live "/", LapsusAgent.UI.LandingLive
    live "/welcome", LapsusAgent.UI.OnboardingLive
    live "/provider", LapsusAgent.UI.DashboardLive
    live "/ask", LapsusAgent.UI.ConsumeLive
    live "/how", LapsusAgent.UI.HowItWorksLive
    live "/guardrail", LapsusAgent.UI.GuardrailLive
    live "/no-tools", LapsusAgent.UI.NoToolsLive
  end
end
