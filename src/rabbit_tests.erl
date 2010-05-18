%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_tests).

-compile([export_all]).

-export([all_tests/0, test_parsing/0]).

%% Exported so the hook mechanism can call back
-export([handle_hook/3, bad_handle_hook/3, extra_arg_hook/5]).

-import(lists).

-include("rabbit.hrl").
-include("rabbit_framing.hrl").
-include_lib("kernel/include/file.hrl").

-define(PERSISTENT_MSG_STORE,     msg_store_persistent).
-define(TRANSIENT_MSG_STORE,      msg_store_transient).

test_content_prop_roundtrip(Datum, Binary) ->
    Types =  [element(1, E) || E <- Datum],
    Values = [element(2, E) || E <- Datum],
    Values = rabbit_binary_parser:parse_properties(Types, Binary), %% assertion
    Binary = rabbit_binary_generator:encode_properties(Types, Values). %% assertion

all_tests() ->
    application:set_env(rabbit, file_handles_high_watermark, 10, infinity),
    passed = test_backing_queue(),
    passed = test_priority_queue(),
    passed = test_bpqueue(),
    passed = test_pg_local(),
    passed = test_unfold(),
    passed = test_parsing(),
    passed = test_topic_matching(),
    passed = test_log_management(),
    passed = test_app_management(),
    passed = test_log_management_during_startup(),
    passed = test_cluster_management(),
    passed = test_user_management(),
    passed = test_server_status(),
    passed = maybe_run_cluster_dependent_tests(),
    passed.


maybe_run_cluster_dependent_tests() ->
    SecondaryNode = rabbit_misc:makenode("hare"),

    case net_adm:ping(SecondaryNode) of
        pong -> passed = run_cluster_dependent_tests(SecondaryNode);
        pang -> io:format("Skipping cluster dependent tests with node ~p~n",
                          [SecondaryNode])
    end,
    passed.

run_cluster_dependent_tests(SecondaryNode) ->
    SecondaryNodeS = atom_to_list(SecondaryNode),

    ok = control_action(stop_app, []),
    ok = control_action(reset, []),
    ok = control_action(cluster, [SecondaryNodeS]),
    ok = control_action(start_app, []),

    io:format("Running cluster dependent tests with node ~p~n", [SecondaryNode]),
    passed = test_delegates_async(SecondaryNode),
    passed = test_delegates_sync(SecondaryNode),

    passed.

test_priority_queue() ->

    false = priority_queue:is_queue(not_a_queue),

    %% empty Q
    Q = priority_queue:new(),
    {true, true, 0, [], []} = test_priority_queue(Q),

    %% 1-4 element no-priority Q
    true = lists:all(fun (X) -> X =:= passed end,
                     lists:map(fun test_simple_n_element_queue/1,
                               lists:seq(1, 4))),

    %% 1-element priority Q
    Q1 = priority_queue:in(foo, 1, priority_queue:new()),
    {true, false, 1, [{1, foo}], [foo]} =
        test_priority_queue(Q1),

    %% 2-element same-priority Q
    Q2 = priority_queue:in(bar, 1, Q1),
    {true, false, 2, [{1, foo}, {1, bar}], [foo, bar]} =
        test_priority_queue(Q2),

    %% 2-element different-priority Q
    Q3 = priority_queue:in(bar, 2, Q1),
    {true, false, 2, [{2, bar}, {1, foo}], [bar, foo]} =
        test_priority_queue(Q3),

    %% 1-element negative priority Q
    Q4 = priority_queue:in(foo, -1, priority_queue:new()),
    {true, false, 1, [{-1, foo}], [foo]} = test_priority_queue(Q4),

    %% merge 2 * 1-element no-priority Qs
    Q5 = priority_queue:join(priority_queue:in(foo, Q),
                             priority_queue:in(bar, Q)),
    {true, false, 2, [{0, foo}, {0, bar}], [foo, bar]} =
        test_priority_queue(Q5),

    %% merge 1-element no-priority Q with 1-element priority Q
    Q6 = priority_queue:join(priority_queue:in(foo, Q),
                             priority_queue:in(bar, 1, Q)),
    {true, false, 2, [{1, bar}, {0, foo}], [bar, foo]} =
        test_priority_queue(Q6),

    %% merge 1-element priority Q with 1-element no-priority Q
    Q7 = priority_queue:join(priority_queue:in(foo, 1, Q),
                             priority_queue:in(bar, Q)),
    {true, false, 2, [{1, foo}, {0, bar}], [foo, bar]} =
        test_priority_queue(Q7),

    %% merge 2 * 1-element same-priority Qs
    Q8 = priority_queue:join(priority_queue:in(foo, 1, Q),
                             priority_queue:in(bar, 1, Q)),
    {true, false, 2, [{1, foo}, {1, bar}], [foo, bar]} =
        test_priority_queue(Q8),

    %% merge 2 * 1-element different-priority Qs
    Q9 = priority_queue:join(priority_queue:in(foo, 1, Q),
                             priority_queue:in(bar, 2, Q)),
    {true, false, 2, [{2, bar}, {1, foo}], [bar, foo]} =
        test_priority_queue(Q9),

    %% merge 2 * 1-element different-priority Qs (other way around)
    Q10 = priority_queue:join(priority_queue:in(bar, 2, Q),
                              priority_queue:in(foo, 1, Q)),
    {true, false, 2, [{2, bar}, {1, foo}], [bar, foo]} =
        test_priority_queue(Q10),

    %% merge 2 * 2-element multi-different-priority Qs
    Q11 = priority_queue:join(Q6, Q5),
    {true, false, 4, [{1, bar}, {0, foo}, {0, foo}, {0, bar}],
     [bar, foo, foo, bar]} = test_priority_queue(Q11),

    %% and the other way around
    Q12 = priority_queue:join(Q5, Q6),
    {true, false, 4, [{1, bar}, {0, foo}, {0, bar}, {0, foo}],
     [bar, foo, bar, foo]} = test_priority_queue(Q12),

    %% merge with negative priorities
    Q13 = priority_queue:join(Q4, Q5),
    {true, false, 3, [{0, foo}, {0, bar}, {-1, foo}], [foo, bar, foo]} =
        test_priority_queue(Q13),

    %% and the other way around
    Q14 = priority_queue:join(Q5, Q4),
    {true, false, 3, [{0, foo}, {0, bar}, {-1, foo}], [foo, bar, foo]} =
        test_priority_queue(Q14),

    %% joins with empty queues:
    Q1 = priority_queue:join(Q, Q1),
    Q1 = priority_queue:join(Q1, Q),

    %% insert with priority into non-empty zero-priority queue
    Q15 = priority_queue:in(baz, 1, Q5),
    {true, false, 3, [{1, baz}, {0, foo}, {0, bar}], [baz, foo, bar]} =
        test_priority_queue(Q15),

    passed.

priority_queue_in_all(Q, L) ->
    lists:foldl(fun (X, Acc) -> priority_queue:in(X, Acc) end, Q, L).

priority_queue_out_all(Q) ->
    case priority_queue:out(Q) of
        {empty, _}       -> [];
        {{value, V}, Q1} -> [V | priority_queue_out_all(Q1)]
    end.
test_priority_queue(Q) ->
    {priority_queue:is_queue(Q),
     priority_queue:is_empty(Q),
     priority_queue:len(Q),
     priority_queue:to_list(Q),
     priority_queue_out_all(Q)}.

