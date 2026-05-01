defmodule SymphonyElixir.CodingAgent do
  @moduledoc """
  Agent adapter boundary for coding and review turns.

  Codex app-server is the first adapter, but Symphony's orchestration contracts
  are phrased around executor/reviewer roles so future local agents can share
  the same handoff, evidence, and session lifecycle surfaces.
  """

  @type role :: :planner | :executor | :reviewer
  @type session :: map()
  @type result :: {:ok, map()} | {:error, term()}
  @type session_result :: {:ok, session()} | {:error, term()}
  @type stop_result :: :ok | {:error, term()}

  @spec default_adapter() :: module()
  def default_adapter, do: SymphonyElixir.CodingAgent.CodexAdapter

  @spec adapter_for(String.t() | atom()) :: {:ok, module()} | {:error, term()}
  def adapter_for(provider) when provider in ["codex", :codex], do: {:ok, SymphonyElixir.CodingAgent.CodexAdapter}

  def adapter_for(provider) when provider in ["claude_code", :claude_code],
    do: {:ok, SymphonyElixir.CodingAgent.ClaudeCodeAdapter}

  def adapter_for(provider), do: {:error, {:unsupported_agent_provider, provider}}

  @spec run(role(), Path.t(), String.t(), map()) :: result()
  def run(role, workspace, prompt, issue), do: run(role, workspace, prompt, issue, [])

  @spec run(role() | term(), Path.t(), String.t(), map(), keyword()) :: result()
  def run(role, workspace, prompt, issue, opts) when role in [:planner, :executor, :reviewer] do
    with {:ok, adapter, opts} <- resolve_adapter(opts, issue, role) do
      adapter.run(role, workspace, prompt, issue, opts)
    end
  end

  def run(role, _workspace, _prompt, _issue, _opts), do: {:error, {:unsupported_agent_role, role}}

  @spec start_session(role(), Path.t()) :: session_result()
  def start_session(role, workspace), do: start_session(role, workspace, [])

  @spec start_session(role() | term(), Path.t(), keyword()) :: session_result()
  def start_session(role, workspace, opts) when role in [:planner, :executor, :reviewer] do
    with {:ok, adapter, opts} <- resolve_adapter(opts, nil, role),
         {:ok, session} <- adapter.start_session(role, workspace, opts) do
      {:ok,
       session
       |> Map.put_new(:agent_provider, Keyword.get(opts, :agent_provider, "codex"))
       |> Map.put_new(:agent_profile, Keyword.get(opts, :agent_profile))}
    end
  end

  def start_session(role, _workspace, _opts), do: {:error, {:unsupported_agent_role, role}}

  @spec run_turn(role(), session(), String.t(), map()) :: result()
  def run_turn(role, session, prompt, issue), do: run_turn(role, session, prompt, issue, [])

  @spec run_turn(role() | term(), session(), String.t(), map(), keyword()) :: result()
  def run_turn(role, session, prompt, issue, opts) when role in [:planner, :executor, :reviewer] do
    with {:ok, adapter, opts} <- resolve_adapter(opts, session, issue, role) do
      adapter.run_turn(role, session, prompt, issue, opts)
    end
  end

  def run_turn(role, _session, _prompt, _issue, _opts), do: {:error, {:unsupported_agent_role, role}}

  @spec stop_session(role(), session()) :: stop_result()
  def stop_session(role, session), do: stop_session(role, session, [])

  @spec stop_session(role() | term(), session(), keyword()) :: stop_result()
  def stop_session(role, session, opts) when role in [:planner, :executor, :reviewer] do
    with {:ok, adapter, opts} <- resolve_session_adapter(opts, session, role) do
      adapter.stop_session(role, session, opts)
    end
  end

  def stop_session(role, _session, _opts), do: {:error, {:unsupported_agent_role, role}}

  defp resolve_adapter(opts, issue, phase) do
    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} ->
        {_provider, opts} = opts |> Keyword.delete(:adapter) |> resolve_provider_opts(issue, phase)
        {:ok, adapter, opts}

      :error ->
        {provider, opts} = resolve_provider_opts(opts, issue, phase)

        with {:ok, adapter} <- adapter_for(provider) do
          {:ok, adapter, Keyword.put(opts, :agent_provider, provider)}
        end
    end
  end

  defp resolve_adapter(opts, session, issue, phase) do
    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} ->
        {_provider, opts} = opts |> Keyword.delete(:adapter) |> resolve_provider_opts(issue, phase, session)
        {:ok, adapter, opts}

      :error ->
        {provider, opts} = resolve_provider_opts(opts, issue, phase, session)

        with {:ok, adapter} <- adapter_for(provider) do
          {:ok, adapter, Keyword.put(opts, :agent_provider, provider)}
        end
    end
  end

  defp resolve_session_adapter(opts, session, phase) do
    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} ->
        {_provider, opts} = opts |> Keyword.delete(:adapter) |> resolve_provider_opts(nil, phase, session)
        {:ok, adapter, opts}

      :error ->
        {provider, opts} = resolve_provider_opts(opts, nil, phase, session)

        with {:ok, adapter} <- adapter_for(provider) do
          {:ok, adapter, Keyword.put(opts, :agent_provider, provider)}
        end
    end
  end

  defp resolve_provider_opts(opts, issue, phase, session \\ %{}) do
    profile =
      Keyword.get(opts, :agent_profile) ||
        Map.get(session, :agent_profile) ||
        SymphonyElixir.Config.agent_profile_for_issue(issue, phase)

    provider =
      Keyword.get(opts, :agent_provider) ||
        Map.get(session, :agent_provider) ||
        Map.get(profile || %{}, :provider) ||
        SymphonyElixir.Config.agent_provider_for_issue(issue)

    {provider, Keyword.put(opts, :agent_profile, profile)}
  end
end
