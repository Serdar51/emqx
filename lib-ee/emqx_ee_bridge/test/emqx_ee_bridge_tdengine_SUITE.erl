%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ee_bridge_tdengine_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

% SQL definitions
-define(SQL_BRIDGE,
    "insert into mqtt.t_mqtt_msg(ts, payload) values (${timestamp}, ${payload})"
).

-define(SQL_CREATE_DATABASE, "CREATE DATABASE IF NOT EXISTS mqtt; USE mqtt;").
-define(SQL_CREATE_TABLE,
    "CREATE TABLE t_mqtt_msg (\n"
    "  ts timestamp,\n"
    "  payload BINARY(1024)\n"
    ");"
).
-define(SQL_DROP_TABLE, "DROP TABLE t_mqtt_msg").
-define(SQL_DELETE, "DELETE from t_mqtt_msg").
-define(SQL_SELECT, "SELECT payload FROM t_mqtt_msg").

% DB defaults
-define(TD_DATABASE, "mqtt").
-define(TD_USERNAME, "root").
-define(TD_PASSWORD, "taosdata").
-define(BATCH_SIZE, 10).
-define(PAYLOAD, <<"HELLO">>).

-define(WITH_CON(Process),
    Con = connect_direct_tdengine(Config),
    Process,
    ok = tdengine:stop(Con)
).

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    [
        {group, with_batch},
        {group, without_batch}
    ].

groups() ->
    TCs = emqx_common_test_helpers:all(?MODULE),
    NonBatchCases = [t_write_timeout],
    [
        {with_batch, TCs -- NonBatchCases},
        {without_batch, TCs}
    ].

init_per_group(with_batch, Config0) ->
    Config = [{enable_batch, true} | Config0],
    common_init(Config);
init_per_group(without_batch, Config0) ->
    Config = [{enable_batch, false} | Config0],
    common_init(Config);
init_per_group(_Group, Config) ->
    Config.

end_per_group(Group, Config) when Group =:= with_batch; Group =:= without_batch ->
    connect_and_drop_table(Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    emqx_mgmt_api_test_util:end_suite(),
    ok = emqx_common_test_helpers:stop_apps([emqx_bridge, emqx_conf]),
    ok.

init_per_testcase(_Testcase, Config) ->
    connect_and_clear_table(Config),
    delete_bridge(Config),
    Config.

end_per_testcase(_Testcase, Config) ->
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    connect_and_clear_table(Config),
    ok = snabbkaffe:stop(),
    delete_bridge(Config),
    ok.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

common_init(ConfigT) ->
    Host = os:getenv("TDENGINE_HOST", "toxiproxy"),
    Port = list_to_integer(os:getenv("TDENGINE_PORT", "6041")),

    Config0 = [
        {td_host, Host},
        {td_port, Port},
        {query_mode, sync},
        {proxy_name, "tdengine_restful"}
        | ConfigT
    ],

    BridgeType = proplists:get_value(bridge_type, Config0, <<"tdengine">>),
    case emqx_common_test_helpers:is_tcp_server_available(Host, Port) of
        true ->
            % Setup toxiproxy
            ProxyHost = os:getenv("PROXY_HOST", "toxiproxy"),
            ProxyPort = list_to_integer(os:getenv("PROXY_PORT", "8474")),
            emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
            % Ensure EE bridge module is loaded
            _ = application:load(emqx_ee_bridge),
            _ = emqx_ee_bridge:module_info(),
            ok = emqx_common_test_helpers:start_apps([emqx_conf, emqx_bridge]),
            emqx_mgmt_api_test_util:init_suite(),
            % Connect to tdengine directly and create the table
            connect_and_create_table(Config0),
            {Name, TDConf} = tdengine_config(BridgeType, Config0),
            Config =
                [
                    {tdengine_config, TDConf},
                    {tdengine_bridge_type, BridgeType},
                    {tdengine_name, Name},
                    {proxy_host, ProxyHost},
                    {proxy_port, ProxyPort}
                    | Config0
                ],
            Config;
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_tdengine);
                _ ->
                    {skip, no_tdengine}
            end
    end.

