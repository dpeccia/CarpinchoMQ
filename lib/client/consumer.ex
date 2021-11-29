defmodule Consumer do
  use GenServer
  require Logger

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  def init(state) do
    {:ok, state}
  end

  def handle_cast({:send_message, message, consumer_pid, queue_name}, state) do
    :timer.sleep(:timer.seconds(20))
    Logger.info "Consumer \"#{inspect consumer_pid}\" received message: \"#{message.payload}\" from queue #{queue_name}"
    Queue.cast(queue_name, {:send_ack, message, consumer_pid})
    { :noreply, state }
  end

  def subscribe(queue_name, pid) do
    Queue.call(queue_name, { :subscribe, pid })
  end

  def unsubscribe(queue_name, pid) do
    Queue.call(queue_name, { :unsubscribe, pid })
  end

  def cast(consumer_pid, request) do
    GenServer.cast(consumer_pid, request)
  end
end
