defmodule SymphonyElixir.CodingAgent.Adapter do
  @moduledoc """
  Behaviour for coding-agent adapters.
  """

  @callback run(SymphonyElixir.CodingAgent.role(), Path.t(), String.t(), map(), keyword()) ::
              SymphonyElixir.CodingAgent.result()

  @callback start_session(SymphonyElixir.CodingAgent.role(), Path.t(), keyword()) ::
              SymphonyElixir.CodingAgent.session_result()

  @callback run_turn(
              SymphonyElixir.CodingAgent.role(),
              SymphonyElixir.CodingAgent.session(),
              String.t(),
              map(),
              keyword()
            ) :: SymphonyElixir.CodingAgent.result()

  @callback stop_session(
              SymphonyElixir.CodingAgent.role(),
              SymphonyElixir.CodingAgent.session(),
              keyword()
            ) :: SymphonyElixir.CodingAgent.stop_result()
end