test_bpqueue() ->
    Q = bpqueue:new(),
    true = bpqueue:is_empty(Q),
    0 = bpqueue:len(Q),

    Q1 = bpqueue:in(bar, 3, bpqueue:in(foo, 2, bpqueue:in(foo, 1, Q))),
    false = bpqueue:is_empty(Q1),
    3 = bpqueue:len(Q1),
    [{foo, [1, 2]}, {bar, [3]}] = bpqueue:to_list(Q1),

    Q2 = bpqueue:in_r(bar, 3, bpqueue:in_r(foo, 2, bpqueue:in_r(foo, 1, Q))),
    false = bpqueue:is_empty(Q2),
    3 = bpqueue:len(Q2),
    [{bar, [3]}, {foo, [2, 1]}] = bpqueue:to_list(Q2),

    {empty, _Q} = bpqueue:out(Q),
    {{value, foo, 1}, Q3} = bpqueue:out(Q1),
    {{value, foo, 2}, Q4} = bpqueue:out(Q3),
    {{value, bar, 3}, _Q5} = bpqueue:out(Q4),

    {empty, _Q} = bpqueue:out_r(Q),
    {{value, foo, 1}, Q6} = bpqueue:out_r(Q2),
    {{value, foo, 2}, Q7} = bpqueue:out_r(Q6),
    {{value, bar, 3}, _Q8} = bpqueue:out_r(Q7),

    [{foo, [1, 2]}, {bar, [3]}] = bpqueue:to_list(bpqueue:join(Q, Q1)),
    [{bar, [3]}, {foo, [2, 1]}] = bpqueue:to_list(bpqueue:join(Q2, Q)),
    [{foo, [1, 2]}, {bar, [3, 3]}, {foo, [2,1]}] =
        bpqueue:to_list(bpqueue:join(Q1, Q2)),

    [{foo, [1, 2]}, {bar, [3]}, {foo, [1, 2]}, {bar, [3]}] =
        bpqueue:to_list(bpqueue:join(Q1, Q1)),

    [{foo, [1, 2]}, {bar, [3]}] =
        bpqueue:to_list(
          bpqueue:from_list(
            [{x, []}, {foo, [1]}, {y, []}, {foo, [2]}, {bar, [3]}, {z, []}])),

    [{undefined, [a]}] = bpqueue:to_list(bpqueue:from_list([{undefined, [a]}])),

    {4, [a,b,c,d]} =
        bpqueue:foldl(
          fun (Prefix, Value, {Prefix, Acc}) ->
                  {Prefix + 1, [Value | Acc]}
          end,
          {0, []}, bpqueue:from_list([{0,[d]}, {1,[c]}, {2,[b]}, {3,[a]}])),

    ok = bpqueue:foldl(fun (Prefix, Value, ok) -> {error, Prefix, Value} end,
                       ok, Q),
    ok = bpqueue:foldr(fun (Prefix, Value, ok) -> {error, Prefix, Value} end,
                       ok, Q),

    [] = bpqueue:to_list(Q),

    [{bar,3}, {foo,2}, {foo,1}] =
        bpqueue:foldr(fun (P, V, I) -> [{P,V} | I] end, [], Q2),

    F1 = fun (Qn) ->
                 bpqueue:map_fold_filter_l(
                   fun (foo) -> true;
                       (_) -> false
                   end,
                   fun (2, _Num) -> stop;
                       (V, Num)  -> {bar, -V, V - Num} end,
                   0, Qn)
         end,

    F2 = fun (Qn) ->
                 bpqueue:map_fold_filter_r(
                   fun (foo) -> true;
                       (_) -> false
                   end,
                   fun (2, _Num) -> stop;
                       (V, Num)  -> {bar, -V, V - Num} end,
                   0, Qn)
         end,

    {Q9, 1} = F1(Q1),
    [{bar, [-1]}, {foo, [2]}, {bar, [3]}] = bpqueue:to_list(Q9),
    {Q10, 0} = F2(Q1),
    [{foo, [1, 2]}, {bar, [3]}] = bpqueue:to_list(Q10),

    {Q11, 0} = F1(Q),
    [] = bpqueue:to_list(Q11),
    {Q12, 0} = F2(Q),
    [] = bpqueue:to_list(Q12),

    FF1 = fun (Prefixes) ->
                  fun (P) -> lists:member(P, Prefixes) end
          end,
    FF2 = fun (Prefix, Stoppers) ->
                  fun (Val, Num) ->
                          case lists:member(Val, Stoppers) of
                              true -> stop;
                              false -> {Prefix, -Val, 1 + Num}
                          end
                  end
          end,
    Queue_to_list = fun ({LHS, RHS}) -> {bpqueue:to_list(LHS), RHS} end,

    BPQL = [{foo,[1,2,2]}, {bar,[3,4,5]}, {foo,[5,6,7]}],
    BPQ = bpqueue:from_list(BPQL),

    %% no effect
    {BPQL, 0} = Queue_to_list(bpqueue:map_fold_filter_l(
                                FF1([none]), FF2(none, []), 0, BPQ)),
    {BPQL, 0} = Queue_to_list(bpqueue:map_fold_filter_l(
                                FF1([foo,bar]), FF2(none, [1]), 0, BPQ)),
    {BPQL, 0} = Queue_to_list(bpqueue:map_fold_filter_l(
                                FF1([bar]), FF2(none, [3]), 0, BPQ)),
    {BPQL, 0} = Queue_to_list(bpqueue:map_fold_filter_r(
                                FF1([bar]), FF2(foo, [5]), 0, BPQ)),
    {[], 0} = Queue_to_list(bpqueue:map_fold_filter_l(
                              fun(_P)-> throw(explosion) end,
                              fun(_V, _N) -> throw(explosion) end, 0, Q)),
    {[], 0} = Queue_to_list(bpqueue:map_fold_filter_r(
                              fun(_P)-> throw(explosion) end,
                              fun(_V, _N) -> throw(explosion) end, 0, Q)),

    %% process 1 item
    {[{foo,[-1,2,2]}, {bar,[3,4,5]}, {foo,[5,6,7]}], 1} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([foo, bar]), FF2(foo, [2]), 0, BPQ)),
    {[{foo,[1,2,2]}, {bar,[-3,4,5]}, {foo,[5,6,7]}], 1} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([bar]), FF2(bar, [4]), 0, BPQ)),
    {[{foo,[1,2,2]}, {bar,[3,4,5]}, {foo,[5,6,-7]}], 1} =
        Queue_to_list(bpqueue:map_fold_filter_r(
                        FF1([foo, bar]), FF2(foo, [6]), 0, BPQ)),
    {[{foo,[1,2,2]}, {bar,[3,4]}, {baz,[-5]}, {foo,[5,6,7]}], 1} =
        Queue_to_list(bpqueue:map_fold_filter_r(
                        FF1([bar]), FF2(baz, [4]), 0, BPQ)),

    %% change prefix
    {[{bar,[-1,-2,-2,-3,-4,-5,-5,-6,-7]}], 9} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([foo, bar]), FF2(bar, []), 0, BPQ)),
    {[{bar,[-1,-2,-2,3,4,5]}, {foo,[5,6,7]}], 3} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([foo]), FF2(bar, [5]), 0, BPQ)),
    {[{bar,[-1,-2,-2,3,4,5,-5,-6]}, {foo,[7]}], 5} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([foo]), FF2(bar, [7]), 0, BPQ)),
    {[{foo,[1,2,2,-3,-4]}, {bar,[5]}, {foo,[5,6,7]}], 2} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([bar]), FF2(foo, [5]), 0, BPQ)),
    {[{bar,[-1,-2,-2,3,4,5,-5,-6,-7]}], 6} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([foo]), FF2(bar, []), 0, BPQ)),
    {[{foo,[1,2,2,-3,-4,-5,5,6,7]}], 3} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([bar]), FF2(foo, []), 0, BPQ)),

    %% edge cases
    {[{foo,[-1,-2,-2]}, {bar,[3,4,5]}, {foo,[5,6,7]}], 3} =
        Queue_to_list(bpqueue:map_fold_filter_l(
                        FF1([foo]), FF2(foo, [5]), 0, BPQ)),
    {[{foo,[1,2,2]}, {bar,[3,4,5]}, {foo,[-5,-6,-7]}], 3} =
        Queue_to_list(bpqueue:map_fold_filter_r(
                        FF1([foo]), FF2(foo, [2]), 0, BPQ)),

    passed.

test_simple_n_element_queue(N) ->
    Items = lists:seq(1, N),
    Q = priority_queue_in_all(priority_queue:new(), Items),
    ToListRes = [{0, X} || X <- Items],
    {true, false, N, ToListRes, Items} = test_priority_queue(Q),
    passed.

test_pg_local() ->
    [P, Q] = [spawn(fun () -> receive X -> X end end) || _ <- [x, x]],
    check_pg_local(ok, [], []),
    check_pg_local(pg_local:join(a, P), [P], []),
    check_pg_local(pg_local:join(b, P), [P], [P]),
    check_pg_local(pg_local:join(a, P), [P, P], [P]),
    check_pg_local(pg_local:join(a, Q), [P, P, Q], [P]),
    check_pg_local(pg_local:join(b, Q), [P, P, Q], [P, Q]),
    check_pg_local(pg_local:join(b, Q), [P, P, Q], [P, Q, Q]),
    check_pg_local(pg_local:leave(a, P), [P, Q], [P, Q, Q]),
    check_pg_local(pg_local:leave(b, P), [P, Q], [Q, Q]),
    check_pg_local(pg_local:leave(a, P), [Q], [Q, Q]),
    check_pg_local(pg_local:leave(a, P), [Q], [Q, Q]),
    [begin X ! done,
           Ref = erlang:monitor(process, X),
           receive {'DOWN', Ref, process, X, _Info} -> ok end
     end  || X <- [P, Q]],
    check_pg_local(ok, [], []),
    passed.

check_pg_local(ok, APids, BPids) ->
    ok = pg_local:sync(),
    [true, true] = [lists:sort(Pids) == lists:sort(pg_local:get_members(Key)) ||
                       {Key, Pids} <- [{a, APids}, {b, BPids}]].

test_unfold() ->
    {[], test} = rabbit_misc:unfold(fun (_V) -> false end, test),
    List = lists:seq(2,20,2),
    {List, 0} = rabbit_misc:unfold(fun (0) -> false;
                                       (N) -> {true, N*2, N-1}
                                   end, 10),
    passed.

test_parsing() ->
    passed = test_content_properties(),
    passed = test_field_values(),
    passed.

