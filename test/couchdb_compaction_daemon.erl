% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couchdb_compaction_daemon).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").

-define(TIMEOUT, 30000).
-define(TIMEOUT_S, ?TIMEOUT div 1000).

-ifdef(run_broken_tests).

start() ->
    Ctx = test_util:start_couch(),
    config:set("compaction_daemon", "check_interval", "3", false),
    config:set("compaction_daemon", "min_file_size", "100000", false),
    Ctx.

setup() ->
    DbName = ?tempdb(),
    {ok, Db} = couch_db:create(DbName, [?ADMIN_CTX]),
    create_design_doc(Db),
    ok = couch_db:close(Db),
    DbName.

teardown(DbName) ->
    Configs = config:get("compactions"),
    lists:foreach(
        fun({Key, _}) ->
            ok = config:delete("compactions", Key, false)
        end,
        Configs),
    couch_server:delete(DbName, [?ADMIN_CTX]),
    ok.


compaction_daemon_test_() ->
    {
        "Compaction daemon tests",
        {
            setup,
            fun start/0, fun test_util:stop_couch/1,
            {
                foreach,
                fun setup/0, fun teardown/1,
                [
                    fun should_compact_by_default_rule/1,
                    fun should_compact_by_dbname_rule/1
                ]
            }
        }
    }.


should_compact_by_default_rule(DbName) ->
    {timeout, ?TIMEOUT_S, ?_test(begin
        {ok, Db} = couch_db:open_int(DbName, []),
        populate(DbName, 70, 70, 200 * 1024),

        {_, DbFileSize} = get_db_frag(DbName),
        {_, ViewFileSize} = get_view_frag(DbName),

        with_config_change(DbName, fun() ->
            ok = config:set("compactions", "_default",
                "[{db_fragmentation, \"70%\"}, {view_fragmentation, \"70%\"}]",
                false)
        end),

        wait_compaction_started(DbName),
        wait_compaction_finished(DbName),

        with_config_change(DbName, fun() ->
            ok = config:delete("compactions", "_default", false)
        end),

        {DbFrag2, DbFileSize2} = get_db_frag(DbName),
        {ViewFrag2, ViewFileSize2} = get_view_frag(DbName),

        ?assert(DbFrag2 < 70),
        ?assert(ViewFrag2 < 70),

        ?assert(DbFileSize > DbFileSize2),
        ?assert(ViewFileSize > ViewFileSize2),

        ?assert(is_idle(DbName)),
        ok = couch_db:close(Db)
    end)}.

should_compact_by_dbname_rule(DbName) ->
    {timeout, ?TIMEOUT_S, ?_test(begin
        {ok, Db} = couch_db:open_int(DbName, []),
        populate(DbName, 70, 70, 200 * 1024),

        {_, DbFileSize} = get_db_frag(DbName),
        {_, ViewFileSize} = get_view_frag(DbName),

        with_config_change(DbName, fun() ->
            ok = config:set("compactions", ?b2l(DbName),
                "[{db_fragmentation, \"70%\"}, {view_fragmentation, \"70%\"}]",
                false)
        end),

        wait_compaction_started(DbName),
        wait_compaction_finished(DbName),

        with_config_change(DbName, fun() ->
            ok = config:delete("compactions", ?b2l(DbName), false)
        end),

        {DbFrag2, DbFileSize2} = get_db_frag(DbName),
        {ViewFrag2, ViewFileSize2} = get_view_frag(DbName),

        ?assert(DbFrag2 < 70),
        ?assert(ViewFrag2 < 70),

        ?assert(DbFileSize > DbFileSize2),
        ?assert(ViewFileSize > ViewFileSize2),

        ?assert(is_idle(DbName)),
        ok = couch_db:close(Db)
    end)}.


create_design_doc(Db) ->
    DDoc = couch_doc:from_json_obj({[
        {<<"_id">>, <<"_design/foo">>},
        {<<"language">>, <<"javascript">>},
        {<<"views">>, {[
            {<<"foo">>, {[
                {<<"map">>, <<"function(doc) { emit(doc._id, doc); }">>}
            ]}},
            {<<"foo2">>, {[
                {<<"map">>, <<"function(doc) { emit(doc._id, doc); }">>}
            ]}},
            {<<"foo3">>, {[
                {<<"map">>, <<"function(doc) { emit(doc._id, doc); }">>}
            ]}}
        ]}}
    ]}),
    {ok, _} = couch_db:update_docs(Db, [DDoc]),
    {ok, _} = couch_db:ensure_full_commit(Db),
    ok.

