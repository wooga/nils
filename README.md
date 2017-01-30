# Nils: orchestrating long running migrations

Nils coordinates different and distributed parts of a system so that migrations/updates with complex transitions are performed in a way that the outside behaviour of the system stays consistent.

## Live cycle

A migration is the only way to align all the participating migrants. So naturally the initial setup is also a migration.
Since the migrants might live on remote nodes they might not be available at the time when the Nils server starts.
To handle this, Nils is started with the ID of a desired state and after all migrants are ready (e.g. the cluster is complete) we call `refresh/1` to actually run the migration. If the migrations themselves are idempotent, `refresh/1` can be called at any time like on a cluster becoming complete again after some nodes been down.

If we need to migrate to a new version we call `migrate/2` with the ID of the new version.

## Callbacks

Each of the migrations subjects implement the `Nils.Migrant` behaviour:

function   | Argument                                   | Purpose
-----------|--------------------------------------------|------------
`init`     | ID of the migration target (e.g. a version)| prepare initial internal state
`migrate`  | State returned from `init`             | Performs the long-running migration, this can take hours
`activate` | State returned from `migrate`          | Puts everything in effect, this should be a rather quick operation
`status`   | State from any phase                   | Provide information about the inner status, especially the progress of the migration

## API

here is an example of how to run a migration.


```
iex(1)> defmodule VanillaMigrant do
...(1)>   use Nils.Migrant
...(1)>
...(1)>   def migrate(version) do
...(1)>     Process.sleep(1000)
...(1)>     version
...(1)>   end
...(1)> end
{:module, VanillaMigrant,
 <<70, 79, 82, 49, 0, 0, 6, 160, 66, 69, 65, 77, 69, 120, 68, 99, 0, 0, 1, 52,
   131, 104, 2, 100, 0, 14, 101, 108, 105, 120, 105, 114, 95, 100, 111, 99, 115,
   95, 118, 49, 108, 0, 0, 0, 4, 104, 2, ...>>, {:migrate, 1}}

iex(2)> migrant = %Nils.Migrant{type: :test, callback: VanillaMigrant}
%Nils.Migrant{callback: VanillaMigrant, internal_ref: nil, node: :nonode@nohost, type: :test}

iex(3)> {:ok, server} = Nils.Server.start_link(:initial_version, [migrant], :nils_server)
{:ok, #PID<0.119.0>}

iex(4)> Nils.Server.status(:nils_server)
%{migrant_states: %{%Nils.Migrant{callback: VanillaMigrant,
    internal_ref: #Reference<0.0.3.582>, node: :nonode@nohost,
    type: :test} => %{current: nil, next: nil}}, queue: [],
 state: :initializing}
```

We can see that the state of the server is `:initializing` and the migrant has neither the `current` nor the `next` key set.
Lets trigger our initial migration:

```
iex(6)> Nils.Server.refresh(:nils_server)

13:12:05.371 [info]  refreshing :initial_version

13:12:05.371 [info]  migrations requested: %Nils.Migrant{callback: VanillaMigrant, internal_ref: #Reference<0.0.3.582>, node: :nonode@nohost, type: :test}

13:12:05.371 [info]  migrations complete: %Nils.Migrant{callback: VanillaMigrant, internal_ref: #Reference<0.0.3.582>, node: :nonode@nohost, type: :test}
:ok

iex(7)>  Nils.Server.status(:nils_server)
%{migrant_states: %{%Nils.Migrant{callback: VanillaMigrant,
     internal_ref: #Reference<0.0.3.582>, node: :nonode@nohost,
     type: :test} => %{current: :initial_version, next: nil}}, queue: [],
  state: :running}
```

The logging tells us that the migration was requested and completed (and activated) by calling the callback module.
Now the state switched to ":running" while the `current` key if the migrants state indicated `:initial_version`.

Now we can migrate to yet another version:

```
Nils.Server.migrate(:foo_version, :nils_server)
:ok
iex(8)> Nils.Server.status(:nils_server)

13:21:29.550 [info]  migrating to :foo_version after an outside call

13:21:29.550 [info]  migrations requested: %Nils.Migrant{callback: VanillaMigrant, internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost, type: :test}
%{migrant_states: %{%Nils.Migrant{callback: VanillaMigrant,
     internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost,
     type: :test} => %{current: :initial_version, next: :foo_version}},
  queue: [],
  state: {:migrating,
   #MapSet<[%Nils.Migrant{callback: VanillaMigrant,
     internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost, type: :test}]>}}

13:21:30.551 [info]  migrations complete: %Nils.Migrant{callback: VanillaMigrant, internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost, type: :test}

```
We called `status/1` right after we triggered the migration so we see the state being `{:migrating, list_of_pending_migrants}` and Nils holding two states of the migrant: `%{current: :initial_version, next: :foo_version}`.

After one second, the server goes back into `:running` state and the migrants states are back to `%{current: :foo_version, next: nil}`:

```
iex(9)> Nils.Server.status(:nils_server)
%{migrant_states: %{%Nils.Migrant{callback: VanillaMigrant,
     internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost,
     type: :test} => %{current: :foo_version, next: nil}}, queue: [],
  state: :running}
```

When a migration is triggered before another is finished, it is put in the queue and then triggered later:

```
iex(11)> Nils.Server.migrate(:bar_version, :nils_server)

13:29:24.352 [info]  migrating to :bar_version after an outside call
:ok

13:29:24.352 [info]  migrations requested: %Nils.Migrant{callback: VanillaMigrant, internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost, type: :test}
iex(12)> Nils.Server.migrate(:baz_version, :nils_server)

13:29:24.353 [info]  queuing migration to :baz_version
:ok
iex(13)> Nils.Server.status(:nils_server)
%{migrant_states: %{%Nils.Migrant{callback: VanillaMigrant,
     internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost,
     type: :test} => %{current: :foo_version, next: :bar_version}},
  queue: [:baz_version],
  state: {:migrating,
   #MapSet<[%Nils.Migrant{callback: VanillaMigrant,
     internal_ref: #Reference<0.0.4.840>, node: :nonode@nohost, type: :test}]>}}
```

## Transitions

Nils' state machine performs its duty cycle through state transitions that are either triggered externally by the app (`External`),
internally (`Manager/FSM`) or implicitly by the callback modules returning (`Callback Modules`).

**************************************************************************
*                                                                        *
*   External          Manager/FSM               Callback Modules         *
*------------------------------------------------------------------------*
*                                                                        *
*                     .--------------------.                             *
*                     |    Initializing    +                             *
*                     '--------------------'                             *
*                               |                                        *
*                     refresh   |                                        *
*                               v                                        *
*                     .--------------------.                             *
*              +----->|{Migrating, [x,y,z]}+                             *
*              |      '--------------------'                             *
*              |                |                                        *
*              |                |               {migration_complete, x}  *
*              |                v                                        *
*              |      .--------------------.                             *
*              |      | {Migrating, [y,z]} +                             *
*              |      '--------------------'                             *
*              |                |                                        *
*              |                |               {migration_complete, y}  *
*  migrate     |                v                                        *
*              |               ...                                       *
*              |      .--------------------.                             *
*              |      |  {Migrating, []}   +                             *
*              |      |  = Migrated        +                             *
*              |      '--------------------'                             *
*              |                |                                        *
*              |      activate  |                                        *
*              |                v                                        *
*              |      .--------------------.                             *
*              +------+ Running            |                             *
*                     '--------------------'                             *
*                                                                        *
**************************************************************************
