defmodule Nostrum.Shard.Intents do
  @moduledoc false

  alias Nostrum.Bot

  import Bitwise

  @privileged_intents [
    :guild_members,
    :guild_presences,
    :message_content
  ]

  @spec intent_values :: [{atom, integer()}, ...]
  def intent_values do
    [
      guilds: 1 <<< 0,
      guild_members: 1 <<< 1,
      # Backwards-compatible value for `:guild_moderation`
      guild_bans: 1 <<< 2,
      guild_moderation: 1 <<< 2,
      # Backwards-compatible value for `:guild_expressions`
      guild_emojis: 1 <<< 3,
      guild_expressions: 1 <<< 3,
      guild_integrations: 1 <<< 4,
      guild_webhooks: 1 <<< 5,
      guild_invites: 1 <<< 6,
      guild_voice_states: 1 <<< 7,
      guild_presences: 1 <<< 8,
      guild_messages: 1 <<< 9,
      guild_message_reactions: 1 <<< 10,
      guild_message_typing: 1 <<< 11,
      direct_messages: 1 <<< 12,
      direct_message_reactions: 1 <<< 13,
      direct_message_typing: 1 <<< 14,
      message_content: 1 <<< 15,
      guild_scheduled_events: 1 <<< 16,
      auto_moderation_configuration: 1 <<< 20,
      auto_moderation_execution: 1 <<< 21,
      guild_message_polls: 1 <<< 24,
      direct_message_polls: 1 <<< 25
    ]
  end

  @spec get_enabled_intents(Bot.intents()) :: integer()
  def get_enabled_intents(configured_intents) do
    # If no intents are passed in config, default to non-privileged being enabled.
    enabled_intents = configured_intents || :nonprivileged

    case enabled_intents do
      :all ->
        get_intent_value(Keyword.keys(intent_values()))

      :nonprivileged ->
        get_intent_value(Keyword.keys(intent_values()) -- @privileged_intents)

      intents ->
        get_intent_value(intents)
    end
  end

  @spec get_intent_value([atom()]) :: integer
  def get_intent_value(enabled_intents) do
    Enum.reduce(enabled_intents, 0, fn intent, intents ->
      case intent_values()[intent] do
        nil -> raise "Invalid intent specified: #{intent}"
        value -> intents ||| value
      end
    end)
  end

  @spec has_intent?(Bot.intents(), atom()) :: boolean
  def has_intent?(configured_intents, requested_intent) do
    enabled_integer = get_enabled_intents(configured_intents)
    intent_integer = intent_values()[requested_intent]

    (enabled_integer &&& intent_integer) == intent_integer
  end
end
