if Code.ensure_loaded?(:mnesia) do
  defmodule Nostrum.Cache.MemberCache.Mnesia do
    @moduledoc """
    An Mnesia-based cache for guild members.

    Please note that this module is only compiled if Mnesia is available on
    your system. See the Mnesia section of the [State](functionality/state.md)
    documentation for more information.

    To retrieve the table name used by this cache, use `table/0`.
    """
    @moduledoc since: "0.8.0"

    @base_table_name :nostrum_guild_members

    @behaviour Nostrum.Cache.MemberCache

    alias Nostrum.Bot
    alias Nostrum.Cache.MemberCache
    alias Nostrum.Snowflake
    alias Nostrum.Struct.Guild
    alias Nostrum.Struct.Guild.Member
    alias Nostrum.Util
    use Supervisor

    @doc "Start the supervisor."
    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts)
    end

    @impl Supervisor
    @doc "Set up the cache's Mnesia table."
    def init(opts) do
      table_name = :"#{@base_table_name}_#{Keyword.fetch!(opts, :name)}"

      table_options = [
        attributes: [:key, :guild_id, :user_id, :data],
        index: [:guild_id, :user_id],
        record_name: record_name()
      ]

      case :mnesia.create_table(table_name, table_options) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, _tab}} -> :ok
      end

      Supervisor.init([], strategy: :one_for_one)
    end

    @doc "Retrieve the Mnesia table name used for the cache."
    @spec table :: atom()
    def table, do: :"#{@base_table_name}_#{Bot.fetch_bot_name()}"

    defp record_name, do: :nostrum_member

    @doc "Drop the table used for caching."
    @spec teardown() :: {:atomic, :ok} | {:aborted, term()}
    def teardown, do: :mnesia.delete_table(table())

    @doc "Clear any objects in the cache."
    @spec clear() :: :ok
    def clear do
      {:atomic, :ok} = :mnesia.clear_table(table())
      :ok
    end

    # Used by dispatch

    @impl MemberCache
    @doc "Retrieve the member for the given guild and user in the cache."
    @spec get(Guild.id(), Member.user_id()) :: {:ok, Member.t()} | {:error, atom()}
    def get(guild_id, user_id) do
      key = {guild_id, user_id}

      :mnesia.activity(:sync_transaction, fn ->
        case :mnesia.read(table(), key) do
          [{_tag, _key, _guild_id, _user_id, member}] -> {:ok, member}
          [] -> {:error, :member_not_found}
        end
      end)
    end

    @impl MemberCache
    @doc "Stream all members with the given user ID."
    @doc since: "0.10.0"
    def by_user(user_id) do
      ms = [{{:_, :_, :"$1", user_id, :"$2"}, [], [{{:"$1", :"$2"}}]}]

      Stream.resource(
        fn -> :mnesia.select(table(), ms, 100, :read) end,
        fn items ->
          case items do
            {matches, cont} ->
              {matches, :mnesia.select(cont)}

            :"$end_of_table" ->
              {:halt, nil}
          end
        end,
        fn _cont -> :ok end
      )
    end

    @impl MemberCache
    @doc "Stream all members on the given guild."
    @doc since: "0.10.0"
    def by_guild(guild_id) do
      ms = [{{:_, :_, guild_id, :_, :"$1"}, [], [:"$1"]}]

      Stream.resource(
        fn -> :mnesia.select(table(), ms, 100, :read) end,
        fn items ->
          case items do
            {matches, cont} ->
              {matches, :mnesia.select(cont)}

            :"$end_of_table" ->
              {:halt, nil}
          end
        end,
        fn _cont -> :ok end
      )
    end

    @impl MemberCache
    @doc "Add the given member to the given guild in the cache."
    @spec create(Guild.id(), map()) :: Member.t()
    def create(guild_id, payload) do
      member = Member.to_struct(payload)
      record = {record_name(), {guild_id, member.user_id}, guild_id, member.user_id, member}
      writer = fn -> :mnesia.write(table(), record, :write) end
      {:atomic, :ok} = :mnesia.sync_transaction(writer)
      member
    end

    @impl MemberCache
    @doc "Update the given member for the given guild in the cache."
    @spec update(Guild.id(), map()) :: {Guild.id(), Member.t() | nil, Member.t()}
    def update(guild_id, payload) do
      # Force keys to be atoms before casting just to simplify finding the user_id
      # because of the atom/string ambiguity issues from the gateway that Discord
      # won't fix.

      member_payload = Map.new(payload, fn {k, v} -> {Util.maybe_to_atom(k), v} end)

      member_id = Util.cast(member_payload[:user][:id], Snowflake)

      key = {guild_id, member_id}

      {old_member, new_member} =
        :mnesia.activity(:sync_transaction, fn ->
          case :mnesia.read(table(), key, :write) do
            [{_tag, _key, _guild_id, _user_id, old_member} = entry] ->
              new_member = Member.to_struct(member_payload, old_member)

              :mnesia.write(table(), put_elem(entry, 4, new_member), :write)
              {old_member, new_member}

            [] ->
              new_member = Member.to_struct(member_payload)
              {nil, new_member}
          end
        end)

      {guild_id, old_member, new_member}
    end

    @impl MemberCache
    @doc "Remove the given member from the given guild in the cache."
    @spec delete(Guild.id(), Member.user_id()) :: {Guild.id(), Member.t()} | :noop
    def delete(guild_id, user_id) do
      key = {guild_id, user_id}

      :mnesia.activity(:sync_transaction, fn ->
        case :mnesia.read(table(), key, :write) do
          [{_tag, _key, _guild_id, _user_id, member}] ->
            :mnesia.delete(table(), key, :write)
            {guild_id, member}

          _ ->
            :noop
        end
      end)
    end

    @impl MemberCache
    @doc "Bulk create a chunk of members for the given guild in the cache."
    def bulk_create(guild_id, members) do
      :mnesia.activity(:sync_transaction, fn ->
        # https://erlang.org/pipermail/erlang-questions/2005-August/016382.html
        # Substantially reduces locking overhead for large amount of records.
        :mnesia.write_lock_table(table())

        Enum.each(
          members,
          &:mnesia.write(
            table(),
            {record_name(), {guild_id, &1.user.id}, guild_id, &1.user.id,
             Util.cast(&1, {:struct, Member})},
            :write
          )
        )
      end)

      true
    end

    @impl MemberCache
    @doc "Wrap long-running queries in a transaction."
    @doc since: "0.10.0"
    def wrap_query(fun) do
      :mnesia.activity(:sync_transaction, fun)
    end
  end
end
