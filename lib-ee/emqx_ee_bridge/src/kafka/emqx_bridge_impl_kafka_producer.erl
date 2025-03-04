%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_impl_kafka_producer).

-include_lib("emqx_resource/include/emqx_resource.hrl").

%% callbacks of behaviour emqx_resource
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_query_async/4,
    on_get_status/2
]).

-export([
    on_kafka_ack/3,
    handle_telemetry_event/4
]).

-include_lib("emqx/include/logger.hrl").

callback_mode() -> async_if_possible.

%% @doc Config schema is defined in emqx_ee_bridge_kafka.
on_start(InstId, Config) ->
    #{
        bridge_name := BridgeName,
        bootstrap_hosts := Hosts0,
        connect_timeout := ConnTimeout,
        metadata_request_timeout := MetaReqTimeout,
        min_metadata_refresh_interval := MinMetaRefreshInterval,
        socket_opts := SocketOpts,
        authentication := Auth,
        ssl := SSL
    } = Config,
    %% TODO: change this to `kafka_producer` after refactoring for kafka_consumer
    BridgeType = kafka,
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, BridgeName),
    _ = maybe_install_wolff_telemetry_handlers(ResourceID),
    %% it's a bug if producer config is not found
    %% the caller should not try to start a producer if
    %% there is no producer config
    ProducerConfigWrapper = get_required(producer, Config, no_kafka_producer_config),
    ProducerConfig = get_required(kafka, ProducerConfigWrapper, no_kafka_producer_parameters),
    MessageTemplate = get_required(message, ProducerConfig, no_kafka_message_template),
    Hosts = hosts(Hosts0),
    ClientId = make_client_id(BridgeName),
    ClientConfig = #{
        min_metadata_refresh_interval => MinMetaRefreshInterval,
        connect_timeout => ConnTimeout,
        client_id => ClientId,
        request_timeout => MetaReqTimeout,
        extra_sock_opts => socket_opts(SocketOpts),
        sasl => sasl(Auth),
        ssl => ssl(SSL)
    },
    #{
        topic := KafkaTopic
    } = ProducerConfig,
    case wolff:ensure_supervised_client(ClientId, Hosts, ClientConfig) of
        {ok, _} ->
            ?SLOG(info, #{
                msg => "kafka_client_started",
                instance_id => InstId,
                kafka_hosts => Hosts
            });
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "failed_to_start_kafka_client",
                instance_id => InstId,
                kafka_hosts => Hosts,
                reason => Reason
            }),
            throw(failed_to_start_kafka_client)
    end,
    %% Check if this is a dry run
    TestIdStart = string:find(InstId, ?TEST_ID_PREFIX),
    IsDryRun =
        case TestIdStart of
            nomatch ->
                false;
            _ ->
                string:equal(TestIdStart, InstId)
        end,
    WolffProducerConfig = producers_config(BridgeName, ClientId, ProducerConfig, IsDryRun),
    case wolff:ensure_supervised_producers(ClientId, KafkaTopic, WolffProducerConfig) of
        {ok, Producers} ->
            {ok, #{
                message_template => compile_message_template(MessageTemplate),
                client_id => ClientId,
                kafka_topic => KafkaTopic,
                producers => Producers,
                resource_id => ResourceID
            }};
        {error, Reason2} ->
            ?SLOG(error, #{
                msg => "failed_to_start_kafka_producer",
                instance_id => InstId,
                kafka_hosts => Hosts,
                kafka_topic => KafkaTopic,
                reason => Reason2
            }),
            %% Need to stop the already running client; otherwise, the
            %% next `on_start' call will try to ensure the client
            %% exists and it will be already present and using the old
            %% config.  This is specially bad if the original crash
            %% was due to misconfiguration and we are trying to fix
            %% it...
            _ = with_log_at_error(
                fun() -> wolff:stop_and_delete_supervised_client(ClientId) end,
                #{
                    msg => "failed_to_delete_kafka_client",
                    client_id => ClientId
                }
            ),
            throw(failed_to_start_kafka_producer)
    end.

on_stop(_InstanceID, #{client_id := ClientID, producers := Producers, resource_id := ResourceID}) ->
    _ = with_log_at_error(
        fun() -> wolff:stop_and_delete_supervised_producers(Producers) end,
        #{
            msg => "failed_to_delete_kafka_producer",
            client_id => ClientID
        }
    ),
    _ = with_log_at_error(
        fun() -> wolff:stop_and_delete_supervised_client(ClientID) end,
        #{
            msg => "failed_to_delete_kafka_client",
            client_id => ClientID
        }
    ),
    with_log_at_error(
        fun() -> uninstall_telemetry_handlers(ResourceID) end,
        #{
            msg => "failed_to_uninstall_telemetry_handlers",
            client_id => ClientID
        }
    ).

on_query(
    _InstId,
    {send_message, Message},
    #{message_template := Template, producers := Producers}
) ->
    KafkaMessage = render_message(Template, Message),
    %% TODO: this function is not used so far,
    %% timeout should be configurable
    %% or the on_query/3 should be on_query/4 instead.
    try
        {_Partition, _Offset} = wolff:send_sync(Producers, [KafkaMessage], 5000),
        ok
    catch
        error:{producer_down, _} = Reason ->
            {error, Reason};
        error:timeout ->
            {error, timeout}
    end.

%% @doc The callback API for rule-engine (or bridge without rules)
%% The input argument `Message' is an enriched format (as a map())
%% of the original #message{} record.
%% The enrichment is done by rule-engine or by the data bridge framework.
%% E.g. the output of rule-engine process chain
%% or the direct mapping from an MQTT message.
on_query_async(
    _InstId,
    {send_message, Message},
    AsyncReplyFn,
    #{message_template := Template, producers := Producers}
) ->
    KafkaMessage = render_message(Template, Message),
    %% * Must be a batch because wolff:send and wolff:send_sync are batch APIs
    %% * Must be a single element batch because wolff books calls, but not batch sizes
    %%   for counters and gauges.
    Batch = [KafkaMessage],
    %% The retuned information is discarded here.
    %% If the producer process is down when sending, this function would
    %% raise an error exception which is to be caught by the caller of this callback
    {_Partition, Pid} = wolff:send(Producers, Batch, {fun ?MODULE:on_kafka_ack/3, [AsyncReplyFn]}),
    %% this Pid is so far never used because Kafka producer is by-passing the buffer worker
    {ok, Pid}.

