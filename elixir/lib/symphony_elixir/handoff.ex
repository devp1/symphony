defmodule SymphonyElixir.Handoff do
  @moduledoc """
  Reads the local machine-readable worker handoff contract.

  Workers write `.symphony/handoff.json` when an issue has reached a
  controller-actionable final state. Symphony still verifies and applies the
  tracker transition itself; this file is a signal, not a substitute for live
  GitHub state.
  """

  @handoff_path ".symphony/handoff.json"
  @valid_states %{
    "human-review" => "Human Review",
    "human_review" => "Human Review",
    "human review" => "Human Review",
    "needs-input" => "Needs Input",
    "needs_input" => "Needs Input",
    "needs input" => "Needs Input",
    "blocked" => "Blocked",
    "done" => "Done"
  }

  @type t :: %{
          required(:state) => String.t(),
          required(:tracker_state) => String.t(),
          optional(:reason) => String.t(),
          optional(:pr_url) => String.t(),
          optional(:summary) => String.t(),
          optional(:validation) => term(),
          optional(:evidence) => map(),
          optional(:raw) => map()
        }

  @spec path(Path.t()) :: Path.t()
  def path(workspace) when is_binary(workspace), do: Path.join(workspace, @handoff_path)

  @spec read(Path.t()) :: {:ok, t()} | :missing | {:error, term()}
  def read(workspace) when is_binary(workspace) do
    handoff_path = path(workspace)

    with true <- File.regular?(handoff_path),
         {:ok, body} <- File.read(handoff_path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, handoff} <- normalize(decoded) do
      {:ok, handoff}
    else
      false -> :missing
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_handoff, other}}
    end
  rescue
    error -> {:error, {:handoff_read_failed, Exception.message(error)}}
  end

  @spec fingerprint(t()) :: term()
  def fingerprint(%{raw: raw}), do: {:handoff, :erlang.phash2(raw)}
  def fingerprint(handoff) when is_map(handoff), do: {:handoff, :erlang.phash2(handoff)}

  @spec tracker_state(t()) :: String.t()
  def tracker_state(%{tracker_state: tracker_state}), do: tracker_state

  @spec storage_payload(t()) :: map()
  def storage_payload(handoff) when is_map(handoff) do
    handoff
    |> Map.take([:state, :tracker_state, :reason, :pr_url, :summary, :validation, :evidence])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize(%{} = raw) do
    with true <- ready?(raw),
         {:ok, state, tracker_state} <- normalize_state(raw) do
      {:ok,
       %{
         state: state,
         tracker_state: tracker_state,
         reason: optional_string(raw, "reason"),
         pr_url: optional_string(raw, "pr_url") || optional_string(raw, "prUrl"),
         summary: optional_string(raw, "summary"),
         validation: Map.get(raw, "validation") || Map.get(raw, :validation),
         evidence: normalize_evidence(raw),
         raw: raw
       }}
    else
      false -> {:error, :handoff_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(_raw), do: {:error, :handoff_not_object}

  defp ready?(raw) do
    Map.get(raw, "ready") == true or Map.get(raw, :ready) == true
  end

  defp normalize_state(raw) do
    raw
    |> state_value()
    |> case do
      nil ->
        {:error, :missing_handoff_state}

      state ->
        normalized = normalize_state_name(state)

        case Map.fetch(@valid_states, normalized) do
          {:ok, tracker_state} -> {:ok, normalized, tracker_state}
          :error -> {:error, {:unsupported_handoff_state, state}}
        end
    end
  end

  defp state_value(raw) do
    Map.get(raw, "state") ||
      Map.get(raw, :state) ||
      Map.get(raw, "target_state") ||
      Map.get(raw, :target_state) ||
      Map.get(raw, "targetState")
  end

  defp normalize_state_name(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_state_name(state), do: state |> to_string() |> normalize_state_name()

  defp optional_string(raw, key) when is_binary(key) do
    case Map.get(raw, key) || Map.get(raw, String.to_atom(key)) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp normalize_evidence(raw) when is_map(raw) do
    nested =
      case Map.get(raw, "evidence") || Map.get(raw, :evidence) do
        %{} = evidence -> evidence
        _ -> %{}
      end

    top_level =
      %{}
      |> maybe_put_boolean(:required, Map.get(raw, "evidence_required") || Map.get(raw, :evidence_required))
      |> maybe_put_string(:bundle_path, optional_string(raw, "evidence_bundle_path"))
      |> maybe_put_string(:manifest_path, optional_string(raw, "evidence_manifest_path"))

    evidence = Map.merge(nested, top_level)

    if map_size(evidence) == 0 do
      nil
    else
      normalize_evidence_keys(evidence)
    end
  end

  defp normalize_evidence_keys(evidence) when is_map(evidence) do
    %{}
    |> maybe_put_boolean(:required, evidence_value(evidence, "required"))
    |> maybe_put_string(:bundle_path, evidence_string(evidence, "bundle_path") || evidence_string(evidence, "bundlePath"))
    |> maybe_put_string(:manifest_path, evidence_string(evidence, "manifest_path") || evidence_string(evidence, "manifestPath"))
    |> maybe_put_string(:reason, evidence_string(evidence, "reason"))
    |> maybe_put_string(:summary, evidence_string(evidence, "summary"))
    |> maybe_put_string(:kind, evidence_string(evidence, "kind"))
    |> Map.put(:raw, evidence)
  end

  defp evidence_value(evidence, key) when is_map(evidence) and is_binary(key) do
    Map.get(evidence, key) || Map.get(evidence, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(evidence, key)
  end

  defp evidence_string(evidence, key) do
    case evidence_value(evidence, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp maybe_put_boolean(map, _key, nil), do: map
  defp maybe_put_boolean(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_boolean(map, _key, _value), do: map

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put_string(map, _key, _value), do: map
end
