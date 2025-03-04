%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_conf_app_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

t_copy_conf_override_on_restarts(_Config) ->
    net_kernel:start(['master@127.0.0.1', longnames]),
    ct:timetrap({seconds, 120}),
    snabbkaffe:fix_ct_logging(),
    Cluster = cluster([core, core, core]),

    %% 1. Start all nodes
    Nodes = start_cluster(Cluster),
    try
        assert_config_load_done(Nodes),

        %% 2. Stop each in order.
        stop_cluster(Nodes),

        %% 3. Restart nodes in the same order.  This should not
        %% crash and eventually all nodes should be ready.
        start_cluster_async(Cluster),

        timer:sleep(15_000),

        assert_config_load_done(Nodes),

        ok
    after
        stop_cluster(Nodes)
    end.

t_copy_data_dir(_Config) ->
    net_kernel:start(['master1@127.0.0.1', longnames]),
    ct:timetrap({seconds, 120}),
    snabbkaffe:fix_ct_logging(),
    Cluster = cluster([{core, copy1}, {core, copy2}, {core, copy3}]),

    %% 1. Start all nodes
    [First | Rest] = Nodes = start_cluster(Cluster),
    try
        assert_config_load_done(Nodes),
        rpc:call(First, ?MODULE, create_data_dir, []),
        {[ok, ok, ok], []} = rpc:multicall(Nodes, application, stop, [emqx_conf]),
        {[ok, ok, ok], []} = rpc:multicall(Nodes, ?MODULE, set_data_dir_env, []),
        ok = rpc:call(First, application, start, [emqx_conf]),
        {[ok, ok], []} = rpc:multicall(Rest, application, start, [emqx_conf]),

        assert_data_copy_done(Nodes),
        stop_cluster(Nodes),
        ok
    after
        stop_cluster(Nodes)
    end.

%%------------------------------------------------------------------------------
%% Helper functions
%%------------------------------------------------------------------------------

create_data_dir() ->
    Node = atom_to_list(node()),
    ok = filelib:ensure_dir(Node ++ "/certs/"),
    ok = filelib:ensure_dir(Node ++ "/authz/"),
    ok = filelib:ensure_dir(Node ++ "/configs/"),
    ok = file:write_file(Node ++ "/certs/fake-cert", list_to_binary(Node)),
    ok = file:write_file(Node ++ "/authz/fake-authz", list_to_binary(Node)),
    Telemetry = <<"telemetry.enable = false">>,
    ok = file:write_file(Node ++ "/configs/cluster-override.conf", Telemetry).

set_data_dir_env() ->
    Node = atom_to_list(node()),
    %% will create certs and authz dir
    ok = filelib:ensure_dir(Node ++ "/configs/"),
    {ok, [ConfigFile]} = application:get_env(emqx, config_files),
    NewConfigFile = ConfigFile ++ "." ++ Node,
    {ok, _} = file:copy(ConfigFile, NewConfigFile),
    Bin = iolist_to_binary(io_lib:format("node.config_files = [~p]~n", [NewConfigFile])),
    ok = file:write_file(NewConfigFile, Bin, [append]),
    DataDir = iolist_to_binary(io_lib:format("node.data_dir = ~p~n", [Node])),
    ok = file:write_file(NewConfigFile, DataDir, [append]),
    application:set_env(emqx, config_files, [NewConfigFile]),
    application:set_env(emqx, data_dir, Node),
    application:set_env(emqx, cluster_override_conf_file, Node ++ "/configs/cluster-override.conf"),
    ok.

assert_data_copy_done([First0 | Rest]) ->
    First = atom_to_list(First0),
    {ok, FakeCertFile} = file:read_file(First ++ "/certs/fake-cert"),
    {ok, FakeAuthzFile} = file:read_file(First ++ "/authz/fake-authz"),
    {ok, FakeOverrideFile} = file:read_file(First ++ "/configs/cluster-override.conf"),
    lists:foreach(
        fun(Node0) ->
            Node = atom_to_list(Node0),
            ?assertEqual(
                {ok, FakeCertFile},
                file:read_file(Node ++ "/certs/fake-cert"),
                #{node => Node}
            ),
            ?assertEqual(
                {ok, FakeOverrideFile},
                file:read_file(Node ++ "/configs/cluster-override.conf"),
                #{node => Node}
            ),
            ?assertEqual(
                {ok, FakeAuthzFile},
                file:read_file(Node ++ "/authz/fake-authz"),
                #{node => Node}
            )
        end,
        Rest
    ).

assert_config_load_done(Nodes) ->
    lists:foreach(
        fun(Node) ->
            Done = rpc:call(Node, emqx_app, get_init_config_load_done, []),
            ?assert(Done, #{node => Node})
        end,
        Nodes
    ).

stop_cluster(Nodes) ->
    [emqx_common_test_helpers:stop_slave(Node) || Node <- Nodes].

start_cluster(Specs) ->
    [emqx_common_test_helpers:start_slave(Name, Opts) || {Name, Opts} <- Specs].

start_cluster_async(Specs) ->
    [
        begin
            Opts1 = maps:remove(join_to, Opts),
            spawn_link(fun() -> emqx_common_test_helpers:start_slave(Name, Opts1) end),
            timer:sleep(7_000)
        end
     || {Name, Opts} <- Specs
    ].

cluster(Specs) ->
    Env = [
        {emqx, init_config_load_done, false},
        {emqx, boot_modules, []}
    ],
    emqx_common_test_helpers:emqx_cluster(Specs, [
        {env, Env},
        {apps, [emqx_conf]},
        {load_schema, false},
        {join_to, false},
        {env_handler, fun
            (emqx) ->
                application:set_env(emqx, boot_modules, []),
                io:format("~p~p~n", [node(), application:get_all_env(emqx)]),
                ok;
            (_) ->
                ok
        end}
    ]).
