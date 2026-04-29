defmodule SymphonyElixir.CodingAgent.CodexAdapter do
  @moduledoc """
  Codex app-server implementation of the coding-agent adapter contract.
  """

  @behaviour SymphonyElixir.CodingAgent.Adapter

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def run(_role, workspace, prompt, issue, opts) do
    AppServer.run(workspace, prompt, issue, opts)
  end

  @impl true
  def start_session(_role, workspace, opts) do
    AppServer.start_session(workspace, opts)
  end

  @impl true
  def run_turn(_role, session, prompt, issue, opts) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(_role, session, _opts) do
    AppServer.stop_session(session)
  end
end