test_content_properties() ->
    test_content_prop_roundtrip([], <<0, 0>>),
    test_content_prop_roundtrip([{bit, true}, {bit, false}, {bit, true}, {bit, false}],
                                <<16#A0, 0>>),
    test_content_prop_roundtrip([{bit, true}, {octet, 123}, {bit, true}, {octet, undefined},
                                 {bit, true}],
                                <<16#E8,0,123>>),
    test_content_prop_roundtrip([{bit, true}, {octet, 123}, {octet, 123}, {bit, true}],
                                <<16#F0,0,123,123>>),
    test_content_prop_roundtrip([{bit, true}, {shortstr, <<"hi">>}, {bit, true},
                                 {shortint, 54321}, {bit, true}],
                                <<16#F8,0,2,"hi",16#D4,16#31>>),
    test_content_prop_roundtrip([{bit, true}, {shortstr, undefined}, {bit, true},
                                 {shortint, 54321}, {bit, true}],
                                <<16#B8,0,16#D4,16#31>>),
    test_content_prop_roundtrip([{table, [{<<"a signedint">>, signedint, 12345678},
                                          {<<"a longstr">>, longstr, <<"yes please">>},
                                          {<<"a decimal">>, decimal, {123, 12345678}},
                                          {<<"a timestamp">>, timestamp, 123456789012345},
                                          {<<"a nested table">>, table,
                                           [{<<"one">>, signedint, 1},
                                            {<<"two">>, signedint, 2}]}]}],
                                <<
                                 % property-flags
                                 16#8000:16,

                                 % property-list:

                                 % table
                                 117:32,                % table length in bytes

                                 11,"a signedint",        % name
                                 "I",12345678:32,        % type and value

                                 9,"a longstr",
                                 "S",10:32,"yes please",

                                 9,"a decimal",
                                 "D",123,12345678:32,

                                 11,"a timestamp",
                                 "T", 123456789012345:64,

                                 14,"a nested table",
                                 "F",
                                        18:32,

                                        3,"one",
                                        "I",1:32,

                                        3,"two",
                                        "I",2:32 >>),
    case catch rabbit_binary_parser:parse_properties([bit, bit, bit, bit], <<16#A0,0,1>>) of
        {'EXIT', content_properties_binary_overflow} -> passed;
        V -> exit({got_success_but_expected_failure, V})
    end.

test_field_values() ->
    %% FIXME this does not test inexact numbers (double and float) yet,
    %% because they won't pass the equality assertions
    test_content_prop_roundtrip(
      [{table, [{<<"longstr">>, longstr, <<"Here is a long string">>},
                {<<"signedint">>, signedint, 12345},
                {<<"decimal">>, decimal, {3, 123456}},
                {<<"timestamp">>, timestamp, 109876543209876},
                {<<"table">>, table, [{<<"one">>, signedint, 54321},
                                      {<<"two">>, longstr, <<"A long string">>}]},
                {<<"byte">>, byte, 255},
                {<<"long">>, long, 1234567890},
                {<<"short">>, short, 655},
                {<<"bool">>, bool, true},
                {<<"binary">>, binary, <<"a binary string">>},
                {<<"void">>, void, undefined},
                {<<"array">>, array, [{signedint, 54321},
                                      {longstr, <<"A long string">>}]}

               ]}],
      <<
       % property-flags
       16#8000:16,
       % table length in bytes
       228:32,

       7,"longstr",   "S", 21:32, "Here is a long string",      %      = 34
       9,"signedint", "I", 12345:32/signed,                     % + 15 = 49
       7,"decimal",   "D", 3, 123456:32,                        % + 14 = 63
       9,"timestamp", "T", 109876543209876:64,                  % + 19 = 82
       5,"table",     "F", 31:32, % length of table             % + 11 = 93
                           3,"one", "I", 54321:32,              % +  9 = 102
                           3,"two", "S", 13:32, "A long string",% + 22 = 124
       4,"byte",      "b", 255:8,                               % +  7 = 131
       4,"long",      "l", 1234567890:64,                       % + 14 = 145
       5,"short",     "s", 655:16,                              % +  9 = 154
       4,"bool",      "t", 1,                                   % +  7 = 161
       6,"binary",    "x", 15:32, "a binary string",            % + 27 = 188
       4,"void",      "V",                                      % +  6 = 194
       5,"array",     "A", 23:32,                               % + 11 = 205
                           "I", 54321:32,                       % +  5 = 210
                           "S", 13:32, "A long string"          % + 18 = 228
       >>),
    passed.

test_topic_match(P, R) ->
    test_topic_match(P, R, true).

test_topic_match(P, R, Expected) ->
    case rabbit_exchange_type_topic:topic_matches(list_to_binary(P),
                                                  list_to_binary(R)) of
        Expected ->
            passed;
        _ ->
            {topic_match_failure, P, R}
    end.

test_topic_matching() ->
    passed = test_topic_match("#", "test.test"),
    passed = test_topic_match("#", ""),
    passed = test_topic_match("#.T.R", "T.T.R"),
    passed = test_topic_match("#.T.R", "T.R.T.R"),
    passed = test_topic_match("#.Y.Z", "X.Y.Z.X.Y.Z"),
    passed = test_topic_match("#.test", "test"),
    passed = test_topic_match("#.test", "test.test"),
    passed = test_topic_match("#.test", "ignored.test"),
    passed = test_topic_match("#.test", "more.ignored.test"),
    passed = test_topic_match("#.test", "notmatched", false),
    passed = test_topic_match("#.z", "one.two.three.four", false),
    passed.

test_app_management() ->
    %% starting, stopping, status
    ok = control_action(stop_app, []),
    ok = control_action(stop_app, []),
    ok = control_action(status, []),
    ok = control_action(start_app, []),
    ok = control_action(start_app, []),
    ok = control_action(status, []),
    passed.

test_log_management() ->
    MainLog = rabbit:log_location(kernel),
    SaslLog = rabbit:log_location(sasl),
    Suffix = ".1",

    %% prepare basic logs
    file:delete([MainLog, Suffix]),
    file:delete([SaslLog, Suffix]),

    %% simple logs reopening
    ok = control_action(rotate_logs, []),
    [true, true] = empty_files([MainLog, SaslLog]),
    ok = test_logs_working(MainLog, SaslLog),

    %% simple log rotation
    ok = control_action(rotate_logs, [Suffix]),
    [true, true] = non_empty_files([[MainLog, Suffix], [SaslLog, Suffix]]),
    [true, true] = empty_files([MainLog, SaslLog]),
    ok = test_logs_working(MainLog, SaslLog),

    %% reopening logs with log rotation performed first
    ok = clean_logs([MainLog, SaslLog], Suffix),
    ok = control_action(rotate_logs, []),
    ok = file:rename(MainLog, [MainLog, Suffix]),
    ok = file:rename(SaslLog, [SaslLog, Suffix]),
    ok = test_logs_working([MainLog, Suffix], [SaslLog, Suffix]),
    ok = control_action(rotate_logs, []),
    ok = test_logs_working(MainLog, SaslLog),

    %% log rotation on empty file
    ok = clean_logs([MainLog, SaslLog], Suffix),
    ok = control_action(rotate_logs, []),
    ok = control_action(rotate_logs, [Suffix]),
    [true, true] = empty_files([[MainLog, Suffix], [SaslLog, Suffix]]),

    %% original main log file is not writable
    ok = make_files_non_writable([MainLog]),
    {error, {cannot_rotate_main_logs, _}} = control_action(rotate_logs, []),
    ok = clean_logs([MainLog], Suffix),
    ok = add_log_handlers([{rabbit_error_logger_file_h, MainLog}]),

    %% original sasl log file is not writable
    ok = make_files_non_writable([SaslLog]),
    {error, {cannot_rotate_sasl_logs, _}} = control_action(rotate_logs, []),
    ok = clean_logs([SaslLog], Suffix),
    ok = add_log_handlers([{rabbit_sasl_report_file_h, SaslLog}]),

    %% logs with suffix are not writable
    ok = control_action(rotate_logs, [Suffix]),
    ok = make_files_non_writable([[MainLog, Suffix], [SaslLog, Suffix]]),
    ok = control_action(rotate_logs, [Suffix]),
    ok = test_logs_working(MainLog, SaslLog),

    %% original log files are not writable
    ok = make_files_non_writable([MainLog, SaslLog]),
    {error, {{cannot_rotate_main_logs, _},
             {cannot_rotate_sasl_logs, _}}} = control_action(rotate_logs, []),

    %% logging directed to tty (handlers were removed in last test)
    ok = clean_logs([MainLog, SaslLog], Suffix),
    ok = application:set_env(sasl, sasl_error_logger, tty),
    ok = application:set_env(kernel, error_logger, tty),
    ok = control_action(rotate_logs, []),
    [{error, enoent}, {error, enoent}] = empty_files([MainLog, SaslLog]),

    %% rotate logs when logging is turned off
    ok = application:set_env(sasl, sasl_error_logger, false),
    ok = application:set_env(kernel, error_logger, silent),
    ok = control_action(rotate_logs, []),
    [{error, enoent}, {error, enoent}] = empty_files([MainLog, SaslLog]),

    %% cleanup
    ok = application:set_env(sasl, sasl_error_logger, {file, SaslLog}),
    ok = application:set_env(kernel, error_logger, {file, MainLog}),
    ok = add_log_handlers([{rabbit_error_logger_file_h, MainLog},
                           {rabbit_sasl_report_file_h, SaslLog}]),
    passed.

test_log_management_during_startup() ->
    MainLog = rabbit:log_location(kernel),
    SaslLog = rabbit:log_location(sasl),

    %% start application with simple tty logging
    ok = control_action(stop_app, []),
    ok = application:set_env(kernel, error_logger, tty),
    ok = application:set_env(sasl, sasl_error_logger, tty),
    ok = add_log_handlers([{error_logger_tty_h, []},
                           {sasl_report_tty_h, []}]),
    ok = control_action(start_app, []),

    %% start application with tty logging and
    %% proper handlers not installed
    ok = control_action(stop_app, []),
    ok = error_logger:tty(false),
    ok = delete_log_handlers([sasl_report_tty_h]),
    ok = case catch control_action(start_app, []) of
             ok -> exit({got_success_but_expected_failure,
                        log_rotation_tty_no_handlers_test});
             {error, {cannot_log_to_tty, _, _}} -> ok
         end,

    %% fix sasl logging
    ok = application:set_env(sasl, sasl_error_logger,
                             {file, SaslLog}),

    %% start application with logging to non-existing directory
    TmpLog = "/tmp/rabbit-tests/test.log",
    delete_file(TmpLog),
    ok = application:set_env(kernel, error_logger, {file, TmpLog}),

    ok = delete_log_handlers([rabbit_error_logger_file_h]),
    ok = add_log_handlers([{error_logger_file_h, MainLog}]),
    ok = control_action(start_app, []),

    %% start application with logging to directory with no
    %% write permissions
    TmpDir = "/tmp/rabbit-tests",
    ok = set_permissions(TmpDir, 8#00400),
    ok = delete_log_handlers([rabbit_error_logger_file_h]),
    ok = add_log_handlers([{error_logger_file_h, MainLog}]),
    ok = case control_action(start_app, []) of
             ok -> exit({got_success_but_expected_failure,
                        log_rotation_no_write_permission_dir_test});
            {error, {cannot_log_to_file, _, _}} -> ok
         end,

    %% start application with logging to a subdirectory which
    %% parent directory has no write permissions
    TmpTestDir = "/tmp/rabbit-tests/no-permission/test/log",
    ok = application:set_env(kernel, error_logger, {file, TmpTestDir}),
    ok = add_log_handlers([{error_logger_file_h, MainLog}]),
    ok = case control_action(start_app, []) of
             ok -> exit({got_success_but_expected_failure,
                        log_rotatation_parent_dirs_test});
             {error, {cannot_log_to_file, _,
               {error, {cannot_create_parent_dirs, _, eacces}}}} -> ok
         end,
    ok = set_permissions(TmpDir, 8#00700),
    ok = set_permissions(TmpLog, 8#00600),
    ok = delete_file(TmpLog),
    ok = file:del_dir(TmpDir),

    %% start application with standard error_logger_file_h
    %% handler not installed
    ok = application:set_env(kernel, error_logger, {file, MainLog}),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, []),

    %% start application with standard sasl handler not installed
    %% and rabbit main log handler installed correctly
    ok = delete_log_handlers([rabbit_sasl_report_file_h]),
    ok = control_action(start_app, []),
    passed.

test_cluster_management() ->

    %% 'cluster' and 'reset' should only work if the app is stopped
    {error, _} = control_action(cluster, []),
    {error, _} = control_action(reset, []),
    {error, _} = control_action(force_reset, []),

    ok = control_action(stop_app, []),

    %% various ways of creating a standalone node
    NodeS = atom_to_list(node()),
    ClusteringSequence = [[],
                          [NodeS],
                          ["invalid@invalid", NodeS],
                          [NodeS, "invalid@invalid"]],

    ok = control_action(reset, []),
    lists:foreach(fun (Arg) ->
                          ok = control_action(cluster, Arg),
                          ok
                  end,
                  ClusteringSequence),
    lists:foreach(fun (Arg) ->
                          ok = control_action(reset, []),
                          ok = control_action(cluster, Arg),
                          ok
                  end,
                  ClusteringSequence),
    ok = control_action(reset, []),
    lists:foreach(fun (Arg) ->
                          ok = control_action(cluster, Arg),
                          ok = control_action(start_app, []),
                          ok = control_action(stop_app, []),
                          ok
                  end,
                  ClusteringSequence),
    lists:foreach(fun (Arg) ->
                          ok = control_action(reset, []),
                          ok = control_action(cluster, Arg),
                          ok = control_action(start_app, []),
                          ok = control_action(stop_app, []),
                          ok
                  end,
                  ClusteringSequence),

    %% convert a disk node into a ram node
    ok = control_action(reset, []),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, []),
    ok = control_action(cluster, ["invalid1@invalid",
                                  "invalid2@invalid"]),

    %% join a non-existing cluster as a ram node
    ok = control_action(reset, []),
    ok = control_action(cluster, ["invalid1@invalid",
                                  "invalid2@invalid"]),

    SecondaryNode = rabbit_misc:makenode("hare"),
    case net_adm:ping(SecondaryNode) of
        pong -> passed = test_cluster_management2(SecondaryNode);
        pang -> io:format("Skipping clustering tests with node ~p~n",
                          [SecondaryNode])
    end,

    ok = control_action(start_app, []),
    passed.

test_cluster_management2(SecondaryNode) ->
    NodeS = atom_to_list(node()),
    SecondaryNodeS = atom_to_list(SecondaryNode),

    %% make a disk node
    ok = control_action(reset, []),
    ok = control_action(cluster, [NodeS]),
    %% make a ram node
    ok = control_action(reset, []),
    ok = control_action(cluster, [SecondaryNodeS]),

    %% join cluster as a ram node
    ok = control_action(reset, []),
    ok = control_action(cluster, [SecondaryNodeS, "invalid1@invalid"]),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, []),

    %% change cluster config while remaining in same cluster
    ok = control_action(cluster, ["invalid2@invalid", SecondaryNodeS]),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, []),

    %% join non-existing cluster as a ram node
    ok = control_action(cluster, ["invalid1@invalid",
                                  "invalid2@invalid"]),
    %% turn ram node into disk node
    ok = control_action(reset, []),
    ok = control_action(cluster, [SecondaryNodeS, NodeS]),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, []),

    %% convert a disk node into a ram node
    ok = control_action(cluster, ["invalid1@invalid",
                                  "invalid2@invalid"]),

    %% turn a disk node into a ram node
    ok = control_action(reset, []),
    ok = control_action(cluster, [SecondaryNodeS]),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, []),

    %% NB: this will log an inconsistent_database error, which is harmless
    %% Turning cover on / off is OK even if we're not in general using cover,
    %% it just turns the engine on / off, doesn't actually log anything.
    cover:stop([SecondaryNode]),
    true = disconnect_node(SecondaryNode),
    pong = net_adm:ping(SecondaryNode),
    cover:start([SecondaryNode]),

    %% leaving a cluster as a ram node
    ok = control_action(reset, []),
    %% ...and as a disk node
    ok = control_action(cluster, [SecondaryNodeS, NodeS]),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, []),
    ok = control_action(reset, []),

    %% attempt to leave cluster when no other node is alive
    ok = control_action(cluster, [SecondaryNodeS, NodeS]),
    ok = control_action(start_app, []),
    ok = control_action(stop_app, SecondaryNode, []),
    ok = control_action(stop_app, []),
    {error, {no_running_cluster_nodes, _, _}} =
        control_action(reset, []),

    %% leave system clustered, with the secondary node as a ram node
    ok = control_action(force_reset, []),
    ok = control_action(start_app, []),
    ok = control_action(force_reset, SecondaryNode, []),
    ok = control_action(cluster, SecondaryNode, [NodeS]),
    ok = control_action(start_app, SecondaryNode, []),

    passed.

test_user_management() ->

    %% lots if stuff that should fail
    {error, {no_such_user, _}} =
        control_action(delete_user, ["foo"]),
    {error, {no_such_user, _}} =
        control_action(change_password, ["foo", "baz"]),
    {error, {no_such_vhost, _}} =
        control_action(delete_vhost, ["/testhost"]),
    {error, {no_such_user, _}} =
        control_action(set_permissions, ["foo", ".*", ".*", ".*"]),
    {error, {no_such_user, _}} =
        control_action(clear_permissions, ["foo"]),
    {error, {no_such_user, _}} =
        control_action(list_user_permissions, ["foo"]),
    {error, {no_such_vhost, _}} =
        control_action(list_permissions, ["-p", "/testhost"]),
    {error, {invalid_regexp, _, _}} =
        control_action(set_permissions, ["guest", "+foo", ".*", ".*"]),

    %% user creation
    ok = control_action(add_user, ["foo", "bar"]),
    {error, {user_already_exists, _}} =
        control_action(add_user, ["foo", "bar"]),
    ok = control_action(change_password, ["foo", "baz"]),
    ok = control_action(list_users, []),

    %% vhost creation
    ok = control_action(add_vhost, ["/testhost"]),
    {error, {vhost_already_exists, _}} =
        control_action(add_vhost, ["/testhost"]),
    ok = control_action(list_vhosts, []),

    %% user/vhost mapping
    ok = control_action(set_permissions, ["-p", "/testhost",
                                          "foo", ".*", ".*", ".*"]),
    ok = control_action(set_permissions, ["-p", "/testhost",
                                          "foo", ".*", ".*", ".*"]),
    ok = control_action(list_permissions, ["-p", "/testhost"]),
    ok = control_action(list_user_permissions, ["foo"]),

    %% user/vhost unmapping
    ok = control_action(clear_permissions, ["-p", "/testhost", "foo"]),
    ok = control_action(clear_permissions, ["-p", "/testhost", "foo"]),

    %% vhost deletion
    ok = control_action(delete_vhost, ["/testhost"]),
    {error, {no_such_vhost, _}} =
        control_action(delete_vhost, ["/testhost"]),

    %% deleting a populated vhost
    ok = control_action(add_vhost, ["/testhost"]),
    ok = control_action(set_permissions, ["-p", "/testhost",
                                          "foo", ".*", ".*", ".*"]),
    ok = control_action(delete_vhost, ["/testhost"]),

    %% user deletion
    ok = control_action(delete_user, ["foo"]),
    {error, {no_such_user, _}} =
        control_action(delete_user, ["foo"]),

    passed.

test_server_status() ->

    %% create a few things so there is some useful information to list
    Writer = spawn(fun () -> receive shutdown -> ok end end),
    Ch = rabbit_channel:start_link(1, self(), Writer, <<"user">>, <<"/">>),
    [Q, Q2] = [#amqqueue{} = rabbit_amqqueue:declare(
                               rabbit_misc:r(<<"/">>, queue, Name),
                               false, false, []) ||
                  Name <- [<<"foo">>, <<"bar">>]],

    ok = rabbit_amqqueue:claim_queue(Q, self()),
    ok = rabbit_amqqueue:basic_consume(Q, true, self(), Ch, undefined,
                                       <<"ctag">>, true, undefined),

    %% list queues
    ok = info_action(list_queues, rabbit_amqqueue:info_keys(), true),

    %% list exchanges
    ok = info_action(list_exchanges, rabbit_exchange:info_keys(), true),

    %% list bindings
    ok = control_action(list_bindings, []),

    %% list connections
    [#listener{host = H, port = P} | _] =
        [L || L = #listener{node = N} <- rabbit_networking:active_listeners(),
              N =:= node()],

    {ok, _C} = gen_tcp:connect(H, P, []),
    timer:sleep(100),
    ok = info_action(list_connections,
                     rabbit_networking:connection_info_keys(), false),
    %% close_connection
    [ConnPid] = rabbit_networking:connections(),
    ok = control_action(close_connection, [rabbit_misc:pid_to_string(ConnPid),
                                           "go away"]),

    %% list channels
    ok = info_action(list_channels, rabbit_channel:info_keys(), false),

    %% list consumers
    ok = control_action(list_consumers, []),

    %% cleanup
    [{ok, _} = rabbit_amqqueue:delete(QR, false, false) || QR <- [Q, Q2]],
    ok = rabbit_channel:shutdown(Ch),

    passed.

test_hooks() ->
    %% Firing of hooks calls all hooks in an isolated manner
    rabbit_hooks:subscribe(test_hook, test, {rabbit_tests, handle_hook, []}),
    rabbit_hooks:subscribe(test_hook, test2, {rabbit_tests, handle_hook, []}),
    rabbit_hooks:subscribe(test_hook2, test2, {rabbit_tests, handle_hook, []}),
    rabbit_hooks:trigger(test_hook, [arg1, arg2]),
    [arg1, arg2] = get(test_hook_test_fired),
    [arg1, arg2] = get(test_hook_test2_fired),
    undefined = get(test_hook2_test2_fired),

    %% Hook Deletion works
    put(test_hook_test_fired, undefined),
    put(test_hook_test2_fired, undefined),
    rabbit_hooks:unsubscribe(test_hook, test),
    rabbit_hooks:trigger(test_hook, [arg3, arg4]),
    undefined = get(test_hook_test_fired),
    [arg3, arg4] = get(test_hook_test2_fired),
    undefined = get(test_hook2_test2_fired),

    %% Catches exceptions from bad hooks
    rabbit_hooks:subscribe(test_hook3, test, {rabbit_tests, bad_handle_hook, []}),
    ok = rabbit_hooks:trigger(test_hook3, []),

    %% Passing extra arguments to hooks
    rabbit_hooks:subscribe(arg_hook, test, {rabbit_tests, extra_arg_hook, [1, 3]}),
    rabbit_hooks:trigger(arg_hook, [arg1, arg2]),
    {[arg1, arg2], 1, 3} = get(arg_hook_test_fired),

    %% Invoking Pids
    Remote = fun() ->
        receive
            {rabbitmq_hook,[remote_test,test,[],Target]} ->
                Target ! invoked
        end
    end,
    P = spawn(Remote),
    rabbit_hooks:subscribe(remote_test, test, {rabbit_hooks, notify_remote, [P, [self()]]}),
    rabbit_hooks:trigger(remote_test, []),
    receive
       invoked -> ok
    after 100 ->
       io:format("Remote hook not invoked"),
       throw(timeout)
    end,
    passed.

test_delegates_async(SecondaryNode) ->
    Self = self(),
    Sender = fun(Pid) -> Pid ! {invoked, Self} end,

    Responder = make_responder(fun({invoked, Pid}) -> Pid ! response end),

    ok = delegate:invoke_no_result(spawn(Responder), Sender),
    ok = delegate:invoke_no_result(spawn(SecondaryNode, Responder), Sender),
    await_response(2),

    LocalPids = spawn_responders(node(), Responder, 10),
    RemotePids = spawn_responders(SecondaryNode, Responder, 10),
    ok = delegate:invoke_no_result(LocalPids ++ RemotePids, Sender),
    await_response(20),

    passed.

make_responder(FMsg) ->
    fun() ->
        receive Msg -> FMsg(Msg)
        after 1000 -> throw(timeout)
        end
    end.

spawn_responders(Node, Responder, Count) ->
    [spawn(Node, Responder) || _ <- lists:seq(1, Count)].

await_response(0) ->
    ok;
await_response(Count) ->
    receive
        response -> ok,
        await_response(Count - 1)
    after 1000 ->
        io:format("Async reply not received~n"),
        throw(timeout)
    end.

must_exit(Fun) ->
    try
        Fun(),
        throw(exit_not_thrown)
    catch
        exit:_ -> ok
    end.

test_delegates_sync(SecondaryNode) ->
    Sender = fun(Pid) -> gen_server:call(Pid, invoked) end,
    BadSender = fun(_Pid) -> exit(exception) end,

    Responder = make_responder(fun({'$gen_call', From, invoked}) ->
                                   gen_server:reply(From, response)
                               end),

    response = delegate:invoke(spawn(Responder), Sender),
    response = delegate:invoke(spawn(SecondaryNode, Responder), Sender),

    must_exit(fun() -> delegate:invoke(spawn(Responder), BadSender) end),
    must_exit(fun() ->
        delegate:invoke(spawn(SecondaryNode, Responder), BadSender) end),

    LocalGoodPids = spawn_responders(node(), Responder, 2),
    RemoteGoodPids = spawn_responders(SecondaryNode, Responder, 2),
    LocalBadPids = spawn_responders(node(), Responder, 2),
    RemoteBadPids = spawn_responders(SecondaryNode, Responder, 2),

    {GoodRes, []} = delegate:invoke(LocalGoodPids ++ RemoteGoodPids, Sender),
    true = lists:all(fun ({_, response}) -> true end, GoodRes),
    GoodResPids = [Pid || {Pid, _} <- GoodRes],

    Good = ordsets:from_list(LocalGoodPids ++ RemoteGoodPids),
    Good = ordsets:from_list(GoodResPids),

    {[], BadRes} = delegate:invoke(LocalBadPids ++ RemoteBadPids, BadSender),
    true = lists:all(fun ({_, {exit, exception, _}}) -> true end, BadRes),
    BadResPids = [Pid || {Pid, _} <- BadRes],

    Bad = ordsets:from_list(LocalBadPids ++ RemoteBadPids),
    Bad = ordsets:from_list(BadResPids),

    passed.

%---------------------------------------------------------------------

control_action(Command, Args) -> control_action(Command, node(), Args).

control_action(Command, Node, Args) ->
    case catch rabbit_control:action(
                 Command, Node, Args,
                 fun (Format, Args1) ->
                         io:format(Format ++ " ...~n", Args1)
                 end) of
        ok ->
            io:format("done.~n"),
            ok;
        Other ->
            io:format("failed.~n"),
            Other
    end.

info_action(Command, Args, CheckVHost) ->
    ok = control_action(Command, []),
    if CheckVHost -> ok = control_action(Command, ["-p", "/"]);
       true       -> ok
    end,
    ok = control_action(Command, lists:map(fun atom_to_list/1, Args)),
    {bad_argument, dummy} = control_action(Command, ["dummy"]),
    ok.

empty_files(Files) ->
    [case file:read_file_info(File) of
         {ok, FInfo} -> FInfo#file_info.size == 0;
         Error       -> Error
     end || File <- Files].

non_empty_files(Files) ->
    [case EmptyFile of
         {error, Reason} -> {error, Reason};
         _               -> not(EmptyFile)
     end || EmptyFile <- empty_files(Files)].

test_logs_working(MainLogFile, SaslLogFile) ->
    ok = rabbit_log:error("foo bar"),
    ok = error_logger:error_report(crash_report, [foo, bar]),
    %% give the error loggers some time to catch up
    timer:sleep(50),
    [true, true] = non_empty_files([MainLogFile, SaslLogFile]),
    ok.

set_permissions(Path, Mode) ->
    case file:read_file_info(Path) of
        {ok, FInfo} -> file:write_file_info(
                         Path,
                         FInfo#file_info{mode=Mode});
        Error       -> Error
    end.

clean_logs(Files, Suffix) ->
    [begin
         ok = delete_file(File),
         ok = delete_file([File, Suffix])
     end || File <- Files],
    ok.

delete_file(File) ->
    case file:delete(File) of
        ok              -> ok;
        {error, enoent} -> ok;
        Error           -> Error
    end.

make_files_non_writable(Files) ->
    [ok = file:write_file_info(File, #file_info{mode=0}) ||
        File <- Files],
    ok.

add_log_handlers(Handlers) ->
    [ok = error_logger:add_report_handler(Handler, Args) ||
        {Handler, Args} <- Handlers],
    ok.

delete_log_handlers(Handlers) ->
    [[] = error_logger:delete_report_handler(Handler) ||
        Handler <- Handlers],
    ok.

handle_hook(HookName, Handler, Args) ->
    A = atom_to_list(HookName) ++ "_" ++ atom_to_list(Handler) ++ "_fired",
    put(list_to_atom(A), Args).
bad_handle_hook(_, _, _) ->
    bad:bad().
extra_arg_hook(Hookname, Handler, Args, Extra1, Extra2) ->
    handle_hook(Hookname, Handler, {Args, Extra1, Extra2}).

test_backing_queue() ->
    case application:get_env(rabbit, backing_queue_module) of
        {ok, rabbit_variable_queue} ->
            passed = test_msg_store(),
            passed = test_queue_index(),
            passed = test_variable_queue();
        _ ->
            passed
    end.

start_msg_store_empty() ->
    start_msg_store(fun (ok) -> finished end, ok).

start_msg_store(MsgRefDeltaGen, MsgRefDeltaGenInit) ->
    ok = rabbit_sup:start_child(
           ?PERSISTENT_MSG_STORE, rabbit_msg_store,
           [?PERSISTENT_MSG_STORE, rabbit_mnesia:dir(), undefined,
            {MsgRefDeltaGen, MsgRefDeltaGenInit}]),
    start_transient_msg_store().

start_transient_msg_store() ->
    ok = rabbit_msg_store:clean(?TRANSIENT_MSG_STORE, rabbit_mnesia:dir()),
    ok = rabbit_sup:start_child(
           ?TRANSIENT_MSG_STORE, rabbit_msg_store,
           [?TRANSIENT_MSG_STORE, rabbit_mnesia:dir(), undefined,
            {fun (ok) -> finished end, ok}]).

stop_msg_store() ->
    case supervisor:terminate_child(rabbit_sup, ?PERSISTENT_MSG_STORE) of
        ok -> supervisor:delete_child(rabbit_sup, ?PERSISTENT_MSG_STORE),
              case supervisor:terminate_child(rabbit_sup, ?TRANSIENT_MSG_STORE) of
                  ok -> supervisor:delete_child(rabbit_sup, ?TRANSIENT_MSG_STORE);
                  E -> {transient, E}
              end;
        E -> {persistent, E}
    end.

guid_bin(X) ->
    erlang:md5(term_to_binary(X)).

msg_store_contains(Atom, Guids) ->
    Atom = lists:foldl(
             fun (Guid, Atom1) when Atom1 =:= Atom ->
                     rabbit_msg_store:contains(?PERSISTENT_MSG_STORE, Guid) end,
             Atom, Guids).

msg_store_sync(Guids) ->
    Ref = make_ref(),
    Self = self(),
    ok = rabbit_msg_store:sync(?PERSISTENT_MSG_STORE, Guids,
                               fun () -> Self ! {sync, Ref} end),
    receive
        {sync, Ref} -> ok
    after
        10000 ->
            io:format("Sync from msg_store missing for guids ~p~n", [Guids]),
            throw(timeout)
    end.

msg_store_read(Guids, MSCState) ->
    lists:foldl(
      fun (Guid, MSCStateM) ->
              {{ok, Guid}, MSCStateN} = rabbit_msg_store:read(
                                           ?PERSISTENT_MSG_STORE, Guid, MSCStateM),
              MSCStateN
      end,
      MSCState, Guids).

msg_store_write(Guids, MSCState) ->
    lists:foldl(
      fun (Guid, {ok, MSCStateN}) ->
              rabbit_msg_store:write(?PERSISTENT_MSG_STORE, Guid, Guid, MSCStateN) end,
      {ok, MSCState}, Guids).

test_msg_store() ->
    stop_msg_store(),
    ok = start_msg_store_empty(),
    Self = self(),
    Guids = [guid_bin(M) || M <- lists:seq(1,100)],
    {Guids1stHalf, Guids2ndHalf} = lists:split(50, Guids),
    %% check we don't contain any of the msgs we're about to publish
    false = msg_store_contains(false, Guids),
    Ref = rabbit_guid:guid(),
    MSCState = rabbit_msg_store:client_init(?PERSISTENT_MSG_STORE, Ref),
    %% publish the first half
    {ok, MSCState1} = msg_store_write(Guids1stHalf, MSCState),
    %% sync on the first half
    ok = msg_store_sync(Guids1stHalf),
    %% publish the second half
    {ok, MSCState2} = msg_store_write(Guids2ndHalf, MSCState1),
    %% sync on the first half again - the msg_store will be dirty, but
    %% we won't need the fsync
    ok = msg_store_sync(Guids1stHalf),
    %% check they're all in there
    true = msg_store_contains(true, Guids),
    %% publish the latter half twice so we hit the caching and ref count code
    {ok, MSCState3} = msg_store_write(Guids2ndHalf, MSCState2),
    %% check they're still all in there
    true = msg_store_contains(true, Guids),
    %% sync on the 2nd half, but do lots of individual syncs to try
    %% and cause coalescing to happen
    ok = lists:foldl(
           fun (Guid, ok) -> rabbit_msg_store:sync(
                                ?PERSISTENT_MSG_STORE,
                                [Guid], fun () -> Self ! {sync, Guid} end)
           end, ok, Guids2ndHalf),
    lists:foldl(
      fun(Guid, ok) ->
              receive
                  {sync, Guid} -> ok
              after
                  10000 ->
                      io:format("Sync from msg_store missing (guid: ~p)~n",
                                [Guid]),
                      throw(timeout)
              end
      end, ok, Guids2ndHalf),
    %% it's very likely we're not dirty here, so the 1st half sync
    %% should hit a different code path
    ok = msg_store_sync(Guids1stHalf),
    %% read them all
    MSCState4 = msg_store_read(Guids, MSCState3),
    %% read them all again - this will hit the cache, not disk
    MSCState5 = msg_store_read(Guids, MSCState4),
    %% remove them all
    ok = rabbit_msg_store:remove(?PERSISTENT_MSG_STORE, Guids),
    %% check first half doesn't exist
    false = msg_store_contains(false, Guids1stHalf),
    %% check second half does exist
    true = msg_store_contains(true, Guids2ndHalf),
    %% read the second half again
    MSCState6 = msg_store_read(Guids2ndHalf, MSCState5),
    %% release the second half, just for fun (aka code coverage)
    ok = rabbit_msg_store:release(?PERSISTENT_MSG_STORE, Guids2ndHalf),
    %% read the second half again, just for fun (aka code coverage)
    MSCState7 = msg_store_read(Guids2ndHalf, MSCState6),
    ok = rabbit_msg_store:client_terminate(MSCState7),
    %% stop and restart, preserving every other msg in 2nd half
    ok = stop_msg_store(),
    ok = start_msg_store(fun ([]) -> finished;
                             ([Guid|GuidsTail])
                             when length(GuidsTail) rem 2 == 0 ->
                                 {Guid, 1, GuidsTail};
                             ([Guid|GuidsTail]) ->
                                 {Guid, 0, GuidsTail}
                         end, Guids2ndHalf),
    %% check we have the right msgs left
    lists:foldl(
      fun (Guid, Bool) ->
              not(Bool = rabbit_msg_store:contains(?PERSISTENT_MSG_STORE, Guid))
      end, false, Guids2ndHalf),
    %% restart empty
    ok = stop_msg_store(),
    ok = start_msg_store_empty(),
    %% check we don't contain any of the msgs
    false = msg_store_contains(false, Guids),
    %% publish the first half again
    MSCState8 = rabbit_msg_store:client_init(?PERSISTENT_MSG_STORE, Ref),
    {ok, MSCState9} = msg_store_write(Guids1stHalf, MSCState8),
    %% this should force some sort of sync internally otherwise misread
    ok = rabbit_msg_store:client_terminate(
           msg_store_read(Guids1stHalf, MSCState9)),
    ok = rabbit_msg_store:remove(?PERSISTENT_MSG_STORE, Guids1stHalf),
    %% restart empty
    ok = stop_msg_store(),
    ok = start_msg_store_empty(), %% now safe to reuse guids
    %% push a lot of msgs in...
    BigCount = 100000,
    GuidsBig = [guid_bin(X) || X <- lists:seq(1, BigCount)],
    Payload = << 0:65536 >>,
    ok = rabbit_msg_store:client_terminate(
           lists:foldl(
             fun (Guid, MSCStateN) ->
                     {ok, MSCStateM} =
                         rabbit_msg_store:write(?PERSISTENT_MSG_STORE, Guid, Payload, MSCStateN),
                     MSCStateM
             end, rabbit_msg_store:client_init(?PERSISTENT_MSG_STORE, Ref), GuidsBig)),
    %% now read them to ensure we hit the fast client-side reading
    ok = rabbit_msg_store:client_terminate(
           lists:foldl(
             fun (Guid, MSCStateM) ->
                     {{ok, Payload}, MSCStateN} =
                         rabbit_msg_store:read(?PERSISTENT_MSG_STORE, Guid, MSCStateM),
                     MSCStateN
             end, rabbit_msg_store:client_init(?PERSISTENT_MSG_STORE, Ref), GuidsBig)),
    %% .., then 3s by 1...
    ok = lists:foldl(
           fun (Guid, ok) ->
                   rabbit_msg_store:remove(?PERSISTENT_MSG_STORE, [guid_bin(Guid)])
           end, ok, lists:seq(BigCount, 1, -3)),
    %% .., then remove 3s by 2, from the young end first. This hits
    %% GC (under 50% good data left, but no empty files. Must GC).
    ok = lists:foldl(
           fun (Guid, ok) ->
                   rabbit_msg_store:remove(?PERSISTENT_MSG_STORE, [guid_bin(Guid)])
           end, ok, lists:seq(BigCount-1, 1, -3)),
    %% .., then remove 3s by 3, from the young end first. This hits
    %% GC...
    ok = lists:foldl(
           fun (Guid, ok) ->
                   rabbit_msg_store:remove(?PERSISTENT_MSG_STORE, [guid_bin(Guid)])
           end, ok, lists:seq(BigCount-2, 1, -3)),
    %% ensure empty
    false = msg_store_contains(false, GuidsBig),
    %% restart empty
    ok = stop_msg_store(),
    ok = start_msg_store_empty(),
    passed.

queue_name(Name) ->
    rabbit_misc:r(<<"/">>, queue, term_to_binary(Name)).

test_queue() ->
    queue_name(test).

empty_test_queue() ->
    ok = rabbit_variable_queue:start([]),
    {0, _Terms, Qi1} = test_queue_init(),
    _Qi2 = rabbit_queue_index:terminate_and_erase(Qi1),
    ok.

queue_index_publish(SeqIds, Persistent, Qi) ->
    Ref = rabbit_guid:guid(),
    MsgStore = case Persistent of
                   true  -> ?PERSISTENT_MSG_STORE;
                   false -> ?TRANSIENT_MSG_STORE
               end,
    {A, B, MSCStateEnd} =
        lists:foldl(
          fun (SeqId, {QiN, SeqIdsGuidsAcc, MSCStateN}) ->
                  Guid = rabbit_guid:guid(),
                  QiM = rabbit_queue_index:publish(
                          Guid, SeqId, Persistent, QiN),
                  {ok, MSCStateM} = rabbit_msg_store:write(MsgStore, Guid,
                                                           Guid, MSCStateN),
                  {QiM, [{SeqId, Guid} | SeqIdsGuidsAcc], MSCStateM}
          end, {Qi, [], rabbit_msg_store:client_init(MsgStore, Ref)}, SeqIds),
    ok = rabbit_msg_store:delete_client(MsgStore, Ref),
    ok = rabbit_msg_store:client_terminate(MSCStateEnd),
    {A, B}.

queue_index_deliver(SeqIds, Qi) ->
    lists:foldl(fun (SeqId, QiN) -> rabbit_queue_index:deliver(SeqId, QiN) end,
                Qi, SeqIds).

queue_index_flush(Qi) ->
    rabbit_queue_index:flush(Qi).

verify_read_with_published(_Delivered, _Persistent, [], _) ->
    ok;
verify_read_with_published(Delivered, Persistent,
                           [{Guid, SeqId, Persistent, Delivered}|Read],
                           [{SeqId, Guid}|Published]) ->
    verify_read_with_published(Delivered, Persistent, Read, Published);
verify_read_with_published(_Delivered, _Persistent, _Read, _Published) ->
    ko.

test_queue_init() ->
    rabbit_queue_index:init(
      test_queue(), false,
      fun (Guid) ->
              rabbit_msg_store:contains(?PERSISTENT_MSG_STORE, Guid)
      end).

test_queue_index() ->
    SegmentSize = rabbit_queue_index:next_segment_boundary(0),
    TwoSegs = SegmentSize + SegmentSize,
    stop_msg_store(),
    ok = empty_test_queue(),
    SeqIdsA = lists:seq(0,9999),
    SeqIdsB = lists:seq(10000,19999),
    {0, _Terms, Qi0} = test_queue_init(),
    {0, 0, Qi1} = rabbit_queue_index:bounds(Qi0),
    {Qi2, SeqIdsGuidsA} = queue_index_publish(SeqIdsA, false, Qi1),
    {0, SegmentSize, Qi3} = rabbit_queue_index:bounds(Qi2),
    {ReadA, undefined, Qi4} = rabbit_queue_index:read(0, SegmentSize, Qi3),
    ok = verify_read_with_published(false, false, ReadA,
                                    lists:reverse(SeqIdsGuidsA)),
    %% call terminate twice to prove it's idempotent
    _Qi5 = rabbit_queue_index:terminate([], rabbit_queue_index:terminate([], Qi4)),
    ok = stop_msg_store(),
    ok = rabbit_variable_queue:start([test_queue()]),
    %% should get length back as 0, as all the msgs were transient
    {0, _Terms1, Qi6} = test_queue_init(),
    {0, 0, Qi7} = rabbit_queue_index:bounds(Qi6),
    {Qi8, SeqIdsGuidsB} = queue_index_publish(SeqIdsB, true, Qi7),
    {0, TwoSegs, Qi9} = rabbit_queue_index:bounds(Qi8),
    {ReadB, undefined, Qi10} = rabbit_queue_index:read(0, SegmentSize, Qi9),
    ok = verify_read_with_published(false, true, ReadB,
                                    lists:reverse(SeqIdsGuidsB)),
    _Qi11 = rabbit_queue_index:terminate([], Qi10),
    ok = stop_msg_store(),
    ok = rabbit_variable_queue:start([test_queue()]),
    %% should get length back as 10000
    LenB = length(SeqIdsB),
    {LenB, _Terms2, Qi12} = test_queue_init(),
    {0, TwoSegs, Qi13} = rabbit_queue_index:bounds(Qi12),
    Qi14 = queue_index_deliver(SeqIdsB, Qi13),
    {ReadC, undefined, Qi15} = rabbit_queue_index:read(0, SegmentSize, Qi14),
    ok = verify_read_with_published(true, true, ReadC,
                                    lists:reverse(SeqIdsGuidsB)),
    Qi16 = rabbit_queue_index:ack(SeqIdsB, Qi15),
    Qi17 = queue_index_flush(Qi16),
    %% Everything will have gone now because #pubs == #acks
    {0, 0, Qi18} = rabbit_queue_index:bounds(Qi17),
    _Qi19 = rabbit_queue_index:terminate([], Qi18),
    ok = stop_msg_store(),
    ok = rabbit_variable_queue:start([test_queue()]),
    %% should get length back as 0 because all persistent msgs have been acked
    {0, _Terms3, Qi20} = test_queue_init(),
    _Qi21 = rabbit_queue_index:terminate_and_erase(Qi20),
    ok = stop_msg_store(),
    ok = empty_test_queue(),

    %% These next bits are just to hit the auto deletion of segment files.
    %% First, partials:
    %% a) partial pub+del+ack, then move to new segment
    SeqIdsC = lists:seq(0,trunc(SegmentSize/2)),
    {0, _Terms4, Qi22} = test_queue_init(),
    {Qi23, _SeqIdsGuidsC} = queue_index_publish(SeqIdsC, false, Qi22),
    Qi24 = queue_index_deliver(SeqIdsC, Qi23),
    Qi25 = rabbit_queue_index:ack(SeqIdsC, Qi24),
    Qi26 = queue_index_flush(Qi25),
    {Qi27, _SeqIdsGuidsC1} = queue_index_publish([SegmentSize], false, Qi26),
    _Qi28 = rabbit_queue_index:terminate_and_erase(Qi27),
    ok = stop_msg_store(),
    ok = empty_test_queue(),

    %% b) partial pub+del, then move to new segment, then ack all in old segment
    {0, _Terms5, Qi29} = test_queue_init(),
    {Qi30, _SeqIdsGuidsC2} = queue_index_publish(SeqIdsC, false, Qi29),
    Qi31 = queue_index_deliver(SeqIdsC, Qi30),
    {Qi32, _SeqIdsGuidsC3} = queue_index_publish([SegmentSize], false, Qi31),
    Qi33 = rabbit_queue_index:ack(SeqIdsC, Qi32),
    Qi34 = queue_index_flush(Qi33),
    _Qi35 = rabbit_queue_index:terminate_and_erase(Qi34),
    ok = stop_msg_store(),
    ok = empty_test_queue(),

    %% c) just fill up several segments of all pubs, then +dels, then +acks
    SeqIdsD = lists:seq(0,SegmentSize*4),
    {0, _Terms6, Qi36} = test_queue_init(),
    {Qi37, _SeqIdsGuidsD} = queue_index_publish(SeqIdsD, false, Qi36),
    Qi38 = queue_index_deliver(SeqIdsD, Qi37),
    Qi39 = rabbit_queue_index:ack(SeqIdsD, Qi38),
    Qi40 = queue_index_flush(Qi39),
    _Qi41 = rabbit_queue_index:terminate_and_erase(Qi40),
    ok = stop_msg_store(),
    ok = rabbit_variable_queue:start([]),
    ok = stop_msg_store(),
    passed.

variable_queue_publish(IsPersistent, Count, VQ) ->
    lists:foldl(
      fun (_N, VQN) ->
              rabbit_variable_queue:publish(
                rabbit_basic:message(
                  rabbit_misc:r(<<>>, exchange, <<>>),
                  <<>>, #'P_basic'{delivery_mode =
                                       case IsPersistent of
                                           true  -> 2;
                                           false -> 1
                                       end}, <<>>), VQN)
      end, VQ, lists:seq(1, Count)).

