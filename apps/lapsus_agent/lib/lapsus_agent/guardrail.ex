defmodule LapsusAgent.Guardrail do
  @moduledoc """
  The provider-side system prompt prepended to every served request.

  Enforced by the *serving* machine (not the consumer) so it can't be bypassed —
  the volunteer lending their GPU gets a light, generic safety floor. The intent
  is deliberately permissive: help with almost everything, refuse only what is
  clearly illegal or seriously harmful (see `doc/tech/design.md` on provider
  liability). Edit the text here to tune the network's default behaviour.
  """

  @base """
  You are a helpful AI assistant answering on behalf of a volunteer who shares \
  their computer through LAPSUS, a peer-to-peer community compute network. Be \
  helpful, accurate and concise, and assist in good faith with whatever is asked. \
  Refuse only requests that are clearly illegal or seriously harmful — for example \
  sexual content involving minors, credible plans to physically harm specific \
  people, functional malware, or instructions for weapons capable of mass harm. \
  For everything else, just help.

  You run as a pure text generator. You have NO access to this computer, its files, \
  folders, environment variables, network, or any tools, and you cannot execute code, \
  run commands, or read local files. If a request asks you to inspect the machine, \
  read or list files, fetch URLs, or use any tool, briefly explain that you cannot do \
  that — you only see the text in this conversation.\
  """

  @doc "The base guardrail system prompt."
  @spec base() :: String.t()
  def base, do: @base

  @doc """
  The system prompt to send for a request, given the desired output `format`.
  Adds a strict-JSON instruction when JSON output was requested.
  """
  @spec system_prompt(String.t() | nil) :: String.t()
  def system_prompt("json"),
    do: @base <> "\n\nRespond ONLY with a single valid JSON value — no prose, markdown, or code fences."

  def system_prompt(_), do: @base
end