tdengine_config(BridgeType, Config) ->
    Port = integer_to_list(?config(td_port, Config)),
    Server = ?config(td_host, Config) ++ ":" ++ Port,
    Name = atom_to_binary(?MODULE),
    BatchSize =
        case ?config(enable_batch, Config) of
            true -> ?BATCH_SIZE;
            false -> 1
        end,
    QueryMode = ?config(query_mode, Config),
    ConfigString =
        io_lib:format(
            "bridges.~s.~s {\n"
            "  enable = true\n"
            "  server = ~p\n"
            "  database = ~p\n"
            "  username = ~p\n"
            "  password = ~p\n"
            "  sql = ~p\n"
            "  resource_opts = {\n"
            "    request_timeout = 500ms\n"
            "    batch_size = ~b\n"
            "    query_mode = ~s\n"
            "  }\n"
            "}",
            [
                BridgeType,
                Name,
                Server,
                ?TD_DATABASE,
                ?TD_USERNAME,
                ?TD_PASSWORD,
                ?SQL_BRIDGE,
                BatchSize,
                QueryMode
            ]
        ),
    {Name, parse_and_check(ConfigString, BridgeType, Name)}.

parse_and_check(ConfigString, BridgeType, Name) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{BridgeType := #{Name := Config}}} = RawConf,
    Config.

create_bridge(Config) ->
    BridgeType = ?config(tdengine_bridge_type, Config),
    Name = ?config(tdengine_name, Config),
    TDConfig = ?config(tdengine_config, Config),
    emqx_bridge:create(BridgeType, Name, TDConfig).

delete_bridge(Config) ->
    BridgeType = ?config(tdengine_bridge_type, Config),
    Name = ?config(tdengine_name, Config),
    emqx_bridge:remove(BridgeType, Name).

create_bridge_http(Params) ->
    Path = emqx_mgmt_api_test_util:api_path(["bridges"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res} -> {ok, emqx_json:decode(Res, [return_maps])};
        Error -> Error
    end.

send_message(Config, Payload) ->
    Name = ?config(tdengine_name, Config),
    BridgeType = ?config(tdengine_bridge_type, Config),
    BridgeID = emqx_bridge_resource:bridge_id(BridgeType, Name),
    emqx_bridge:send_message(BridgeID, Payload).

query_resource(Config, Request) ->
    Name = ?config(tdengine_name, Config),
    BridgeType = ?config(tdengine_bridge_type, Config),
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, Name),
    emqx_resource:query(ResourceID, Request, #{timeout => 1_000}).

connect_direct_tdengine(Config) ->
    Opts = [
        {host, to_bin(?config(td_host, Config))},
        {port, ?config(td_port, Config)},
        {username, to_bin(?TD_USERNAME)},
        {password, to_bin(?TD_PASSWORD)},
        {pool_size, 8}
    ],

    {ok, Con} = tdengine:start_link(Opts),
    Con.

% These funs connect and then stop the tdengine connection
connect_and_create_table(Config) ->
    ?WITH_CON(begin
        {ok, _} = directly_query(Con, ?SQL_CREATE_DATABASE, []),
        {ok, _} = directly_query(Con, ?SQL_CREATE_TABLE)
    end).

connect_and_drop_table(Config) ->
    ?WITH_CON({ok, _} = directly_query(Con, ?SQL_DROP_TABLE)).

connect_and_clear_table(Config) ->
    ?WITH_CON({ok, _} = directly_query(Con, ?SQL_DELETE)).

connect_and_get_payload(Config) ->
    ?WITH_CON(
        {ok, #{<<"code">> := 0, <<"data">> := [[Result]]}} = directly_query(Con, ?SQL_SELECT)
    ),
    Result.

directly_query(Con, Query) ->
    directly_query(Con, Query, [{db_name, ?TD_DATABASE}]).

directly_query(Con, Query, QueryOpts) ->
    tdengine:insert(Con, Query, QueryOpts).

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_setup_via_config_and_publish(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    SentData = #{payload => ?PAYLOAD, timestamp => 1668602148000},
    ?check_trace(
        begin
            ?wait_async_action(
                ?assertMatch(
                    {ok, #{<<"code">> := 0, <<"rows">> := 1}}, send_message(Config, SentData)
                ),
                #{?snk_kind := tdengine_connector_query_return},
                10_000
            ),
            ?assertMatch(
                ?PAYLOAD,
                connect_and_get_payload(Config)
            ),
            ok
        end,
        fun(Trace0) ->
            Trace = ?of_kind(tdengine_connector_query_return, Trace0),
            ?assertMatch([#{result := {ok, #{<<"code">> := 0, <<"rows">> := 1}}}], Trace),
            ok
        end
    ),
    ok.

t_setup_via_http_api_and_publish(Config) ->
    BridgeType = ?config(tdengine_bridge_type, Config),
    Name = ?config(tdengine_name, Config),
    PgsqlConfig0 = ?config(tdengine_config, Config),
    PgsqlConfig = PgsqlConfig0#{
        <<"name">> => Name,
        <<"type">> => BridgeType
    },
    ?assertMatch(
        {ok, _},
        create_bridge_http(PgsqlConfig)
    ),
    SentData = #{payload => ?PAYLOAD, timestamp => 1668602148000},
    ?check_trace(
        begin
            ?wait_async_action(
                ?assertMatch(
                    {ok, #{<<"code">> := 0, <<"rows">> := 1}}, send_message(Config, SentData)
                ),
                #{?snk_kind := tdengine_connector_query_return},
                10_000
            ),
            ?assertMatch(
                ?PAYLOAD,
                connect_and_get_payload(Config)
            ),
            ok
        end,
        fun(Trace0) ->
            Trace = ?of_kind(tdengine_connector_query_return, Trace0),
            ?assertMatch([#{result := {ok, #{<<"code">> := 0, <<"rows">> := 1}}}], Trace),
            ok
        end
    ),
    ok.

t_get_status(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),

    Name = ?config(tdengine_name, Config),
    BridgeType = ?config(tdengine_bridge_type, Config),
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, Name),

    ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceID)),
    emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
        ?assertMatch(
            {ok, Status} when Status =:= disconnected orelse Status =:= connecting,
            emqx_resource_manager:health_check(ResourceID)
        )
    end),
    ok.

t_write_failure(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    {ok, _} = create_bridge(Config),
    SentData = #{payload => ?PAYLOAD, timestamp => 1668602148000},
    emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
        ?assertMatch({error, econnrefused}, send_message(Config, SentData))
    end),
    ok.

% This test doesn't work with batch enabled since it is not possible
% to set the timeout directly for batch queries
t_write_timeout(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    {ok, _} = create_bridge(Config),
    SentData = #{payload => ?PAYLOAD, timestamp => 1668602148000},
    emqx_common_test_helpers:with_failure(timeout, ProxyName, ProxyHost, ProxyPort, fun() ->
        ?assertMatch(
            {error, {resource_error, #{reason := timeout}}},
            query_resource(Config, {send_message, SentData})
        )
    end),
    ok.

t_simple_sql_query(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    Request = {query, <<"SELECT count(1) AS T">>},
    Result = query_resource(Config, Request),
    case ?config(enable_batch, Config) of
        true ->
            ?assertEqual({error, {unrecoverable_error, batch_prepare_not_implemented}}, Result);
        false ->
            ?assertMatch({ok, #{<<"code">> := 0, <<"data">> := [[1]]}}, Result)
    end,
    ok.

t_missing_data(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    Result = send_message(Config, #{}),
    ?assertMatch(
        {error, #{
            <<"code">> := 534,
            <<"desc">> := _
        }},
        Result
    ),
    ok.

t_bad_sql_parameter(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    Request = {sql, <<"">>, [bad_parameter]},
    Result = query_resource(Config, Request),
    case ?config(enable_batch, Config) of
        true ->
            ?assertEqual({error, {unrecoverable_error, invalid_request}}, Result);
        false ->
            ?assertMatch(
                {error, {unrecoverable_error, _}}, Result
            )
    end,
    ok.

to_bin(List) when is_list(List) ->
    unicode:characters_to_binary(List, utf8);
to_bin(Bin) when is_binary(Bin) ->
    Bin.