variable_queue_fetch(Count, IsPersistent, IsDelivered, Len, VQ) ->
    lists:foldl(fun (N, {VQN, AckTagsAcc}) ->
                        Rem = Len - N,
                        {{#basic_message { is_persistent = IsPersistent },
                          IsDelivered, AckTagN, Rem}, VQM} =
                            rabbit_variable_queue:fetch(true, VQN),
                        {VQM, [AckTagN | AckTagsAcc]}
                end, {VQ, []}, lists:seq(1, Count)).

assert_prop(List, Prop, Value) ->
    Value = proplists:get_value(Prop, List).

fresh_variable_queue() ->
    stop_msg_store(),
    ok = empty_test_queue(),
    VQ = rabbit_variable_queue:init(test_queue(), true, false),
    S0 = rabbit_variable_queue:status(VQ),
    assert_prop(S0, len, 0),
    assert_prop(S0, q1, 0),
    assert_prop(S0, q2, 0),
    assert_prop(S0, delta, {delta, undefined, 0, undefined}),
    assert_prop(S0, q3, 0),
    assert_prop(S0, q4, 0),
    VQ.

test_variable_queue() ->
    passed = test_variable_queue_dynamic_duration_change(),
    passed = test_variable_queue_partial_segments_delta_thing(),
    passed.