compile_message_template(T) ->
    KeyTemplate = maps:get(key, T, <<"${.clientid}">>),
    ValueTemplate = maps:get(value, T, <<"${.}">>),
    TimestampTemplate = maps:get(value, T, <<"${.timestamp}">>),
    #{
        key => preproc_tmpl(KeyTemplate),
        value => preproc_tmpl(ValueTemplate),
        timestamp => preproc_tmpl(TimestampTemplate)
    }.

preproc_tmpl(Tmpl) ->
    emqx_plugin_libs_rule:preproc_tmpl(Tmpl).

render_message(
    #{key := KeyTemplate, value := ValueTemplate, timestamp := TimestampTemplate}, Message
) ->
    #{
        key => render(KeyTemplate, Message),
        value => render(ValueTemplate, Message),
        ts => render_timestamp(TimestampTemplate, Message)
    }.

render(Template, Message) ->
    Opts = #{
        var_trans => fun
            (undefined) -> <<"">>;
            (X) -> emqx_plugin_libs_rule:bin(X)
        end,
        return => full_binary
    },
    emqx_plugin_libs_rule:proc_tmpl(Template, Message, Opts).

render_timestamp(Template, Message) ->
    try
        binary_to_integer(render(Template, Message))
    catch
        _:_ ->
            erlang:system_time(millisecond)
    end.

%% Wolff producer never gives up retrying
%% so there can only be 'ok' results.
on_kafka_ack(_Partition, Offset, {ReplyFn, Args}) when is_integer(Offset) ->
    %% the ReplyFn is emqx_resource_worker:handle_async_reply/2
    apply(ReplyFn, Args ++ [ok]);
on_kafka_ack(_Partition, buffer_overflow_discarded, _Callback) ->
    %% wolff should bump the dropped_queue_full counter
    %% do not apply the callback (which is basically to bump success or fail counter)
    ok.