populate(DbName, DbFrag, ViewFrag, MinFileSize) ->
    {CurDbFrag, DbFileSize} = get_db_frag(DbName),
    {CurViewFrag, ViewFileSize} = get_view_frag(DbName),
    populate(DbName, DbFrag, ViewFrag, MinFileSize, CurDbFrag, CurViewFrag,
             lists:min([DbFileSize, ViewFileSize])).

populate(_Db, DbFrag, ViewFrag, MinFileSize, CurDbFrag, CurViewFrag, FileSize)
    when CurDbFrag >= DbFrag, CurViewFrag >= ViewFrag, FileSize >= MinFileSize ->
    ok;
populate(DbName, DbFrag, ViewFrag, MinFileSize, _, _, _) ->
    update(DbName),
    {CurDbFrag, DbFileSize} = get_db_frag(DbName),
    {CurViewFrag, ViewFileSize} = get_view_frag(DbName),
    populate(DbName, DbFrag, ViewFrag, MinFileSize, CurDbFrag, CurViewFrag,
             lists:min([DbFileSize, ViewFileSize])).

update(DbName) ->
    {ok, Db} = couch_db:open_int(DbName, []),
    lists:foreach(fun(_) ->
        Doc = couch_doc:from_json_obj({[{<<"_id">>, couch_uuids:new()}]}),
        {ok, _} = couch_db:update_docs(Db, [Doc]),
        query_view(Db#db.name)
    end, lists:seq(1, 200)),
    couch_db:close(Db).

db_url(DbName) ->
    Addr = config:get("httpd", "bind_address", "127.0.0.1"),
    Port = integer_to_list(mochiweb_socket_server:get(couch_httpd, port)),
    "http://" ++ Addr ++ ":" ++ Port ++ "/" ++ ?b2l(DbName).

query_view(DbName) ->
    {ok, Code, _Headers, _Body} = test_request:get(
        db_url(DbName) ++ "/_design/foo/_view/foo"),
    ?assertEqual(200, Code).

get_db_frag(DbName) ->
    {ok, Db} = couch_db:open_int(DbName, []),
    {ok, Info} = couch_db:get_db_info(Db),
    couch_db:close(Db),
    FileSize = get_size(file, Info),
    DataSize = get_size(external, Info),
    {round((FileSize - DataSize) / FileSize * 100), FileSize}.

get_view_frag(DbName) ->
    {ok, Db} = couch_db:open_int(DbName, []),
    {ok, Info} = couch_mrview:get_info(Db, <<"_design/foo">>),
    couch_db:close(Db),
    FileSize = get_size(file, Info),
    DataSize = get_size(external, Info),
    {round((FileSize - DataSize) / FileSize * 100), FileSize}.

get_size(Kind, Info) ->
    couch_util:get_nested_json_value({Info}, [sizes, Kind]).

wait_compaction_started(DbName) ->
    WaitFun = fun() ->
        case is_compaction_running(DbName) of
            false -> wait;
            true ->  ok
        end
    end,
    case test_util:wait(WaitFun, 10000) of
        timeout ->
            erlang:error({assertion_failed,
                          [{module, ?MODULE},
                           {line, ?LINE},
                           {reason, "Compaction starting timeout"}]});
        _ ->
            ok
    end.

wait_compaction_finished(DbName) ->
    WaitFun = fun() ->
        case is_compaction_running(DbName) of
            true -> wait;
            false -> ok
        end
    end,
    case test_util:wait(WaitFun, 10000) of
        timeout ->
            erlang:error({assertion_failed,
                          [{module, ?MODULE},
                           {line, ?LINE},
                           {reason, "Compaction timeout"}]});
        _ ->
            ok
    end.

is_compaction_running(_DbName) ->
    couch_compaction_daemon:in_progress() /= [].

is_idle(DbName) ->
    {ok, Db} = couch_db:open_int(DbName, [?ADMIN_CTX]),
    Monitors = couch_db:monitored_by(Db),
    ok = couch_db:close(Db),
    not lists:any(fun(M) -> M /= self() end, Monitors).

with_config_change(DbName, Fun) ->
    Current = ets:info(couch_compaction_daemon_config, size),
    Fun(),
    test_util:wait(fun() ->
        case ets:info(couch_compaction_daemon_config, size) == Current of
            false -> ok;
            true -> wait
        end
    end).

-endif.