test_variable_queue_dynamic_duration_change() ->
    SegmentSize = rabbit_queue_index:next_segment_boundary(0),
    VQ0 = fresh_variable_queue(),
    %% start by sending in a couple of segments worth
    Len1 = 2*SegmentSize,
    VQ1 = variable_queue_publish(false, Len1, VQ0),
    {_Duration, VQ2} = rabbit_variable_queue:ram_duration(VQ1),
    {ok, _TRef} = timer:send_after(1000, {duration, 60,
                                          fun (V) -> (V*0.75)-1 end}),
    VQ3 = test_variable_queue_dynamic_duration_change_f(Len1, VQ2),
    {VQ4, AckTags} = variable_queue_fetch(Len1, false, false, Len1, VQ3),
    VQ5 = rabbit_variable_queue:ack(AckTags, VQ4),
    {empty, VQ6} = rabbit_variable_queue:fetch(true, VQ5),

    %% just publish and fetch some persistent msgs, this hits the the
    %% partial segment path in queue_index due to the period when
    %% duration was 0 and the entire queue was delta.
    VQ7 = variable_queue_publish(true, 20, VQ6),
    {VQ8, AckTags1} = variable_queue_fetch(20, true, false, 20, VQ7),
    VQ9 = rabbit_variable_queue:ack(AckTags1, VQ8),
    VQ10 = rabbit_variable_queue:handle_pre_hibernate(VQ9),
    {empty, VQ11} = rabbit_variable_queue:fetch(true, VQ10),

    rabbit_variable_queue:terminate(VQ11),

    passed.

