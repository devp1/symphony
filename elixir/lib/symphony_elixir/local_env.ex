defmodule SymphonyElixir.LocalEnv do
  @moduledoc """
  Loads trusted local operator environment files for Symphony.

  This is intentionally narrow: it only imports the GitHub App variables that
  Symphony owns, and it never overrides values already present in the process
  environment.
  """

  @github_app_env_keys ~w[
    SYMPHONY_GITHUB_BUILDER_APP_ID
    SYMPHONY_GITHUB_BUILDER_INSTALLATION_ID
    SYMPHONY_GITHUB_BUILDER_PRIVATE_KEY_PATH
    SYMPHONY_GITHUB_BUILDER_PRIVATE_KEY
    SYMPHONY_GITHUB_REVIEWER_APP_ID
    SYMPHONY_GITHUB_REVIEWER_INSTALLATION_ID
    SYMPHONY_GITHUB_REVIEWER_PRIVATE_KEY_PATH
    SYMPHONY_GITHUB_REVIEWER_PRIVATE_KEY
  ]

  @spec load_default_github_app_env() :: :ok
  def load_default_github_app_env do
    if default_github_app_env_enabled?() do
      load_github_app_env(default_github_app_env_path())
    else
      :ok
    end
  end

  @spec load_github_app_env(Path.t()) :: :ok
  def load_github_app_env(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.each(&load_env_line/1)

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp load_env_line(line) do
    with {:ok, key, value} <- parse_env_line(line),
         true <- key in @github_app_env_keys,
         true <- blank?(System.get_env(key)) do
      System.put_env(key, value)
    else
      _ -> :ok
    end
  end

  defp parse_env_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    case Regex.run(~r/\A(?:export\s+)?([A-Z0-9_]+)=(.*)\z/, trimmed) do
      [_match, key, value] -> {:ok, key, unquote_env_value(value)}
      _ -> :error
    end
  end

  defp unquote_env_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end

  defp default_github_app_env_path do
    Application.get_env(:symphony_elixir, :github_app_env_path) ||
      Path.join([System.user_home!(), ".config", "symphony", "github-apps", "env"])
  end

  defp default_github_app_env_enabled? do
    Application.get_env(
      :symphony_elixir,
      :load_default_github_app_env,
      mix_env() != :test
    )
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    else
      :prod
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
end
