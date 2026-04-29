defmodule SymphonyElixir.GitHub.AppAuth do
  @moduledoc false

  @cache_table :symphony_github_app_tokens
  @expiry_leeway_seconds 60

  @type app_config :: %{
          optional(:app_id) => String.t(),
          optional(:installation_id) => String.t(),
          optional(:private_key) => String.t(),
          optional(:private_key_path) => String.t()
        }
  @type command_fun :: (list(String.t()), [{String.t(), String.t()}] -> {String.t(), non_neg_integer()})

  @spec installation_token(app_config(), command_fun()) :: {:ok, String.t()} | {:error, term()}
  def installation_token(%{} = app_config, command_fun) when is_function(command_fun) do
    with {:ok, normalized} <- normalize_app_config(app_config),
         {:ok, token} <- cached_token(normalized) do
      {:ok, token}
    else
      :missing ->
        mint_and_cache_token(app_config, command_fun)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec clear_cache_for_test() :: :ok
  def clear_cache_for_test do
    case :ets.whereis(@cache_table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp mint_and_cache_token(app_config, command_fun) do
    with {:ok, normalized} <- normalize_app_config(app_config),
         {:ok, jwt} <- app_jwt(normalized),
         {:ok, token, expires_at} <- request_installation_token(normalized, jwt, command_fun) do
      cache_token(normalized, token, expires_at)
      {:ok, token}
    end
  end

  defp normalize_app_config(app_config) do
    app_id = app_field(app_config, :app_id)
    installation_id = app_field(app_config, :installation_id)
    private_key = app_field(app_config, :private_key)
    private_key_path = app_field(app_config, :private_key_path)

    cond do
      blank?(app_id) ->
        {:error, :github_app_id_missing}

      blank?(installation_id) ->
        {:error, :github_app_installation_id_missing}

      blank?(private_key) and blank?(private_key_path) ->
        {:error, :github_app_private_key_missing}

      true ->
        {:ok,
         %{
           app_id: String.trim(app_id),
           installation_id: String.trim(installation_id),
           private_key: normalize_optional(private_key),
           private_key_path: normalize_optional(private_key_path)
         }}
    end
  end

  defp app_field(app_config, key), do: Map.get(app_config, key) || Map.get(app_config, Atom.to_string(key))

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp normalize_optional(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional(_value), do: nil

  defp cached_token(normalized) do
    table = ensure_cache_table()
    now = System.system_time(:second)

    case :ets.lookup(table, cache_key(normalized)) do
      [{_key, token, expires_at}] when expires_at - now > @expiry_leeway_seconds -> {:ok, token}
      _other -> :missing
    end
  end

  defp cache_token(normalized, token, expires_at) do
    :ets.insert(ensure_cache_table(), {cache_key(normalized), token, expires_at})
  end

  defp cache_key(%{app_id: app_id, installation_id: installation_id, private_key: private_key, private_key_path: private_key_path}) do
    {app_id, installation_id, :erlang.phash2({private_key, private_key_path})}
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])

      table ->
        table
    end
  rescue
    ArgumentError -> @cache_table
  end

  defp app_jwt(%{app_id: app_id} = normalized) do
    with {:ok, private_key} <- read_private_key(normalized) do
      now = System.system_time(:second)
      header = base64url_json!(%{alg: "RS256", typ: "JWT"})
      payload = base64url_json!(%{iat: now - 60, exp: now + 9 * 60, iss: app_id})
      signing_input = "#{header}.#{payload}"
      signature = :public_key.sign(signing_input, :sha256, private_key)

      {:ok, "#{signing_input}.#{Base.url_encode64(signature, padding: false)}"}
    end
  end

  defp read_private_key(%{private_key: private_key}) when is_binary(private_key) do
    decode_private_key(private_key)
  end

  defp read_private_key(%{private_key_path: private_key_path}) when is_binary(private_key_path) do
    private_key_path
    |> Path.expand()
    |> File.read()
    |> case do
      {:ok, pem} -> decode_private_key(pem)
      {:error, reason} -> {:error, {:github_app_private_key_read_failed, reason}}
    end
  end

  defp read_private_key(_normalized), do: {:error, :github_app_private_key_missing}

  defp decode_private_key(pem) when is_binary(pem) do
    pem = normalize_pem(pem)

    case :public_key.pem_decode(pem) do
      [entry | _rest] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :github_app_private_key_invalid}
    end
  rescue
    error -> {:error, {:github_app_private_key_invalid, Exception.message(error)}}
  end

  defp normalize_pem(pem) do
    if String.contains?(pem, "\\n") and not String.contains?(pem, "\n") do
      String.replace(pem, "\\n", "\n")
    else
      pem
    end
  end

  defp base64url_json!(payload) do
    payload
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp request_installation_token(%{installation_id: installation_id}, jwt, command_fun) do
    args = [
      "api",
      "app/installations/#{installation_id}/access_tokens",
      "-X",
      "POST",
      "-H",
      "Accept: application/vnd.github+json",
      "-H",
      "X-GitHub-Api-Version: 2022-11-28"
    ]

    env = [{"GH_TOKEN", jwt}, {"GITHUB_TOKEN", jwt}]

    case run_command(command_fun, args, env) do
      {output, 0} ->
        parse_installation_token(output)

      {output, status} ->
        {:error, {:github_app_token_request_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:github_app_token_request_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:github_app_token_request_failed, {kind, reason}}}
  end

  defp run_command(command_fun, args, env) when is_function(command_fun, 2), do: command_fun.(args, env)
  defp run_command(command_fun, args, _env) when is_function(command_fun, 1), do: command_fun.(args)

  defp parse_installation_token(output) do
    with {:ok, %{"token" => token, "expires_at" => expires_at}} when is_binary(token) <- Jason.decode(output),
         {:ok, expires_at} <- parse_expires_at(expires_at) do
      {:ok, token, expires_at}
    else
      _other -> {:error, :github_app_token_response_invalid}
    end
  end

  defp parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime)}
      {:error, _reason} -> {:error, :github_app_token_expiry_invalid}
    end
  end

  defp parse_expires_at(_value), do: {:error, :github_app_token_expiry_invalid}
end
