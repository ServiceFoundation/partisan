#!/usr/bin/env escript
%%! -pa ./_build/default/lib/jsx/ebin -Wall

main([TraceFile, ReplayTraceFile, CounterexampleConsultFile, RebarCounterexampleConsultFile, PreloadOmissionFile]) ->
    %% Keep track of when test started.
    StartTime = os:timestamp(),

    %% Open ets table.
    ?MODULE = ets:new(?MODULE, [named_table, set]),

    %% Open the trace file.
    {ok, TraceLines} = file:consult(TraceFile),

    %% Open the counterexample consult file:
    %% - we make an assumption that there will only be a single counterexample here.
    {ok, [{TestModule, TestFunction, [TestCommands]}]} = file:consult(CounterexampleConsultFile),

    io:format("Loading commands...~n", []),
    [io:format(" ~p.~n", [TestCommand]) || TestCommand <- TestCommands],

    %% Drop last command -- forced failure.
    TestFinalCommands = lists:reverse(tl(lists:reverse(TestCommands))),

    io:format("Rewritten commands...~n", []),
    [io:format(" ~p.~n", [TestFinalCommand]) || TestFinalCommand <- TestFinalCommands],

    %% Write the schedule out.
    {ok, CounterexampleIo} = file:open(RebarCounterexampleConsultFile, [write, {encoding, utf8}]),
    io:format(CounterexampleIo, "~p.~n", [{TestModule, TestFunction, [TestFinalCommands]}]),
    ok = file:close(CounterexampleIo),

    %% Remove forced failure from the trace.
    TraceLinesWithoutFailure = lists:filter(fun(Command) ->
        case Command of 
            {_, {_, [forced_failure]}} ->
                io:format("Removing command from trace: ~p~n", [Command]),
                false;
            _ ->
                true
        end
    end, hd(TraceLines)),

    %% Filter the trace into message trace lines.
    MessageTraceLines = lists:filter(fun({Type, Message}) ->
        case Type =:= pre_interposition_fun of 
            true ->
                {_TracingNode, InterpositionType, _OriginNode, _MessagePayload} = Message,

                case InterpositionType of 
                    forward_message ->
                        true;
                    _ -> 
                        false
                end;
            false ->
                false
        end
    end, TraceLinesWithoutFailure),
    io:format("Number of items in message trace: ~p~n", [length(MessageTraceLines)]),

    %% Generate the powerset of tracelines.
    MessageTraceLinesPowerset = powerset(MessageTraceLines),
    io:format("Number of message sets in powerset: ~p~n", [length(MessageTraceLinesPowerset)]),

    %% Traces to iterate.
    SortedPowerset = lists:sort(fun(A, B) -> length(A) =< length(B) end, MessageTraceLinesPowerset),

    TracesToIterate = case os:getenv("SUBLIST") of 
        false ->
            lists:reverse(SortedPowerset);
        Other ->
            lists:reverse(lists:sublist(SortedPowerset, list_to_integer(Other)))
    end,

    %% For each trace, write out the preload omission file.
    lists:foldl(fun(Omissions, Iteration) ->
            %% Write out a new omission file from the previously used trace.
            io:format("Writing out new preload omissions file!~n", []),
            {ok, PreloadOmissionIo} = file:open(PreloadOmissionFile, [write, {encoding, utf8}]),
            [io:format(PreloadOmissionIo, "~p.~n", [O]) || O <- [Omissions]],
            ok = file:close(PreloadOmissionIo),

            %% Generate a new trace.
            io:format("Generating new trace based on message omissions (~p omissions): ~n", 
                    [length(Omissions)]),

            {FinalTraceLines, _, _} = lists:foldl(fun({Type, Message} = Line, {FinalTrace0, FaultsStarted0, AdditionalOmissions0}) ->
                case Type =:= pre_interposition_fun of 
                    true ->
                        {TracingNode, InterpositionType, OriginNode, MessagePayload} = Message,

                        case FaultsStarted0 of 
                            true ->
                                %% Once we start omitting, omit everything after that's a message
                                %% send because we don't know what might be coming. In 2PC, if we
                                %% have a successful trace and omit a prepare -- we can't be guaranteed
                                %% to ever see a prepare vote or commmit.
                                {FinalTrace0, FaultsStarted0, AdditionalOmissions0};
                            false ->
                                %% Otherwise, find just the targeted commands to remove.
                                case InterpositionType of 
                                    forward_message ->
                                        case lists:member(Line, Omissions) of 
                                            true ->
                                                %% Sort of hack, just deal with it for now.
                                                ReceiveOmission = {Type, {OriginNode, receive_message, TracingNode, {forward_message, implementation_module(), MessagePayload}}},
                                                {FinalTrace0, true, AdditionalOmissions0 ++ [ReceiveOmission]};
                                            false ->
                                                {FinalTrace0 ++ [Line], FaultsStarted0, AdditionalOmissions0}
                                        end;
                                    receive_message -> 
                                        case lists:member(Line, AdditionalOmissions0) of 
                                            true ->
                                                {FinalTrace0, FaultsStarted0, AdditionalOmissions0 -- [Line]};
                                            false ->
                                                {FinalTrace0 ++ [Line], FaultsStarted0, AdditionalOmissions0}
                                        end
                                end
                        end;
                    false ->
                        {FinalTrace0 ++ [Line], FaultsStarted0, AdditionalOmissions0}
                end
            end, {[], false, []}, TraceLinesWithoutFailure),

            %% Write out replay trace.
            io:format("Writing out new replay trace file!~n", []),
            {ok, TraceIo} = file:open(ReplayTraceFile, [write, {encoding, utf8}]),
            [io:format(TraceIo, "~p.~n", [TraceLine]) || TraceLine <- [FinalTraceLines]],
            ok = file:close(TraceIo),

            %% Run the trace.
            Command = "rm -rf priv/lager; SHRINKING=true REPLAY=true PRELOAD_OMISSIONS_FILE=" ++ PreloadOmissionFile ++ " REPLAY_TRACE_FILE=" ++ ReplayTraceFile ++ " TRACE_FILE=" ++ TraceFile ++ " ./rebar3 proper --retry | tee /tmp/partisan.output",
            io:format("Executing command for iteration ~p of ~p:", [Iteration, length(TracesToIterate)]),
            io:format(" ~p~n", [Command]),
            Output = os:cmd(Command),

            %% Store set of omissions as omissions that didn't invalidate the execution.
            case string:find(Output, "{postcondition,false}") of 
                nomatch ->
                    %% This passed.
                    io:format("Test passed.~n", []),

                    %% Insert result into the ETS table.
                    true = ets:insert(?MODULE, {Iteration, {Iteration, FinalTraceLines, Omissions, true}});
                _ ->
                    %% This failed.
                    io:format("Test FAILED!~n", []),

                    %% Insert result into the ETS table.
                    true = ets:insert(?MODULE, {Iteration, {Iteration, FinalTraceLines, Omissions, false}})
            end,

            %% Bump iteration.
            Iteration + 1
    end, 1, TracesToIterate),

    io:format("Identifying witnesses...~n", []),

    %% Once we finished, we need to compute the minimals.
    Witnesses = ets:foldl(fun({_, {Iteration, FinalTraceLines, _Omissions, Status} = Candidate}, Witnesses1) ->
        io:format("=> looking at iteration ~p~n", [Iteration]),

        %% For each trace that passes.
        case Status of 
            true ->
                %% Ensure all supertraces also pass.
                AllSupertracesPass = ets:foldl(fun({_, {_Iteration1, FinalTraceLines1, _Omissions1, Status1}}, AllSupertracesPass1) ->
                    case is_supertrace(FinalTraceLines1, FinalTraceLines) of
                        true ->
                            io:format("=> => found supertrace, status: ~p~n", [Status1]),
                            Status1 andalso AllSupertracesPass1;
                        false ->
                            AllSupertracesPass1
                    end
                end, true, ?MODULE),

                io:format("=> ~p, all_super_traces_passing? ~p~n", [Iteration, AllSupertracesPass]),

                case AllSupertracesPass of 
                    true ->
                        Witnesses1 ++ [Candidate];
                    false ->
                        Witnesses1
                end;
            false ->
                %% If it didn't pass, it can't be a witness.
                Witnesses1
        end
    end, [], ?MODULE),

    io:format("Checking for minimal witnesses...~n", []),

    %% Identify minimal.
    MinimalWitnesses = lists:foldl(fun({Iteration, FinalTraceLines, Omissions, Status} = Witness, MinimalWitnesses) ->
        io:format("=> looking at iteration ~p~n", [Iteration]),

        %% See if any of the traces are subtraces of this.
        StillMinimal = lists:foldl(fun({Iteration1, FinalTraceLines1, Omissions1, Status1}, StillMinimal1) ->
            %% Is this other trace a subtrace of me?  If so, discard us
            case is_subtrace(FinalTraceLines1, FinalTraceLines) andalso Iteration =/= Iteration1 of 
                true ->
                    io:format("=> => found subtrace in iteration: ~p, status: ~p~n", [Iteration1, Status1]),
                    StillMinimal1 andalso false;
                false ->
                    StillMinimal1
            end
        end, true, Witnesses),

        io:format("=> ~p, still_minimal? ~p~n", [Iteration, StillMinimal]),

        case StillMinimal of 
            true ->
                MinimalWitnesses ++ [Witness];
            false ->
                MinimalWitnesses
        end
    end, [], Witnesses),

    %% Test finished time.
    EndTime = os:timestamp(),
    Difference = timer:now_diff(EndTime, StartTime),
    DifferenceMs = Difference / 1000,
    DifferenceSec = DifferenceMs / 1000,

    io:format("Test started: ~p~n", [StartTime]),
    io:format("Test ended: ~p~n", [EndTime]),
    io:format("Test took: ~p seconds.~n", [DifferenceSec]),

    ok.

%% @doc Generate the powerset of messages.
powerset([]) -> 
    [[]];

powerset([H|T]) -> 
    PT = powerset(T),
    [ [H|X] || X <- PT ] ++ PT.

%% @private
implementation_module() ->
    case os:getenv("IMPLEMENTATION_MODULE") of 
        false ->
            exit({error, no_implementation_module_specified});
        Other ->
            list_to_atom(Other)
    end.

%% @private
is_supertrace(Trace1, Trace2) ->
    %% Trace1 is a supertrace if Trace2 is a prefix of Trace1.
    %% Contiguous, ordered.
    lists:prefix(Trace2, Trace1).

%% @private
is_subtrace(Trace1, Trace2) ->
    %% Remove all elements from T2 not in T1 to make traces comparable.
    FilteredTrace2 = lists:filter(fun(T2) -> lists:member(T2, Trace1) end, Trace2),

    %% Now, is the first trace a prefix?  If so, it's a subtrace.
    lists:prefix(Trace1, FilteredTrace2).