on_get_status(_InstId, #{client_id := ClientId, kafka_topic := KafkaTopic}) ->
    case wolff_client_sup:find_client(ClientId) of
        {ok, Pid} ->
            do_get_status(Pid, KafkaTopic);
        {error, _Reason} ->
            disconnected
    end.

do_get_status(Client, KafkaTopic) ->
    %% TODO: add a wolff_producers:check_connectivity
    case wolff_client:get_leader_connections(Client, KafkaTopic) of
        {ok, Leaders} ->
            %% Kafka is considered healthy as long as any of the partition leader is reachable
            case
                lists:any(
                    fun({_Partition, Pid}) ->
                        is_pid(Pid) andalso erlang:is_process_alive(Pid)
                    end,
                    Leaders
                )
            of
                true ->
                    connected;
                false ->
                    disconnected
            end;
        {error, _} ->
            disconnected
    end.

%% Parse comma separated host:port list into a [{Host,Port}] list
hosts(Hosts) when is_binary(Hosts) ->
    hosts(binary_to_list(Hosts));
hosts(Hosts) when is_list(Hosts) ->
    kpro:parse_endpoints(Hosts).

%% Extra socket options, such as sndbuf size etc.
socket_opts(Opts) when is_map(Opts) ->
    socket_opts(maps:to_list(Opts));
socket_opts(Opts) when is_list(Opts) ->
    socket_opts_loop(Opts, []).

socket_opts_loop([], Acc) ->
    lists:reverse(Acc);
socket_opts_loop([{T, Bytes} | Rest], Acc) when
    T =:= sndbuf orelse T =:= recbuf orelse T =:= buffer
->
    Acc1 = [{T, Bytes} | adjust_socket_buffer(Bytes, Acc)],
    socket_opts_loop(Rest, Acc1);
socket_opts_loop([Other | Rest], Acc) ->
    socket_opts_loop(Rest, [Other | Acc]).

%% https://www.erlang.org/doc/man/inet.html
%% For TCP it is recommended to have val(buffer) >= val(recbuf)
%% to avoid performance issues because of unnecessary copying.
adjust_socket_buffer(Bytes, Opts) ->
    case lists:keytake(buffer, 1, Opts) of
        false ->
            [{buffer, Bytes} | Opts];
        {value, {buffer, Bytes1}, Acc1} ->
            [{buffer, max(Bytes1, Bytes)} | Acc1]
    end.

sasl(none) ->
    undefined;
sasl(#{mechanism := Mechanism, username := Username, password := Password}) ->
    {Mechanism, Username, emqx_secret:wrap(Password)};
sasl(#{
    kerberos_principal := Principal,
    kerberos_keytab_file := KeyTabFile
}) ->
    {callback, brod_gssapi, {gssapi, KeyTabFile, Principal}}.

ssl(#{enable := true} = SSL) ->
    emqx_tls_lib:to_client_opts(SSL);
ssl(_) ->
    [].

producers_config(BridgeName, ClientId, Input, IsDryRun) ->
    #{
        max_batch_bytes := MaxBatchBytes,
        compression := Compression,
        partition_strategy := PartitionStrategy,
        required_acks := RequiredAcks,
        partition_count_refresh_interval := PCntRefreshInterval,
        max_inflight := MaxInflight,
        buffer := #{
            mode := BufferMode,
            per_partition_limit := PerPartitionLimit,
            segment_bytes := SegmentBytes,
            memory_overload_protection := MemOLP0
        }
    } = Input,
    MemOLP =
        case os:type() of
            {unix, linux} -> MemOLP0;
            _ -> false
        end,
    {OffloadMode, ReplayqDir} =
        case BufferMode of
            memory -> {false, false};
            disk -> {false, replayq_dir(ClientId)};
            hybrid -> {true, replayq_dir(ClientId)}
        end,
    %% TODO: change this once we add kafka source
    BridgeType = kafka,
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, BridgeName),
    #{
        name => make_producer_name(BridgeName, IsDryRun),
        partitioner => partitioner(PartitionStrategy),
        partition_count_refresh_interval_seconds => PCntRefreshInterval,
        replayq_dir => ReplayqDir,
        replayq_offload_mode => OffloadMode,
        replayq_max_total_bytes => PerPartitionLimit,
        replayq_seg_bytes => SegmentBytes,
        drop_if_highmem => MemOLP,
        required_acks => RequiredAcks,
        max_batch_bytes => MaxBatchBytes,
        max_send_ahead => MaxInflight - 1,
        compression => Compression,
        telemetry_meta_data => #{bridge_id => ResourceID}
    }.

