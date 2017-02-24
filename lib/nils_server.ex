defmodule Nils.MigrantState do
  defstruct current: nil, next: nil
end

defmodule Nils.Server do
  @behaviour :gen_statem

  @dialyzer [:no_match]

  require Logger

  alias Nils.{Server, MigrantState, Migrant}

  defstruct destination_version: nil, migrants: nil, migrant_states: %{}, queue: []

  #--- API --------------------------------------------------------------------

  def start_link(destination_version, migrants = [%Migrant{}|_], {scope, name}) when scope == :local or scope == :global do
    migrants_unique = Enum.map(
      migrants,
      fn(%Migrant{internal_ref: nil} = migrant) ->
        %Migrant{migrant | internal_ref: make_ref()};
        (migrant) -> migrant
      end)
    :gen_statem.start_link({scope, name}, __MODULE__, [destination_version, migrants_unique], [])
  end
  def start_link(destination_version, migrants = [_|_], name) do
    start_link(destination_version, migrants, {:local, name})
  end

  def refresh(name) do
    :gen_statem.call(name, :refresh)
  end

  def migrate(destination_version, name) do
    :gen_statem.call(name, {:migrate, destination_version})
  end

  def status(name) do
    :gen_statem.call(name, :status)
  end

  #--- Callbacks --------------------------------------------------------------

  def callback_mode() do
    :handle_event_function
  end

  def init([destination_version, migrants]) do
    init_data = %Server{
      migrants: migrants,
      destination_version: destination_version,
    }
    {:ok, :initializing, init_data}
  end

  def handle_event({:call, from}, :status, state, data) do
    status =
    %{
      state: state,
      queue: data.queue,
      migrant_states:
        Enum.map(
          data.migrants,
          fn(migrant) ->
            migrant_state  = Map.get(data.migrant_states, migrant, %MigrantState{})
            current_status = migrant_status(migrant, migrant_state.current)
            next_status    = migrant_status(migrant, migrant_state.next)
            {migrant, %{current: current_status, next: next_status}}
          end
        )
        |> Enum.into(%{})
    }
    {:next_state, state, data, [{:reply, from, status}]}
  end

  # receiving an migration call when idling -> migrating
  def handle_event({:call, from}, {:migrate, destination_version}, state, data) when state == :running or state == :initializing do
    Logger.info("migrating to #{inspect(destination_version)} after an outside call")
    {next_state, next_data} = migrate_internal(destination_version, data)
    {:next_state, next_state, next_data, [{:reply, from, :ok}]}
  end
  # receiving an migration call during a migration -> queueing
  def handle_event({:call, from}, {:migrate, destination_version}, state, data) do
    Logger.info("queuing migration to #{inspect(destination_version)}")
    next_data = %Server{data | queue: data.queue ++ [destination_version]}
    {:next_state, state, next_data, [{:reply, from, :ok}]}
  end
  # receiving an migration cast internally from a queued migration
  def handle_event(:cast, {:migrate, destination_version}, state, data) when state == :running do
    Logger.info("migrating to #{inspect(destination_version)} after an internal cast from a queued migration")
    {next_state, next_data} = migrate_internal(destination_version, data)
    {:next_state, next_state, next_data}
  end

  def handle_event({:call, from}, :refresh, state, data) when state == :running or state == :initializing do
    Logger.info("refreshing #{inspect(data.destination_version)}")
    {next_state, next_data} = migrate_internal(data.destination_version, data)
    {:next_state, next_state, next_data, [{:reply, from, :ok}]}
  end
  def handle_event({:call, from}, :refresh, state, data) do
    Logger.info("not refreshing, migration in progress")
    {:next_state, state, data, [{:reply, from, :ok}]}
  end

  def handle_event(:cast, {:migration_complete, migrant, new_migrant_state}, {:migrating, active_migrants}, data) do
    true = MapSet.member?(active_migrants, migrant)
    remaining_migrants = MapSet.delete(active_migrants, migrant)

    migrant_state      = Map.get(data.migrant_states, migrant)
    next_migrant_state = %MigrantState{migrant_state | next: new_migrant_state}
    next_data          = %Server{data | migrant_states: Map.put(data.migrant_states, migrant, next_migrant_state)}

    case MapSet.size(remaining_migrants) == 0 do
      true ->
        {:next_state, :migrated, next_data, [{:next_event, :cast, :activate}]}
      false ->
        {:next_state, {:migrating, remaining_migrants}, next_data}
    end
  end

  def handle_event(:cast, :activate, :migrated, data) do
    next_migrant_states =
    Enum.map(
      data.migrants,
      fn(migrant) ->
        migrant_state = Map.get(data.migrant_states, migrant)
        activated_migrant_state = call!(migrant, :activate, [migrant_state.next])
        {migrant, %MigrantState{migrant_state | next: nil, current: activated_migrant_state}}
      end
    )
    |> Enum.into(%{})
    activated_data = %Server{data | migrant_states: next_migrant_states}
    case data.queue do
      [] ->
        {:next_state, :running, activated_data}
      [next_destination_version | queue_rest] ->
        next_data = %Server{activated_data | queue: queue_rest}
        {:next_state, :running, next_data, [{:next_event, :cast, {:migrate, next_destination_version}}]}
    end
  end

  def terminate(_reason, _state, _data) do
    :ok
  end

  def code_change(_old_version, old_state, old_data, _extra) do
    {:handle_event_function, old_state, old_data}
  end

  #--- Internal ---------------------------------------------------------------

  def migrant_status(_, nil) do
    nil
  end
  def migrant_status(migrant, migrant_state) do
    case call(migrant, :status, [migrant_state], 1000) do
      {:badrpc, _reason} -> :error
      result             -> result
    end
  end

  def migrate_internal(destination_version, data) do
    next_migrant_states =
    Enum.map(
      data.migrants,
      fn(migrant) ->
        server = self()
        init_migrant_state = call!(migrant, :init, [destination_version])
        spawn_link(
          fn() ->
            Logger.info("migrations requested: #{inspect(migrant)}")
            migrated_migrant_state = call!(migrant, :migrate, [init_migrant_state])
            Logger.info("migrations complete: #{inspect(migrant)}")
            :gen_statem.cast(server, {:migration_complete, migrant, migrated_migrant_state})
          end
        )
        migrant_state = Map.get(data.migrant_states, migrant, %MigrantState{})
        {migrant, %MigrantState{migrant_state | next: init_migrant_state}}
      end
    )
    |> Enum.into(%{})

    next_data  = %Server{data |
      migrant_states:    next_migrant_states,
      destination_version: destination_version,
    }
    next_state = {:migrating, MapSet.new(data.migrants)}
    {next_state, next_data}
  end

  def call(migrant, method, args, timeout \\ :infinity) do
   case :rpc.call(migrant.node, migrant.callback, method, args, timeout) do
      {:badrpc, :timeout} ->
        {:error, :timeou}
      reply ->
        reply
   end
  end

  def call!(migrant, method, args) do
    case call(migrant, method, args) do
      error = {:badrpc, _reason} -> exit({migrant.callback, migrant.node, method, error})
      result                     -> result
    end
  end


end