test_variable_queue_dynamic_duration_change_f(Len, VQ0) ->
    VQ1 = variable_queue_publish(false, 1, VQ0),
    {{_Msg, false, AckTag, Len}, VQ2} = rabbit_variable_queue:fetch(true, VQ1),
    VQ3 = rabbit_variable_queue:ack([AckTag], VQ2),
    receive
        {duration, _, stop} ->
            VQ3;
        {duration, N, Fun} ->
            N1 = lists:max([Fun(N), 0]),
            Fun1 = case N1 of
                       0               -> fun (V) -> (V+1)/0.75 end;
                       _ when N1 > 400 -> stop;
                       _               -> Fun
                   end,
            {ok, _TRef} = timer:send_after(1000, {duration, N1, Fun1}),
            {_Duration, VQ4} = rabbit_variable_queue:ram_duration(VQ3),
            VQ5 = %% /37 otherwise the duration is just to high to stress things
                rabbit_variable_queue:set_ram_duration_target(N/37, VQ4),
            io:format("~p:~n~p~n~n", [N, rabbit_variable_queue:status(VQ5)]),
            test_variable_queue_dynamic_duration_change_f(Len, VQ5)
    after 0 ->
            test_variable_queue_dynamic_duration_change_f(Len, VQ3)
    end.

