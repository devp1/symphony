defmodule SymphonyElixir.LocalEnvTest do
  use ExUnit.Case

  alias SymphonyElixir.LocalEnv

  @env_keys ~w[
    SYMPHONY_GITHUB_BUILDER_APP_ID
    SYMPHONY_GITHUB_BUILDER_INSTALLATION_ID
    SYMPHONY_GITHUB_BUILDER_PRIVATE_KEY_PATH
    SYMPHONY_GITHUB_REVIEWER_APP_ID
    SYMPHONY_GITHUB_REVIEWER_INSTALLATION_ID
    SYMPHONY_GITHUB_REVIEWER_PRIVATE_KEY_PATH
  ]

  setup do
    original_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.delete_env(:symphony_elixir, :github_app_env_path)
      Application.delete_env(:symphony_elixir, :load_default_github_app_env)
    end)

    :ok
  end

  test "loads only Symphony GitHub App variables from an env file" do
    path = Path.join(System.tmp_dir!(), "symphony-github-app-env-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, """
    export SYMPHONY_GITHUB_BUILDER_APP_ID=100
    SYMPHONY_GITHUB_BUILDER_INSTALLATION_ID='200'
    SYMPHONY_GITHUB_BUILDER_PRIVATE_KEY_PATH="/tmp/builder.pem"
    SYMPHONY_GITHUB_REVIEWER_APP_ID=101
    SYMPHONY_GITHUB_REVIEWER_INSTALLATION_ID=201
    SYMPHONY_GITHUB_REVIEWER_PRIVATE_KEY_PATH=/tmp/reviewer.pem
    OTHER_SECRET=ignored
    """)

    assert :ok = LocalEnv.load_github_app_env(path)

    assert System.get_env("SYMPHONY_GITHUB_BUILDER_APP_ID") == "100"
    assert System.get_env("SYMPHONY_GITHUB_BUILDER_INSTALLATION_ID") == "200"
    assert System.get_env("SYMPHONY_GITHUB_BUILDER_PRIVATE_KEY_PATH") == "/tmp/builder.pem"
    assert System.get_env("SYMPHONY_GITHUB_REVIEWER_APP_ID") == "101"
    assert System.get_env("SYMPHONY_GITHUB_REVIEWER_INSTALLATION_ID") == "201"
    assert System.get_env("SYMPHONY_GITHUB_REVIEWER_PRIVATE_KEY_PATH") == "/tmp/reviewer.pem"
    assert System.get_env("OTHER_SECRET") == nil
  end

  test "does not override explicit process environment" do
    path = Path.join(System.tmp_dir!(), "symphony-github-app-env-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    System.put_env("SYMPHONY_GITHUB_REVIEWER_APP_ID", "explicit")
    File.write!(path, "SYMPHONY_GITHUB_REVIEWER_APP_ID=from-file\n")

    assert :ok = LocalEnv.load_github_app_env(path)
    assert System.get_env("SYMPHONY_GITHUB_REVIEWER_APP_ID") == "explicit"
  end

  test "loads the configured default env path when enabled" do
    path = Path.join(System.tmp_dir!(), "symphony-github-app-env-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, "SYMPHONY_GITHUB_BUILDER_APP_ID=default-path\n")
    Application.put_env(:symphony_elixir, :github_app_env_path, path)
    Application.put_env(:symphony_elixir, :load_default_github_app_env, true)

    assert :ok = LocalEnv.load_default_github_app_env()
    assert System.get_env("SYMPHONY_GITHUB_BUILDER_APP_ID") == "default-path"
  end

  test "does not load the configured default env path when disabled" do
    path = Path.join(System.tmp_dir!(), "symphony-github-app-env-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, "SYMPHONY_GITHUB_BUILDER_APP_ID=disabled\n")
    Application.put_env(:symphony_elixir, :github_app_env_path, path)
    Application.put_env(:symphony_elixir, :load_default_github_app_env, false)

    assert :ok = LocalEnv.load_default_github_app_env()
    assert System.get_env("SYMPHONY_GITHUB_BUILDER_APP_ID") == nil
  end
end
