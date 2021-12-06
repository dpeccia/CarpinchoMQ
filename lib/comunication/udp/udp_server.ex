defmodule UDPServer do
  use GenServer
  require Logger

  def start_link(port \\ 2052) do
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end


  def init(port) do
    info("started server on port #{inspect(port)}")
    :gen_udp.open(port, [:binary, active: true])
  end

  def handle_cast({:send_message, queue_name, message, consumer}, socket) do
    message = %{
      "queueName" => Atom.to_string(queue_name),
      "message" => message
    }

    debug("sending #{inspect(message)} from #{queue_name} to #{inspect(consumer)}")
    { :ok, address } = consumer.address |> to_charlist |> :inet.parse_address()
    :gen_udp.send(socket, address, consumer.port, Jason.encode!(message))
    { :noreply, socket }
  end

  def handle_info({:udp, _socket, address, _port, data}, socket) do
    case Jason.decode(data) do
      { :ok, %{ "port" => listeningPort, "data" => %{ "method" => method, "body" => body } } } ->
        consumer = new_consumer(address, listeningPort)
        handle_packet(method, body, consumer)
      _ -> handle_parse_error(data)
    end

    { :noreply, socket }
  end

  defp handle_packet("subscribe", %{ "queueName" => queue_name }, consumer) do
    info("subscription message from #{inspect(consumer)} to #{queue_name}")
    Consumer.subscribe(String.to_atom(queue_name), consumer)
  end

  defp handle_packet("unsubscribe", %{ "queueName" => queue_name }, consumer) do
    info("unsubscription message from from #{inspect(consumer)} to #{queue_name}")
    Consumer.unsubscribe(String.to_atom(queue_name), consumer)
  end

  defp handle_packet("ack", %{ "queueName" => queue_name, "messageId" => message_id }, consumer) do
    info("received ack message from #{inspect(consumer)} to #{queue_name}")
    Consumer.ack(String.to_atom(queue_name), String.to_atom(message_id), consumer)
  end

  defp handle_packet(method, body, consumer) do
    message = %{
      "method" => method,
      "body" => body,
      "from" => inspect(consumer)
    }

    debug("could not resolve method: #{inspect(message)}")
  end

  defp handle_parse_error(data) do
    debug("could not parse message: #{inspect(data)}")
  end

  defp log_message(message),
    do: "[UDP] #{message}"

  defp debug(message) do
    log_message(message) |> Logger.debug
  end

  defp info(message) do
    log_message(message) |> Logger.info
  end

  defp new_consumer(address, port) do
    %{
      address: address |> :inet_parse.ntoa |> to_string(),
      port: port
    }
  end
end
