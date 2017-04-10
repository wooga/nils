defmodule NilsServerTest do
  use ExUnit.Case
  alias Nils.{Server, Migrant}

  @moduletag :capture_log

  defmodule VanillaMigrant do
    use Nils.Migrant

    def migrate(state) do
      Process.sleep(10)
      state
    end

  end

  defmodule ReportingMigrant do
    use Nils.Migrant

    def init(state) do
      report(:init)
      state
    end

    def migrate(state) do
      Process.sleep(10)
      report(:migrate)
      state
    end

    def activate(state) do
      report(:activate)
      state
    end

    def status(state) do
      state
    end

    def report(msg) do
      Process.send(:test_process, {__MODULE__, msg}, [])
    end

  end

  test "starting and migrating with a vanilla migrant" do
    ref = make_ref()
    {:ok, server} = Server.start_link(:next_version_init, [%Migrant{type: :test, callback: VanillaMigrant, internal_ref: ref}], :test_server)
    assert :initializing == Server.status(:test_server).state
    assert is_pid(server)
    assert :ok == Server.refresh(:test_server)
    assert TestHelper.wait_for(fn() -> :running == Server.status(:test_server).state end)
    status = %{state: :running, queue: [], current_version: :next_version_init, next_version: nil, migrant_states: %{%Nils.Migrant{callback: VanillaMigrant, node: :nonode@nohost, type: :test, internal_ref: ref} => %{current: :next_version_init, next: nil}}}
    assert status == Server.status(:test_server)
    assert :ok == Server.migrate(:next_version1, :test_server)
    assert TestHelper.wait_for(fn() -> :running == Server.status(:test_server).state end)
    status = %{state: :running, queue: [], current_version: :next_version1, next_version: nil, migrant_states: %{%Nils.Migrant{callback: VanillaMigrant, node: :nonode@nohost, type: :test, internal_ref: ref} => %{current: :next_version1, next: nil}}}
    assert status == Server.status(:test_server)
  end

  test "queueing migrations" do
    ref = make_ref()
    {:ok, _} = Server.start_link(:next_version_init, [%Migrant{type: :test, callback: VanillaMigrant, internal_ref: ref}], :test_server)
    assert :initializing == Server.status(:test_server).state
    assert :ok == Server.refresh(:test_server)
    assert TestHelper.wait_for(fn() -> :running == Server.status(:test_server).state end)
    assert :ok == Server.migrate(:next_version1, :test_server)
    assert :ok == Server.migrate(:next_version2, :test_server)
    assert :ok == Server.migrate(:next_version3, :test_server)
    assert [:next_version2, :next_version3] == Server.status(:test_server).queue
    assert TestHelper.wait_for(fn() -> :running == Server.status(:test_server).state end)
    assert [] == Server.status(:test_server).queue
    status = %{state: :running,
              current_version: :next_version3,
              next_version: nil,
              migrant_states: %{
                %Nils.Migrant{callback: VanillaMigrant, node: :nonode@nohost, type: :test, internal_ref: ref} =>
                  %{current: :next_version3, next: nil}
              },
              queue: []}
    assert status == Server.status(:test_server)
  end


  test "starting and migrating with a vanilla migrant and a reporting migrant" do
    Process.register(self(), :test_process)
    {reporting_ref, vanilla_ref} = {make_ref(), make_ref()}
    {:ok, _} = Server.start_link(
      :next_version_init,
      [
          %Migrant{type: :test, callback: VanillaMigrant,   internal_ref: vanilla_ref},
          %Migrant{type: :test, callback: ReportingMigrant, internal_ref: reporting_ref}
      ],
    :test_server)
    assert :initializing == Server.status(:test_server).state
    status = %{
              state: :initializing,
              queue: [],
              current_version: nil,
              next_version: :next_version_init,
              migrant_states: %{
                %Nils.Migrant{callback: ReportingMigrant,
                 node: :nonode@nohost,
                 internal_ref: reporting_ref,
                 type: :test} => %{current: nil, next: nil},
                %Nils.Migrant{callback: VanillaMigrant,
                 node: :nonode@nohost,
                 internal_ref: vanilla_ref,
                 type: :test} => %{current: nil, next: nil}}
               }
    assert status == Server.status(:test_server)
    refute_receive _
    assert :ok == Server.refresh(:test_server)
    assert_receive {ReportingMigrant, :init}
    assert_receive {ReportingMigrant, :migrate}
    assert_receive {ReportingMigrant, :activate}
    refute_receive _
    assert TestHelper.wait_for(fn() -> :running == Server.status(:test_server).state end)
    status = %{
        state: :running,
        queue: [],
        current_version: :next_version_init,
        next_version: nil,
        migrant_states: %{
          %Nils.Migrant{callback: VanillaMigrant, node: :nonode@nohost, type: :test, internal_ref: vanilla_ref} => %{current: :next_version_init, next: nil},
          %Nils.Migrant{callback: ReportingMigrant, node: :nonode@nohost, type: :test, internal_ref: reporting_ref} => %{current: :next_version_init, next: nil}
        }}
    assert status == Server.status(:test_server)
    assert :ok == Server.migrate(:next_version1, :test_server)
    status = %{
        state: {
          :migrating,
          (MapSet.new |> MapSet.put(%Nils.Migrant{callback: ReportingMigrant, node: :nonode@nohost, type: :test, internal_ref: reporting_ref}) |> MapSet.put(%Nils.Migrant{callback: VanillaMigrant, node: :nonode@nohost, type: :test, internal_ref: vanilla_ref}))
        },
        queue: [],
        current_version: :next_version_init,
        next_version: :next_version1,
        migrant_states: %{
          %Nils.Migrant{callback: ReportingMigrant, node: :nonode@nohost, type: :test, internal_ref: reporting_ref} => %{current: :next_version_init, next: :next_version1},
          %Nils.Migrant{callback: VanillaMigrant, node: :nonode@nohost, type: :test, internal_ref: vanilla_ref} => %{current: :next_version_init, next: :next_version1}},
        }
    assert status == Server.status(:test_server)
    assert_receive {ReportingMigrant, :init}
    assert_receive {ReportingMigrant, :migrate}
    assert_receive {ReportingMigrant, :activate}
    refute_receive _
    assert TestHelper.wait_for(fn() -> :running == Server.status(:test_server).state end)
    status =  %{state: :running,
        queue: [],
        current_version: :next_version1,
        next_version: nil,
        migrant_states: %{
          %Nils.Migrant{callback: VanillaMigrant, node: :nonode@nohost, type: :test, internal_ref: vanilla_ref} => %{current: :next_version1, next: nil},
          %Nils.Migrant{callback: ReportingMigrant, node: :nonode@nohost, type: :test, internal_ref: reporting_ref} => %{current: :next_version1, next: nil}
        }}
    assert status == Server.status(:test_server)
  end

  test "large number of migrations" do
    migrants = for _ <- 1..1001, do: %Migrant{type: :test, callback: VanillaMigrant}
    {:ok, _} = Server.start_link(:next_version_init, migrants, :test_server)
    assert :ok == Server.refresh(:test_server)
    assert TestHelper.wait_for(fn() -> :running == Server.status(:test_server).state end)
  end

end
