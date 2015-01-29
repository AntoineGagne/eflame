-module(eflame).

-export([
    apply/5
]).

-define(RESOLUTION, 100).

-record(dump, {
    stack = [],
    us = 0,
    acc = []
}).

%% public
apply(Mode, OutputFile, M, F, A) ->
    Tracer = spawn_tracer(),

    start_trace(Tracer, self(), Mode),
    Return = (catch erlang:apply(M, F, A)),
    case stop_trace(Tracer, self()) of
        {ok, Bytes} ->
            ok = file:write_file(OutputFile, Bytes);
        {error, timeout} ->
            ok = file:write_file(OutputFile, <<>>)
    end,
    Return.

%% private
dump_to_iolist(Pid, #dump {acc = Acc}) ->
    [[pid_to_list(Pid), <<";">>, stack_collapse(S), <<"\n">>] || S <- lists:reverse(Acc)].

entry_to_iolist({M, F, A}) ->
    [atom_to_binary(M, utf8), <<":">>, atom_to_binary(F, utf8), <<"/">>, integer_to_list(A)];
entry_to_iolist(A) when is_atom(A) ->
    [atom_to_binary(A, utf8)].

intercalate(Sep, Xs) -> lists:concat(intersperse(Sep, Xs)).

intersperse(_, []) -> [];
intersperse(_, [X]) -> [X];
intersperse(Sep, [X | Xs]) -> [X, Sep | intersperse(Sep, Xs)].

new_state(#dump {
        us = Us,
        acc = Acc
    } = State, Stack, Ts) ->

    UsTs = us(Ts),
    case Us of
        0 -> State#dump {
            us = UsTs,
            stack = Stack
        };
        _ when Us > 0 ->
            Diff = us(Ts) - Us,
            NOverlaps = Diff div ?RESOLUTION,
            Overlapped = NOverlaps * ?RESOLUTION,

            case NOverlaps of
                X when X >= 1 ->
                    StackRev = lists:reverse(Stack),
                    Stacks = [StackRev || _ <- lists:seq(1, NOverlaps)],
                    State#dump {
                        us = Us + Overlapped,
                        acc = lists:append(Stacks, Acc),
                        stack = Stack
                    };
                _ ->
                    State#dump {stack = Stack}
            end
    end.

spawn_tracer() -> spawn(fun() -> trace_listener(dict:new()) end).

stack_collapse(Stack) ->
    intercalate(";", [entry_to_iolist(S) || S <- Stack]).

start_trace(Tracer, Target, Mode) ->
    MatchSpec = [{'_', [], [{message, {{cp, {caller}}}}]}],
    erlang:trace_pattern(on_load, MatchSpec, [local]),
    erlang:trace_pattern({'_', '_', '_'}, MatchSpec, [local]),
    erlang:trace(Target, true, [{tracer, Tracer} | trace_flags(Mode)]),
    ok.

stop_trace(Tracer, Target) ->
    erlang:trace(Target, false, [all]),
    Tracer ! {dump_bytes, self()},

    Return = receive {bytes, B} -> {ok, B}
    after 10000 ->
        {error, timeout}
    end,

    exit(Tracer, normal),
    Return.

trace_flags(normal) ->
    [call, arity, return_to, timestamp, running];
trace_flags(normal_with_children) ->
    [call, arity, return_to, timestamp, running, set_on_spawn].

trace_listener(State) ->
    receive
        {dump_bytes, Pid} ->
            Bytes = iolist_to_binary([dump_to_iolist(TPid, Dump) || {TPid, [Dump]} <- dict:to_list(State)]),
            Pid ! {bytes, Bytes};
        Term ->
            lager:info("~p~n", [Term]),
            trace_ts = element(1, Term),
            Pid = element(2, Term),

            PidState2 = case dict:find(Pid, State) of
                {ok, [PidState]} -> PidState;
                error -> #dump {}
            end,

            PidState3 = trace_proc_stream(Term, PidState2),
            lager:info("~p~n", [PidState3#dump.stack]),

            State2 = dict:erase(Pid, State),
            State3 = dict:append(Pid, PidState3, State2),
            trace_listener(State3)
    end.

% call
trace_proc_stream({trace_ts, _Ps, call, MFA, {cp, {_, _, _} = CallerMFA}, Ts}, #dump {stack = []} = State) ->
    new_state(State, [MFA, CallerMFA], Ts);

trace_proc_stream({trace_ts, _Ps, call, MFA, {cp, undefined}, Ts}, #dump {stack = []} = State) ->
    new_state(State, [MFA], Ts);

trace_proc_stream({trace_ts, _Ps, call, MFA, {cp, MFA}, Ts}, #dump {stack = [MFA | Stack]} = State) ->
    new_state(State, [MFA | Stack], Ts);

trace_proc_stream({trace_ts, _Ps, call, MFA, {cp, CpMFA}, Ts}, #dump {stack = [CpMFA | Stack]} = State) ->
    new_state(State, [MFA, CpMFA | Stack], Ts);

trace_proc_stream({trace_ts, _Ps, call, MFA, {cp, undefined}, Ts}, #dump {stack = Stack} = State) ->
    new_state(State, [MFA | Stack], Ts);

trace_proc_stream({trace_ts, _Ps, call, _MFA, {cp, _}, _Ts} = TraceTs, #dump {stack=[_ | StackRest]} = State) ->
    trace_proc_stream(TraceTs, State#dump {stack = StackRest});

% return_to
trace_proc_stream({trace_ts, _Ps, return_to, MFA, Ts}, #dump {stack = [_Current, MFA | Stack]} = State) ->
    new_state(State, [MFA | Stack], Ts);

trace_proc_stream({trace_ts, _Ps, return_to, undefined, _Ts}, State) ->
    State;

trace_proc_stream({trace_ts, _Ps, return_to, _, _Ts}, State) ->
    State;

% in
trace_proc_stream({trace_ts, _Ps, in, _MFA, Ts}, #dump {stack = [sleep | Stack]} = State) ->
    new_state(new_state(State, [sleep | Stack], Ts), Stack, Ts);

trace_proc_stream({trace_ts, _Ps, in, _MFA, Ts}, #dump {stack = Stack} = State) ->
    new_state(State, Stack, Ts);

% out
trace_proc_stream({trace_ts, _Ps, out, _MFA, Ts}, #dump {stack = Stack} = State) ->
    new_state(State, [sleep | Stack], Ts);

% other
trace_proc_stream(TraceTs, State) ->
    io:format("trace_proc_stream: unknown trace: ~p~n", [TraceTs]),
    State.

us({Mega, Secs, Micro}) ->
    Mega * 1000000 * 1000000 + Secs * 1000000 + Micro.