test_variable_queue_partial_segments_delta_thing() ->
    SegmentSize = rabbit_queue_index:next_segment_boundary(0),
    HalfSegment = SegmentSize div 2,
    VQ0 = fresh_variable_queue(),
    VQ1 = variable_queue_publish(true, SegmentSize + HalfSegment, VQ0),
    {_Duration, VQ2} = rabbit_variable_queue:ram_duration(VQ1),
    VQ3 = rabbit_variable_queue:set_ram_duration_target(0, VQ2),
    %% one segment in q3 as betas, and half a segment in delta
    S3 = rabbit_variable_queue:status(VQ3),
    io:format("~p~n", [S3]),
    assert_prop(S3, delta, {delta, SegmentSize, HalfSegment,
                            SegmentSize + HalfSegment}),
    assert_prop(S3, q3, SegmentSize),
    assert_prop(S3, len, SegmentSize + HalfSegment),
    VQ4 = rabbit_variable_queue:set_ram_duration_target(infinity, VQ3),
    VQ5 = variable_queue_publish(true, 1, VQ4),
    %% should have 1 alpha, but it's in the same segment as the deltas
    S5 = rabbit_variable_queue:status(VQ5),
    io:format("~p~n", [S5]),
    assert_prop(S5, q1, 1),
    assert_prop(S5, delta, {delta, SegmentSize, HalfSegment,
                            SegmentSize + HalfSegment}),
    assert_prop(S5, q3, SegmentSize),
    assert_prop(S5, len, SegmentSize + HalfSegment + 1),
    {VQ6, AckTags} = variable_queue_fetch(SegmentSize, true, false,
                                          SegmentSize + HalfSegment + 1, VQ5),
    %% the half segment should now be in q3 as betas
    S6 = rabbit_variable_queue:status(VQ6),
    io:format("~p~n", [S6]),
    assert_prop(S6, delta, {delta, undefined, 0, undefined}),
    assert_prop(S6, q1, 1),
    assert_prop(S6, q3, HalfSegment),
    assert_prop(S6, len, HalfSegment + 1),
    {VQ7, AckTags1} = variable_queue_fetch(HalfSegment + 1, true, false,
                                           HalfSegment + 1, VQ6),
    VQ8 = rabbit_variable_queue:ack(AckTags ++ AckTags1, VQ7),
    %% should be empty now
    {empty, VQ9} = rabbit_variable_queue:fetch(true, VQ8),
    rabbit_variable_queue:terminate(VQ9),

    passed.