%% Wolff API is a batch API.
%% key_dispatch only looks at the first element, so it's named 'first_key_dispatch'
partitioner(random) -> random;
partitioner(key_dispatch) -> first_key_dispatch.

replayq_dir(ClientId) ->
    filename:join([emqx:data_dir(), "kafka", ClientId]).

%% Client ID is better to be unique to make it easier for Kafka side trouble shooting.
make_client_id(BridgeName) when is_atom(BridgeName) ->
    make_client_id(atom_to_list(BridgeName));
make_client_id(BridgeName) ->
    iolist_to_binary([BridgeName, ":", atom_to_list(node())]).

%% Producer name must be an atom which will be used as a ETS table name for
%% partition worker lookup.
make_producer_name(BridgeName, IsDryRun) when is_atom(BridgeName) ->
    make_producer_name(atom_to_list(BridgeName), IsDryRun);
make_producer_name(BridgeName, IsDryRun) ->
    %% Woff needs an atom for ets table name registration. The assumption here is
    %% that bridges with new names are not often created.
    case IsDryRun of
        true ->
            %% It is a dry run and we don't want to leak too many atoms
            %% so we use the default producer name instead of creating
            %% an unique name.
            probing_wolff_producers;
        false ->
            binary_to_atom(iolist_to_binary(["kafka_producer_", BridgeName]))
    end.

with_log_at_error(Fun, Log) ->
    try
        Fun()
    catch
        C:E ->
            ?SLOG(error, Log#{
                exception => C,
                reason => E
            })
    end.

get_required(Field, Config, Throw) ->
    Value = maps:get(Field, Config, none),
    Value =:= none andalso throw(Throw),
    Value.

%% we *must* match the bridge id in the event metadata with that in
%% the handler config; otherwise, multiple kafka producer bridges will
%% install multiple handlers to the same wolff events, multiplying the
handle_telemetry_event(
    [wolff, dropped_queue_full],
    #{counter_inc := Val},
    #{bridge_id := ID},
    #{bridge_id := ID}
) when is_integer(Val) ->
    emqx_resource_metrics:dropped_queue_full_inc(ID, Val);
handle_telemetry_event(
    [wolff, queuing],
    #{gauge_set := Val},
    #{bridge_id := ID, partition_id := PartitionID},
    #{bridge_id := ID}
) when is_integer(Val) ->
    emqx_resource_metrics:queuing_set(ID, PartitionID, Val);
handle_telemetry_event(
    [wolff, retried],
    #{counter_inc := Val},
    #{bridge_id := ID},
    #{bridge_id := ID}
) when is_integer(Val) ->
    emqx_resource_metrics:retried_inc(ID, Val);
handle_telemetry_event(
    [wolff, inflight],
    #{gauge_set := Val},
    #{bridge_id := ID, partition_id := PartitionID},
    #{bridge_id := ID}
) when is_integer(Val) ->
    emqx_resource_metrics:inflight_set(ID, PartitionID, Val);
handle_telemetry_event(_EventId, _Metrics, _MetaData, _HandlerConfig) ->
    %% Event that we do not handle
    ok.

%% Note: don't use the instance/manager ID, as that changes everytime
%% the bridge is recreated, and will lead to multiplication of
%% metrics.
-spec telemetry_handler_id(resource_id()) -> binary().
telemetry_handler_id(ResourceID) ->
    <<"emqx-bridge-kafka-producer-", ResourceID/binary>>.

uninstall_telemetry_handlers(ResourceID) ->
    HandlerID = telemetry_handler_id(ResourceID),
    telemetry:detach(HandlerID).

maybe_install_wolff_telemetry_handlers(ResourceID) ->
    %% Attach event handlers for Kafka telemetry events. If a handler with the
    %% handler id already exists, the attach_many function does nothing
    telemetry:attach_many(
        %% unique handler id
        telemetry_handler_id(ResourceID),
        [
            [wolff, dropped_queue_full],
            [wolff, queuing],
            [wolff, retried],
            [wolff, inflight]
        ],
        fun ?MODULE:handle_telemetry_event/4,
        %% we *must* keep track of the same id that is handed down to
        %% wolff producers; otherwise, multiple kafka producer bridges
        %% will install multiple handlers to the same wolff events,
        %% multiplying the metric counts...
        #{bridge_id => ResourceID}
    ).
