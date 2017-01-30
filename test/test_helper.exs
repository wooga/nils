ExUnit.start()

defmodule TestHelper do

	def wait_for(fun, timeout \\ 1000)
	def wait_for(_, timeout) when timeout <= 0  do
		throw({:error, :timeout})
	end
	def wait_for(fun, timeout) do
		case fun.() do
			true ->
				true
			_    ->
				Process.sleep(20)
				wait_for(fun, timeout - 20)
		end
	end

end
