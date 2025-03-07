defmodule Electric.Replication.Postgres.LogicalReplicationProducer do
  use GenStage
  require Logger

  alias Ecto.Changeset.Relation
  alias Electric.Telemetry.Metrics

  alias Electric.Postgres.LogicalReplication
  alias Electric.Postgres.LogicalReplication.Messages
  alias Electric.Replication.Postgres.Client
  alias Electric.Replication.Connectors

  alias Electric.Postgres.LogicalReplication.Messages.{
    Begin,
    Origin,
    Commit,
    Relation,
    Insert,
    Update,
    Delete,
    Truncate,
    Type
  }

  alias Electric.Replication.Changes

  alias Electric.Replication.Changes.{
    Transaction,
    NewRecord,
    UpdatedRecord,
    DeletedRecord,
    TruncatedRelation
  }

  defmodule State do
    defstruct conn: nil,
              demand: 0,
              queue: nil,
              relations: %{},
              transaction: nil,
              publication: nil,
              client: nil,
              origin: nil,
              drop_current_transaction?: false,
              types: %{},
              ignore_relations: []

    @type t() :: %__MODULE__{
            conn: pid(),
            demand: non_neg_integer(),
            queue: :queue.queue(),
            relations: %{Messages.relation_id() => %Relation{}},
            transaction: {Electric.Postgres.Lsn.t(), %Transaction{}},
            publication: String.t(),
            origin: Connectors.origin(),
            drop_current_transaction?: boolean(),
            types: %{},
            ignore_relations: [term()]
          }
  end

  @spec start_link(Connectors.config()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(conn_config) do
    GenStage.start_link(__MODULE__, conn_config)
  end

  @spec get_name(Connectors.origin()) :: Electric.reg_name()
  def get_name(name) do
    {:via, :gproc, name(name)}
  end

  defp name(name) do
    {:n, :l, {__MODULE__, name}}
  end

  @impl true
  def init(conn_config) do
    origin = Connectors.origin(conn_config)
    conn_opts = Connectors.get_connection_opts(conn_config)
    repl_opts = Connectors.get_replication_opts(conn_config)

    :gproc.reg(name(origin))

    publication = repl_opts.publication
    slot = repl_opts.slot

    Logger.debug("#{__MODULE__} init:: publication: '#{publication}', slot: '#{slot}'")

    with {:ok, conn} <- Client.connect(conn_opts),
         :ok <- Client.start_replication(conn, publication, slot, self()) do
      Logger.metadata(pg_producer: origin)
      Logger.info("Starting replication from #{origin}")
      Logger.info("Connection settings: #{inspect(conn_opts)}")

      {:producer,
       %State{
         conn: conn,
         queue: :queue.new(),
         publication: publication,
         origin: origin
       }}
    end
  end

  @impl true
  def handle_info({:epgsql, _pid, {:x_log_data, _start_lsn, _end_lsn, binary_msg}}, state) do
    binary_msg
    |> LogicalReplication.decode_message()
    |> process_message(state)
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message #{inspect(msg)}")
    {:noreply, [], state}
  end

  defp process_message(%Begin{} = msg, state) do
    tx = %Transaction{changes: [], commit_timestamp: msg.commit_timestamp}

    {:noreply, [], %{state | transaction: {msg.final_lsn, tx}}}
  end

  defp process_message(%Origin{} = msg, state) do
    # If we got the "origin" message, it means that the Postgres sending the data has got it from Electric already
    # so we just drop the transaction altogether
    Logger.debug("origin: #{inspect(msg.name)}")
    {:noreply, [], %{state | drop_current_transaction?: true}}
  end

  defp process_message(%Type{}, state), do: {:noreply, [], state}

  defp process_message(%Relation{} = msg, state) do
    state =
      case ignore_relations(msg, state) do
        {true, state} ->
          Logger.debug("ignore relation from electric schema #{inspect(msg)}")
          %{state | relations: Map.put(state.relations, msg.id, msg)}

        false ->
          %{state | relations: Map.put(state.relations, msg.id, msg)}
      end

    # Mapping from a `LogicalReplication.Messages.Relation` to a
    # `Electric.Replication.Changes.Relation` is a little superfluous but keeps
    # the clean line between pg logical replication and this internal change
    # stream.
    # The Relation messages are used and then dropped by the
    # `Electric.Replication.Postgres.MigrationConsumer` stage that reads from
    # this producer. 
    relation =
      Changes.Relation
      |> struct(Map.from_struct(msg))
      |> Map.put(
        :columns,
        Enum.map(msg.columns, &struct(Changes.Relation.Column, Map.from_struct(&1)))
      )

    queue = :queue.in(relation, state.queue)
    state = %{state | queue: queue}

    dispatch_events(state, [])
  end

  defp process_message(%Insert{} = msg, %State{} = state) do
    Metrics.pg_producer_received(state.origin, :insert)

    relation = Map.get(state.relations, msg.relation_id)

    data = data_tuple_to_map(relation.columns, msg.tuple_data)

    new_record = %NewRecord{relation: {relation.namespace, relation.name}, record: data}

    {lsn, txn} = state.transaction
    txn = %{txn | changes: [new_record | txn.changes]}

    {:noreply, [],
     %{
       state
       | transaction: {lsn, txn},
         drop_current_transaction?: maybe_drop(msg.relation_id, state)
     }}
  end

  defp process_message(%Update{} = msg, %State{} = state) do
    Metrics.pg_producer_received(state.origin, :update)

    relation = Map.get(state.relations, msg.relation_id)

    old_data = data_tuple_to_map(relation.columns, msg.old_tuple_data)
    data = data_tuple_to_map(relation.columns, msg.tuple_data)

    updated_record = %UpdatedRecord{
      relation: {relation.namespace, relation.name},
      old_record: old_data,
      record: data
    }

    {lsn, txn} = state.transaction
    txn = %{txn | changes: [updated_record | txn.changes]}

    {:noreply, [],
     %{
       state
       | transaction: {lsn, txn},
         drop_current_transaction?: maybe_drop(msg.relation_id, state)
     }}
  end

  defp process_message(%Delete{} = msg, %State{} = state) do
    Metrics.pg_producer_received(state.origin, :delete)

    relation = Map.get(state.relations, msg.relation_id)

    data =
      data_tuple_to_map(
        relation.columns,
        msg.old_tuple_data || msg.changed_key_tuple_data
      )

    deleted_record = %DeletedRecord{
      relation: {relation.namespace, relation.name},
      old_record: data
    }

    {lsn, txn} = state.transaction
    txn = %{txn | changes: [deleted_record | txn.changes]}

    {:noreply, [],
     %{
       state
       | transaction: {lsn, txn},
         drop_current_transaction?: maybe_drop(msg.relation_id, state)
     }}
  end

  defp process_message(%Truncate{} = msg, state) do
    truncated_relations =
      for truncated_relation <- msg.truncated_relations do
        relation = Map.get(state.relations, truncated_relation)

        %TruncatedRelation{
          relation: {relation.namespace, relation.name}
        }
      end

    {lsn, txn} = state.transaction
    txn = %{txn | changes: Enum.reverse(truncated_relations) ++ txn.changes}

    {:noreply, [], %{state | transaction: {lsn, txn}}}
  end

  # When we have a new event, enqueue it and see if there's any
  # pending demand we can meet by dispatching events.

  defp process_message(
         %Commit{lsn: commit_lsn},
         %State{transaction: {current_txn_lsn, _}, drop_current_transaction?: true} = state
       )
       when commit_lsn == current_txn_lsn do
    Logger.debug("ignoring transaction with lsn #{inspect(commit_lsn)}")
    {:noreply, [], %{state | transaction: nil, drop_current_transaction?: false}}
  end

  defp process_message(
         %Commit{lsn: commit_lsn, end_lsn: end_lsn},
         %State{transaction: {current_txn_lsn, txn}, queue: queue} = state
       )
       when commit_lsn == current_txn_lsn do
    event = build_message(Map.update!(txn, :changes, &Enum.reverse/1), end_lsn, state)

    queue = :queue.in(event, queue)
    state = %{state | queue: queue, transaction: nil, drop_current_transaction?: false}

    dispatch_events(state, [])
  end

  # When we have new demand, add it to any pending demand and see if we can
  # meet it by dispatching events.
  @impl true
  def handle_demand(incoming_demand, %{demand: pending_demand} = state) do
    state = %{state | demand: incoming_demand + pending_demand}

    dispatch_events(state, [])
  end

  # When we're done exhausting demand, emit events.
  defp dispatch_events(%{demand: 0} = state, events) do
    emit_events(state, events)
  end

  defp dispatch_events(%{demand: demand, queue: queue} = state, events) do
    case :queue.out(queue) do
      # If the queue has events, recurse to accumulate them
      # as long as there is demand.
      {{:value, event}, queue} ->
        state = %{state | demand: demand - 1, queue: queue}

        dispatch_events(state, [event | events])

      # When the queue is empty, emit any accumulated events.
      {:empty, queue} ->
        state = %{state | queue: queue}

        emit_events(state, events)
    end
  end

  defp emit_events(state, []) do
    {:noreply, [], state}
  end

  defp emit_events(state, events) do
    {:noreply, Enum.reverse(events), state}
  end

  # TODO: Typecast to meaningful Elixir types here later
  @spec data_tuple_to_map([Relation.Column.t()], tuple()) :: term()
  defp data_tuple_to_map(_columns, nil), do: %{}

  defp data_tuple_to_map(columns, tuple_data) do
    columns
    |> Enum.zip(Tuple.to_list(tuple_data))
    |> Map.new(fn {column, data} -> {column.name, data} end)
  end

  defp build_message(%Transaction{} = transaction, end_lsn, %State{} = state) do
    conn = state.conn
    origin = state.origin

    %Transaction{
      transaction
      | origin: origin,
        origin_type: :postgresql,
        publication: state.publication,
        lsn: end_lsn,
        # Make sure not to pass state.field into ack function, as this
        # will create a copy of the whole state in memory when sending a message
        ack_fn: fn -> ack(conn, origin, end_lsn) end
    }
  end

  @spec ack(pid(), Connectors.origin(), Electric.Postgres.Lsn.t()) :: :ok
  def ack(conn, origin, lsn) do
    Logger.debug("Acknowledging #{lsn}", origin: origin)
    Client.acknowledge_lsn(conn, lsn)
  end

  # We use this fun to limit replication, electric.* tables are not expected to be
  # replicated further from PG
  defp ignore_relations(msg = %Relation{}, state = %State{}) do
    case msg.id in state.ignore_relations do
      false ->
        # We do not encourage developers to use 'electric' schema, but some
        # tools like sysbench do that by default, instead of 'public' schema

        # TODO: VAX-680 remove this special casing of schema_migrations table
        # once we are selectivley replicating tables
        # ||
        ignore? = msg.namespace == "electric" and msg.name in ["migrations", "meta"]
        # (msg.namespace == "public" and msg.name == "schema_migrations")

        if ignore? do
          {true, %State{state | ignore_relations: [msg.id | state.ignore_relations]}}
        else
          false
        end

      true ->
        {true, state}
    end
  end

  @spec maybe_drop(Messages.relation_id(), %State{}) :: boolean
  defp maybe_drop(_id, %State{drop_current_transaction?: true}) do
    true
  end

  defp maybe_drop(id, %State{ignore_relations: ids}) do
    id in ids
  end
end
