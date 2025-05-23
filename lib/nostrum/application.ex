defmodule Nostrum.Application do
  @moduledoc false

  use Application

  alias Nostrum.Voice

  require Logger

  # Used for starting nostrum when running as an included application.
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start, [:normal, []]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc false
  def start(_type, _args) do
    check_executables()
    check_otp_version()

    # Obsolete from 1.18.2. See
    # https://github.com/elixir-lang/elixir/commit/70391199a481c7d3ccb2756c99452ee7dc8ad12f
    if System.version() < "1.18.2" do
      Logger.add_translator({Nostrum.StateMachineTranslator, :translate})
    end

    if Application.fetch_env(:nostrum, :token) != :error do
      raise RuntimeError, """
      Using nostrum via old-style application configuration (`:nostrum, :token`).

      Please migrate to using the `Nostrum.Bot` module by including it in
      your supervisor tree, and move the token configuration to your bot's
      application environment.

      See the migration guide in the `Nostrum.Bot` module for more information.
      """
    end

    children = [
      {Registry, keys: :unique, name: Nostrum.Bot.Registry}
    ]

    if Application.get_env(:nostrum, :dev),
      do: Supervisor.start_link(children ++ [DummySupervisor], strategy: :one_for_one),
      else: Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp check_executables do
    ff = Voice.ffmpeg_executable()
    yt = Voice.youtubedl_executable()
    sl = Voice.streamlink_executable()

    ff_path = if ff, do: System.find_executable(ff)
    yt_path = if yt, do: System.find_executable(yt)
    sl_path = if sl, do: System.find_executable(sl)

    check_ffmpeg(ff_path, ff)
    check_ytdl(ff_path, yt, yt_path)
    check_streamlink(ff_path, sl, sl_path)
  end

  defp check_ffmpeg(_ff_path = nil, ff) when is_binary(ff) do
    Logger.warning("""
    #{ff} was not found in your path. By default, Nostrum requires ffmpeg to use voice.
    If you don't intend to use voice with ffmpeg, configure :nostrum, :ffmpeg to nil or false to suppress all voice warnings.
    """)
  end

  defp check_ffmpeg(_ff_path, _ff), do: :noop

  defp check_ytdl(ff_path, yt, _yt_path = nil) when is_binary(ff_path) and is_binary(yt) do
    Logger.warning("""
    #{yt} was not found in your path. Nostrum supports youtube-dl for voice.
    If you don't require youtube-dl support, configure :nostrum, :youtubedl to nil or false to suppress.
    """)
  end

  defp check_ytdl(_ff_path, _yt, _yt_path), do: :noop

  defp check_streamlink(ff_path, sl, _sl_path = nil) when is_binary(ff_path) and is_binary(sl) do
    Logger.warning("""
    #{sl} was not found in your path. Nostrum supports streamlink for voice.
    If you don't require streamlink support, configure :nostrum, :streamlink to nil or false to suppress.
    """)
  end

  defp check_streamlink(_ff_path, _sl, _sl_path), do: :noop

  defp check_otp_version do
    _module_info = :pg.module_info()

    if not function_exported?(:pg, :monitor, 2) do
      Logger.critical("""
      Your Erlang/OTP version needs to be 25.1 or newer to use Nostrum 0.9 and newer.
      Current major version: #{System.otp_release()}
      """)
    end
  end
end
