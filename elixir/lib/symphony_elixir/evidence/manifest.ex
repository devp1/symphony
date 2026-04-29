defmodule SymphonyElixir.Evidence.Manifest do
  @moduledoc """
  Validates and normalizes Symphony evidence bundle manifests.

  The contract is intentionally proof-oriented but not tool-specific: executor
  agents can attach Playwright traces, videos, screenshots, command logs,
  validation summaries, or future artifact kinds without Symphony needing to
  understand the tool that produced them.
  """

  alias SymphonyElixir.PathSafety

  @schema_version "symphony.evidence.v1"

  @type t :: map()

  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @spec validate(map(), Path.t(), Path.t()) :: {:ok, t()} | {:error, term()}
  def validate(manifest, workspace_root, bundle_path) when is_map(manifest) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_root),
         {:ok, canonical_bundle} <- PathSafety.canonicalize(bundle_path) do
      {schema_version, schema_errors} = normalize_schema_version(manifest)
      {summary, summary_errors} = normalize_summary(manifest)
      {artifacts, artifact_errors} = normalize_artifacts(manifest, canonical_workspace, canonical_bundle)
      {commands, command_errors} = normalize_commands(manifest, canonical_workspace, canonical_bundle)
      {changed_files, changed_file_errors} = normalize_changed_files(manifest)

      errors =
        schema_errors ++
          summary_errors ++
          artifact_errors ++
          command_errors ++
          changed_file_errors ++
          proof_errors(artifacts, commands)

      if errors == [] do
        {:ok,
         manifest
         |> Map.put("schema_version", schema_version)
         |> Map.put("summary", summary)
         |> Map.put("artifacts", artifacts)
         |> Map.put("commands", commands)
         |> Map.put("changed_files", changed_files)}
      else
        {:error, {:invalid_evidence_manifest, errors}}
      end
    end
  end

  def validate(_manifest, _workspace_root, _bundle_path), do: {:error, :manifest_not_object}

  defp normalize_schema_version(manifest) do
    case string_value(manifest, ["schema_version", "schemaVersion", "version"]) do
      nil -> {@schema_version, []}
      "1" -> {@schema_version, []}
      @schema_version -> {@schema_version, []}
      version -> {version, [{:unsupported_schema_version, version}]}
    end
  end

  defp normalize_summary(manifest) do
    case string_value(manifest, ["summary"]) do
      nil -> {nil, [:missing_summary]}
      summary -> {summary, []}
    end
  end

  defp normalize_artifacts(manifest, workspace_root, bundle_path) do
    manifest
    |> list_value(["artifacts"])
    |> Enum.with_index()
    |> Enum.map(fn {artifact, index} -> normalize_artifact(artifact, index, workspace_root, bundle_path) end)
    |> split_results()
  end

  defp normalize_artifact(%{} = artifact, index, workspace_root, bundle_path) do
    kind = string_value(artifact, ["kind", "type"])
    label = string_value(artifact, ["label", "title"])
    description = string_value(artifact, ["description", "summary"])
    path = string_value(artifact, ["path"])
    url = string_value(artifact, ["url", "href"])
    path_context = {:artifact_path, index}

    errors =
      []
      |> maybe_error(is_nil(kind), {:artifact_missing_kind, index})
      |> maybe_error(is_nil(path) and is_nil(url), {:artifact_missing_location, index})
      |> maybe_error(not is_nil(url) and not web_url?(url), {:artifact_invalid_url, index, url})

    with [] <- errors,
         {:ok, normalized_path} <- normalize_optional_path(path, workspace_root, bundle_path, path_context) do
      {:ok,
       %{}
       |> put_string("kind", kind)
       |> put_string("label", label)
       |> put_string("description", description)
       |> put_string("path", path)
       |> put_string("workspace_path", normalized_path)
       |> put_string("url", url)}
    else
      [_ | _] = validation_errors -> {:error, validation_errors}
      {:error, reason} -> {:error, [reason]}
    end
  end

  defp normalize_artifact(_artifact, index, _workspace_root, _bundle_path) do
    {:error, [{:artifact_not_object, index}]}
  end

  defp normalize_commands(manifest, workspace_root, bundle_path) do
    manifest
    |> list_value(["commands"])
    |> Enum.with_index()
    |> Enum.map(fn {command, index} -> normalize_command(command, index, workspace_root, bundle_path) end)
    |> split_results()
  end

  defp normalize_command(%{} = command, index, workspace_root, bundle_path) do
    command_text = string_value(command, ["command", "cmd"])
    status = string_value(command, ["status", "result"])
    summary = string_value(command, ["summary"])
    output_path = string_value(command, ["output_path", "outputPath", "log_path", "logPath"])
    exit_code = integer_value(command, ["exit_code", "exitCode"])
    output_context = {:command_output_path, index}

    errors =
      []
      |> maybe_error(is_nil(command_text), {:command_missing_command, index})
      |> maybe_error(is_nil(status), {:command_missing_status, index})

    with [] <- errors,
         {:ok, normalized_output_path} <-
           normalize_optional_path(output_path, workspace_root, bundle_path, output_context) do
      {:ok,
       %{}
       |> put_string("command", command_text)
       |> put_string("status", status)
       |> put_integer("exit_code", exit_code)
       |> put_string("summary", summary)
       |> put_string("output_path", output_path)
       |> put_string("workspace_output_path", normalized_output_path)}
    else
      [_ | _] = validation_errors -> {:error, validation_errors}
      {:error, reason} -> {:error, [reason]}
    end
  end

  defp normalize_command(_command, index, _workspace_root, _bundle_path) do
    {:error, [{:command_not_object, index}]}
  end

  defp normalize_changed_files(manifest) do
    case raw_value(manifest, "changed_files") || raw_value(manifest, "changedFiles") do
      nil ->
        {[], []}

      files when is_list(files) ->
        {Enum.flat_map(files, &trimmed_string/1), []}

      _value ->
        {[], [:changed_files_not_list]}
    end
  end

  defp proof_errors([], []), do: [:missing_proof_entries]
  defp proof_errors(_artifacts, _commands), do: []

  defp split_results(results) do
    Enum.reduce(results, {[], []}, fn
      {:ok, item}, {items, errors} -> {[item | items], errors}
      {:error, item_errors}, {items, errors} -> {items, errors ++ List.wrap(item_errors)}
    end)
    |> then(fn {items, errors} -> {Enum.reverse(items), errors} end)
  end

  defp normalize_optional_path(nil, _workspace_root, _bundle_path, _context), do: {:ok, nil}

  defp normalize_optional_path(path, workspace_root, bundle_path, context) when is_binary(path) do
    expanded_path =
      case Path.type(path) do
        :absolute -> Path.expand(path)
        _ -> Path.expand(path, bundle_path)
      end

    with {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path),
         :ok <- ensure_inside_workspace(canonical_path, workspace_root),
         :ok <- ensure_existing_path(canonical_path) do
      {:ok, Path.relative_to(canonical_path, workspace_root)}
    else
      {:error, reason} -> {:error, {context, reason}}
    end
  end

  defp ensure_inside_workspace(path, workspace_root) do
    workspace_prefix = workspace_root <> "/"

    if path == workspace_root or String.starts_with?(path <> "/", workspace_prefix) do
      :ok
    else
      {:error, {:path_escape, path, workspace_root}}
    end
  end

  defp ensure_existing_path(path) do
    if File.exists?(path), do: :ok, else: {:error, {:path_missing, path}}
  end

  defp list_value(map, keys) do
    case Enum.find_value(keys, &raw_value(map, &1)) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp string_value(map, keys) do
    keys
    |> Enum.find_value(fn key -> raw_value(map, key) |> trimmed_string() |> List.first() end)
  end

  defp integer_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case raw_value(map, key) do
        value when is_integer(value) -> value
        _value -> nil
      end
    end)
  end

  defp raw_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp trimmed_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp trimmed_string(_value), do: []

  defp maybe_error(errors, true, error), do: [error | errors]
  defp maybe_error(errors, false, _error), do: errors

  defp put_string(map, _key, nil), do: map
  defp put_string(map, key, value), do: Map.put(map, key, value)

  defp put_integer(map, _key, nil), do: map
  defp put_integer(map, key, value), do: Map.put(map, key, value)

  defp web_url?(url) when is_binary(url), do: String.starts_with?(url, ["https://", "http://"])
end
