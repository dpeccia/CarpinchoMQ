defmodule PrimaryQueue do
  use Queue
  require Logger

  def init(default_state) do
    info(default_state.name, "queue started")
    Process.flag(:trap_exit, true)
    {:ok, default_state, {:continue, :check_replica}}
  end

  def handle_continue(:check_replica, default_state) do
    replica = Queue.replica_name(default_state.name)
    state = OK.try do
      replica_state <- Queue.state(replica)
    after
      debug(default_state.name, "restored from replica")
      replica_state |> Map.put(:name, default_state.name)
    rescue
      _ -> default_state
    end

    { :noreply, state }
  end

  def handle_call({:push, payload}, _from, state) do
    size = Enum.count(state.elements)
    cond do
      size >= state.max_size ->
        { :reply, OK.failure(Errors.queue_max_size_exeded(state.max_size)), state }
      Enum.empty?(state.subscribers) ->
        warning(state.name, "not enough subscribers to send the message: #{payload}, message discarded")
        {:reply, OK.success(:message_queued), state}
      true ->
        new_message = create_message(payload)
        send_to_replica(state.name, {:push, new_message})
        state.work_mode.push_message(state, new_message)
        {:reply, OK.success(:message_queued), add_new_element(state, new_message)}
      end
  end

  def handle_call({:subscribe, consumer}, _from, state) do
    if is_subscriber?(consumer, state) do
      { :reply, :already_subscribed, state }
    else
      send_to_replica(state.name, { :subscribe, consumer })
      debug(state.name, "subscribed #{inspect(consumer)}")
      { :reply, :subscribed, add_subscriber(state, consumer) }
    end
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    unless is_subscriber?(subscriber, state) do
      { :reply, :not_subscribed, state }
    else
      send_to_replica(state.name, { :unsubscribe, subscriber })
      debug(state.name, "unsubscribed #{inspect(subscriber)}")
      { :reply, :unsubscribed, remove_subscribers(state, [subscriber]) }
    end
  end

  def handle_info({:message_attempt_timeout, message}, state) do
    queue_name = state.name
    element = get_element_by_message(state, message.id)
    unless element == nil or Enum.empty?(element.consumers_that_did_not_ack) do
      if rem(element.number_of_attempts, 5) == 0 do
        state.work_mode.handle_timeout(state, element)
        {:noreply, state}
      else
        new_state = update_specific_element(state, message.id, &(increase_number_of_attempts(&1)))
        debug(state.name, "retrying send message #{message.id} to consumers: #{inspect element.consumers_that_did_not_ack}. Attempt Nr. #{element.number_of_attempts + 1}")
        send_message_to(message, element.consumers_that_did_not_ack, queue_name)
        send_to_replica(state.name, {:message_attempt_timeout, message})
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_cast({:ack, message_id, consumer}, state) do
    #    :timer.sleep(:timer.seconds(20)) # Para probar que es no transaccional y tener tiempo de ver el state
    Logger.info("State and message before receiving ACK: State -> #{inspect state}; Message -> #{inspect message_id}")
    new_state = update_specific_element(state, message_id, &(update_consumers_that_did_not_ack(&1, [consumer])))
    element = get_element_by_message(new_state, message_id)
    unless element == nil do
      debug(state.name, "message #{message_id} acknowledged by #{inspect(consumer)}")
      if got_all_acks?(element) do
        debug(state.name, "message #{message_id} received all ACKs")
        Queue.cast(state.name, {:delete, element})
      end

      send_to_replica(state.name, { :ack, message_id, consumer })
    end

    {:noreply, new_state}
  end

  def handle_cast({:delete, element}, state) do
    send_to_replica(state.name, {:delete, element})
    debug(state.name, "message #{inspect(element.message)} deleted")
    { :noreply, delete_element(state, element) }
  end

  def handle_cast({:delete_dead_subscribers, subscribers_to_delete}, state) do
    send_to_replica(state.name, {:delete_dead_subscribers, subscribers_to_delete})
    Enum.each(subscribers_to_delete, fn sub ->
      UDPServer.send_error(state.name, "timed out", sub)
    end)
    { :noreply, delete_subscribers(state, subscribers_to_delete) }
  end

  def handle_cast({:send_to_subscribers, message}, state) do
    queue_name = state.name
    all_subscribers = state.subscribers
    send_message_to(message, all_subscribers, queue_name)
    {:noreply, check_queue_mode(state, message, all_subscribers)}
  end

  def handle_cast({:send_to_subscriber, message}, state) do
    queue_name = state.name
    all_subscribers = state.subscribers
    if length(all_subscribers) == state.next_subscriber_to_send  do
      subscriber_to_send = Enum.at(all_subscribers, 0)
      send_message_to(message, [subscriber_to_send], queue_name)
      new_state = update_next_subscribers_and_replica(state, 1)
                  |> check_queue_mode(message,[subscriber_to_send])
      {:noreply, new_state}
    else
      subscriber_to_send = Enum.at(all_subscribers, state.next_subscriber_to_send)
      send_message_to(message, [subscriber_to_send], queue_name)
      new_state = update_next_subscribers_and_replica(state, state.next_subscriber_to_send + 1)
                  |> check_queue_mode(message,[subscriber_to_send])
      {:noreply, new_state}
    end
  end

  def handle_cast(:notify_shutdown, state) do
    info(state.name, "queue deleted, notifying subscribers")
    Enum.each(state.subscribers, fn sub ->
      UDPServer.send_error(state.name, "the queue was deleted", sub)
    end)
    {:noreply, state}
  end

  def check_queue_mode(state, message, all_subscribers) do
    case state.queue_mode do
      :transactional -> add_receivers_to_state_message(state, all_subscribers, message)
      :non_transactional -> element = get_element_by_message(state, message.id)
                            Queue.cast(state.name, {:delete, element})
                            state
    end
  end

  defp is_subscriber?(consumer, state) do
    Enum.member?(state.subscribers, consumer)
  end

  defp send_message_to(message, subscribers, queue_name) do
    Enum.each(subscribers, fn subscriber ->
      debug(queue_name, "message #{inspect(message)} sent to #{inspect(subscriber)}")
      UDPServer.send_message(queue_name, message, subscriber)
    end)
    schedule_retry_call(message)
  end

  defp add_receivers_to_state_message(state, subscribers, message) do
    send_to_replica(state.name, { :add_receivers_to_state_message, subscribers, message })
    update_specific_element(state, message.id, &(init_sent_element_props(&1, subscribers)))
  end

  defp update_next_subscribers_and_replica(state, next_subscriber_to_send) do
    send_to_replica(state.name, {:update_next_subscriber_to_send, next_subscriber_to_send})
    update_next_subscriber(state, next_subscriber_to_send)
  end

  defp send_to_replica(queue_name, request) do
    Queue.replica_name(queue_name)
      |> Queue.cast(request)
  end

  def schedule_retry_call(message) do
    Process.send_after(self(), {:message_attempt_timeout, message}, 4000)
  end

  defp get_element_by_message(state, message_id), do: Enum.find(state.elements, &(&1.message.id == message_id))
end
