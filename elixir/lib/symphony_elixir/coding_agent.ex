defmodule SymphonyElixir.CodingAgent do
  @moduledoc """
  Agent adapter boundary for coding and review turns.

  Codex app-server is the first adapter, but Symphony's orchestration contracts
  are phrased around executor/reviewer roles so future local agents can share
  the same handoff, evidence, and session lifecycle surfaces.
  """

  @type role :: :executor | :reviewer
  @type session :: map()
  @type result :: {:ok, map()} | {:error, term()}
  @type session_result :: {:ok, session()} | {:error, term()}
  @type stop_result :: :ok | {:error, term()}

  @spec default_adapter() :: module()
  def default_adapter, do: SymphonyElixir.CodingAgent.CodexAdapter

  @spec run(role(), Path.t(), String.t(), map()) :: result()
  def run(role, workspace, prompt, issue), do: run(role, workspace, prompt, issue, [])

  @spec run(role() | term(), Path.t(), String.t(), map(), keyword()) :: result()
  def run(role, workspace, prompt, issue, opts) when role in [:executor, :reviewer] do
    adapter = Keyword.get(opts, :adapter, default_adapter())
    adapter.run(role, workspace, prompt, issue, Keyword.delete(opts, :adapter))
  end

  def run(role, _workspace, _prompt, _issue, _opts), do: {:error, {:unsupported_agent_role, role}}

  @spec start_session(role(), Path.t()) :: session_result()
  def start_session(role, workspace), do: start_session(role, workspace, [])

  @spec start_session(role() | term(), Path.t(), keyword()) :: session_result()
  def start_session(role, workspace, opts) when role in [:executor, :reviewer] do
    adapter = Keyword.get(opts, :adapter, default_adapter())
    adapter.start_session(role, workspace, Keyword.delete(opts, :adapter))
  end

  def start_session(role, _workspace, _opts), do: {:error, {:unsupported_agent_role, role}}

  @spec run_turn(role(), session(), String.t(), map()) :: result()
  def run_turn(role, session, prompt, issue), do: run_turn(role, session, prompt, issue, [])

  @spec run_turn(role() | term(), session(), String.t(), map(), keyword()) :: result()
  def run_turn(role, session, prompt, issue, opts) when role in [:executor, :reviewer] do
    adapter = Keyword.get(opts, :adapter, default_adapter())
    adapter.run_turn(role, session, prompt, issue, Keyword.delete(opts, :adapter))
  end

  def run_turn(role, _session, _prompt, _issue, _opts), do: {:error, {:unsupported_agent_role, role}}

  @spec stop_session(role(), session()) :: stop_result()
  def stop_session(role, session), do: stop_session(role, session, [])

  @spec stop_session(role() | term(), session(), keyword()) :: stop_result()
  def stop_session(role, session, opts) when role in [:executor, :reviewer] do
    adapter = Keyword.get(opts, :adapter, default_adapter())
    adapter.stop_session(role, session, Keyword.delete(opts, :adapter))
  end

  def stop_session(role, _session, _opts), do: {:error, {:unsupported_agent_role, role}}
end
