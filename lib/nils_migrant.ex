defmodule Nils.Migrant do
  @callback init(String.t) :: any
  @callback migrate(any) :: any
  @callback activate(any) :: any
  @callback status(any) :: any

  defstruct type: nil, callback: nil, node: node(), internal_ref: nil

  #--- Behaviour --------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do

      @behaviour Nils.Migrant

      def init(state) do
      	state
      end

      def migrate(state) do
        state
      end

      def activate(state) do
        state
      end

      def status(state) do
      	state
      end

      defoverridable [
        init:  		1,
        migrate:  1,
        activate: 1,
        status:   1,
      ]

    end
  end


end
