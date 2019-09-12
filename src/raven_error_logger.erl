-module(raven_error_logger).
-include("raven.hrl").
-include("raven_error_logger.hrl").
-behaviour(gen_event).
-export([
    init/1,
    code_change/3,
    terminate/2,
    handle_call/2,
    handle_event/2,
    handle_info/2
]).

-record(config, {
    logging_level = warning :: logging_level(),
    filter = undefined :: module()
}).

init(_) ->
    {ok, []}.

handle_call(_, State) ->
    {ok, ok, State}.

handle_event({error, _, {Pid, Format, Data}}, State) ->
    capture(parse_message(error, Pid, Format, Data)),
    {ok, State};
handle_event({error_report, _, {Pid, Type, Report}}, State) ->
    case should_send_report(Type, Report) of
        true ->
            {Message, Details} = parse_report(error, Pid, Type, Report),
            raven:capture(Message, Details),
            {ok, State};
        false ->
            {ok, State}
    end;

handle_event({warning_msg, _, {Pid, Format, Data}}, State) ->
    case get_config() of
        #config{logging_level = warning} ->
            {Message, Details} = parse_message(warning, Pid, Format, Data),
            raven:capture(Message, Details),
            {ok, State};
        _ ->
            {ok, State}
    end;
handle_event({warning_report, _, {Pid, Type, Report}}, State) ->
    case {get_config(), should_send_report(Type, Report)} of
        {#config{logging_level = warning}, true}->
            {Message, Details} = parse_report(warning, Pid, Type, Report),
            raven:capture(Message, Details),
            {ok, State};
        _ ->
            {ok, State}
    end;

handle_event(_, State) ->
    {ok, State}.

handle_info(_, State) ->
    {ok, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, _) ->
    ok.

%% @private
capture(mask) ->
    ok;
capture({Message, Details}) ->
    raven:capture(Message, Details).

%% @private
-spec get_config() -> #config{}.
get_config() ->
    Default = #config{},
    case application:get_env(?APP, error_logger_config) of
        {ok, Options} when is_list(Options) ->
            #config{
                logging_level =
                    proplists:get_value(level,
                                        Options,
                                        Default#config.logging_level),
                filter =
                    proplists:get_value(filter,
                                        Options,
                                        Default#config.filter)
            };
        undefined ->
            Default
    end.


%% @private
parse_message(error = Level, Pid, "** Generic server " ++ _, [Name, LastMessage, State, Reason]) ->
    %% gen_server terminate
    {Exception, Stacktrace} = parse_reason(Reason),
    {format_exit(gen_server, Name, Reason), [
        {level, Level},
        {exception, Exception},
        {stacktrace, Stacktrace},
        {extra, [
            {name, Name},
            {pid, Pid},
            {last_message, LastMessage},
            {state, State},
            {reason, Reason}
        ]}
    ]};
%% OTP 20 crash reports where the client pid is dead don't include the stacktrace
parse_message(error = Level, Pid, "** Generic server " ++ _, [Name, LastMessage, State, Reason, Client]) ->
	%% gen_server terminate
	{Exception, Stacktrace} = parse_reason(Reason),
	{format_exit(gen_server, Name, Reason), [
		{level, Level},
		{exception, Exception},
		{stacktrace, Stacktrace},
		{extra, [
			{name, Name},
			{pid, Pid},
			{last_message, LastMessage},
			{state, State},
			{reason, Reason},
			{client, Client}
		]}
	]};
%% OTP 20 crash reports contain the pid of the client and stacktrace
parse_message(error = Level, Pid, "** Generic server " ++ _, [Name, LastMessage, State, Reason, Client, ClientStacktrace]) ->
	%% gen_server terminate
	{Exception, Stacktrace} = parse_reason(Reason),
	{format_exit(gen_server, Name, Reason), [
		{level, Level},
		{exception, Exception},
		{stacktrace, Stacktrace},
		{extra, [
			{name, Name},
			{pid, Pid},
			{last_message, LastMessage},
			{state, State},
			{reason, Reason},
			{client, Client},
			{client_stacktrace, ClientStacktrace}
		]}
	]};
parse_message(error = Level, Pid, "** State machine " ++ _, [Name, LastMessage, StateName, State, Reason]) ->
    %% gen_fsm terminate
    {Exception, Stacktrace} = parse_reason(Reason),
    {format_exit(gen_fsm, Name, Reason), [
        {level, Level},
        {exception, Exception},
        {stacktrace, Stacktrace},
        {extra, [
            {name, Name},
            {pid, Pid},
            {last_message, LastMessage},
            {state, State},
            {state_name, StateName},
            {reason, Reason}
        ]}
    ]};
parse_message(error = Level, Pid, "** State machine " ++ _, [Name, LastEvent, {StateName, StateData}, Class, Reason, CallbackMode, Stacktrace]) ->
	%% gen_statem terminate
	{format_exit(gen_statem, Name, Reason), [
		{level, Level},
		{exception, {Class, Reason}},
		{stacktrace, Stacktrace},
		{extra, [
			{name, Name},
			{pid, Pid},
			{last_event, LastEvent},
			{state_name, StateName},
			{state_data, StateData},
			{callback_mode, CallbackMode},
			{reason, Reason}
		]}
	]};
parse_message(error = Level, Pid, "** State machine " ++ _, [Name, LastEvent, [{StateName, StateData}], Class, Reason, CallbackMode, Stacktrace]) ->
	%% gen_statem terminate
	%% sometimes gen_statem wraps its statename/data in a list for some reason???
	{format_exit(gen_statem, Name, Reason), [
		{level, Level},
		{exception, {Class, Reason}},
		{stacktrace, Stacktrace},
		{extra, [
			{name, Name},
			{pid, Pid},
			{last_event, LastEvent},
			{state_name, StateName},
			{state_data, StateData},
			{callback_mode, CallbackMode},
			{reason, Reason}
		]}
	]};
parse_message(_Level, _Pid, "** gen_event handler " ++ _, [error_logger_lager_h, error_logger, _LastMessage, _State, _Reason]) ->
    mask;
parse_message(error = Level, Pid, "** gen_event handler " ++ _, [ID, Name, LastMessage, State, Reason]) ->
    %% gen_event terminate
    {Exception, Stacktrace} = parse_reason(Reason),
    {format_exit(gen_event, Name, Reason), [
        {level, Level},
        {exception, Exception},
        {stacktrace, Stacktrace},
        {extra, [
            {id, ID},
            {name, Name},
            {pid, Pid},
            {last_message, LastMessage},
            {state, State},
            {reason, Reason}
        ]}
    ]};
parse_message(error = Level, Pid, "** Generic process " ++ _, [Name, LastMessage, State, Reason]) ->
    %% gen_process terminate
    {Exception, Stacktrace} = parse_reason(Reason),
    {format_exit(gen_process, Name, Reason), [
        {level, Level},
        {exception, Exception},
        {stacktrace, Stacktrace},
        {extra, [
            {name, Name},
            {pid, Pid},
            {last_message, LastMessage},
            {state, State},
            {reason, Reason}
        ]}
    ]};
parse_message(error = Level, Pid, "Error in process " ++ _,
              [Name, Node, [ {reason, Reason}
                           , {mfa, {Handler, _, _}}
                           , {stacktrace, Stacktrace}
                           | Extras ]]) ->
	%% cowboy_handler terminate
	{format_exit(process, Name, {Reason, Stacktrace}), [
		{level, Level},
		{exception, {exit, Reason}},
		{stacktrace, Stacktrace},
		{extra, [
			{name, Name},
			{pid, Pid},
			{node, Node},
			{handler, Handler} | Extras
		]}
    ]};
parse_message(error = Level, Pid, "Error in process " ++ _, [Name, Node, Reason]) ->
    %% process terminate
    {Exception, Stacktrace} = parse_reason(Reason),
    {format_exit(process, Name, Reason), [
        {level, Level},
        {exception, Exception},
        {stacktrace, Stacktrace},
        {extra, [
            {name, Name},
            {pid, Pid},
            {node, Node},
            {reason, Reason}
        ]}
    ]};
parse_message(_Level, _Pid, "Ranch listener " ++ _, _) ->
    mask;
%% --- General ---
parse_message(Level, Pid, "Error: ~p" ++ _ = Format, [{failed, _Reason} = Exception | _] = Data) ->
	{format(Format, Data), [
		{level, Level},
		{exception, Exception},
		{extra, [
			{pid, Pid}
		]}
	]};
parse_message(Level, Pid, "Error: ~p" ++ _ = Format, [{failed, Reason, Extras} | Rest])
		when is_list(Extras) ->
	{format(Format, [{failed, Reason} | Rest]), [
		{level, Level},
		{exception, {failed, Reason}},
		{extra, [
			{pid, Pid} |
			[ {Key, Value} || {Key, Value} <- Extras, is_atom(Key) ]
		]}
	]};
parse_message(Level, Pid, "Exception: ~p\n"
						  "Extras: ~p" = Format,
			  [{{Class, Reason}, [{_, _, _, _} | _] = Stacktrace}, Extras])
		when Class =:= exit; Class =:= error; Class =:= throw ->
	{format(Format, [{Class, Reason}, Extras]), [
		{level, Level},
		{exception, {Class, Reason}},
		{stacktrace, Stacktrace},
		{extra, [
			{pid, Pid} | [ {Key, Value} || {Key, Value} <- Extras, is_atom(Key) ]
		]}
	]};
%% --- Brod ---
parse_message(_Level, Pid, "Produce error ~s-~B Offset: ~B Error: ~p" = Format,
			  [Topic, _Partition, _Offset, ErrorCode] = Data) ->
	Extra = "\nRetriable errors will be retried, actual failures will result in "
			"an exit. Look for 'producer_down'.",
	{format(Format ++ Extra, Data), [
		{level, warning},
		{exception, {failed, {brod, produce, Topic, ErrorCode}}},
		{extra, [
			{pid, Pid},
			{data, Data}
		]}
	]};
parse_message(Level, Pid, "~p [~p] ~p is terminating\nreason: ~p~n" = Format,
	          [_Module, _Pid, _ClientId, Reason] = Data) ->
	{Exception, Stacktrace} = parse_reason(Reason),
	{format(Format, Data), [
		{level, Level},
		{exception, Exception},
		{stacktrace, Stacktrace},
		{extra, [
			{pid, Pid},
			{data, Data}
		]}
	]};
parse_message(Level, Pid, "~p ~p terminating, reason:\n~p" = Format,
	          [_Module, _Pid, Reason] = Data) ->
	{format(Format, Data), [
		{level, Level},
		{exception, {exit, Reason}},
		{extra, [
			{pid, Pid},
			{data, Data}
		]}
	]};
parse_message(error = Level, Pid, "** Task " ++ _, [TaskPid, RefPid, Fun, FunArgs, Reason]) ->
  {Exception, Stacktrace} = parse_reason(Reason),
    {format_exit("Task", TaskPid, Reason), [
        {level, Level},
        {exception, Exception},
        {stacktrace, Stacktrace},
        {extra, [
            {pid, Pid},
            {parent_pid, RefPid},
            {function, Fun},
            {function_args, FunArgs}
        ]}
    ]};
parse_message(Level, Pid, Format, Data) ->
    {format(Format, Data), [
        {level, Level},
        {extra, [
            {pid, Pid},
            {data, Data}
        ]}
    ]}.


%% @private
-spec should_send_report(report_type(), error_logger:report()) -> boolean().
should_send_report(supervisor_report, Report) ->
    #config{filter = Mod} = get_config(),
    case Mod of
        undefined -> true;
        _ ->
            Mod:should_send_supervisor_report(
                proplists:get_value(supervisor, Report),
                proplists:get_value(reason, Report),
                proplists:get_value(errorContext, Report)
            )
    end;
should_send_report(crash_report, Report) ->
    #config{filter = Mod} = get_config(),
    case Mod of
        undefined -> true;
        _ ->
            Mod:should_send_crash_report(Report)
    end.

%% @private
parse_report(Level, Pid, Type, Report) ->
    case {Level, Type} of
        {_, crash_report} when is_list(Report) ->
            parse_crash_report(
                Level,
                Pid,
                Report
            );
        {_, supervisor_report} when is_list(Report) ->
            parse_supervisor_report(
                Level,
                Pid,
                proplists:get_value(errorContext, Report),
                proplists:get_value(offender, Report),
                proplists:get_value(reason, Report),
                proplists:get_value(supervisor, Report)
            );
        {info, progress} when is_list(Report) ->
            parse_progress_report(
                Pid,
                proplists:get_value(started, Report),
                proplists:get_value(supervisor, Report)
            );
        {error, std_error} when is_list(Report) ->
            parse_std_error_report(Pid, Report);
        _ ->
            parse_unknown_report(Level, Pid, Type, Report)
    end.


%% @private
parse_crash_report(Level, Pid, [Report, Neighbors]) ->
    Name = case proplists:get_value(registered_name, Report, []) of
        [] -> proplists:get_value(pid, Report);
        N -> N
    end,
    case Name of
        undefined ->
            {<<"Process crashed">>, [
                {level, Level},
                {extra, [
                    {pid, Pid},
                    {neighbors, Neighbors} |
                    Report
                ]}
            ]};
        _ ->
            {Class, R, Trace} = proplists:get_value(error_info, Report, {error, unknown, []}),
            Reason = {{Class, R}, Trace},
            {Exception, Stacktrace} = parse_reason(Reason),
            {format_exit("Process", Name, Reason), [
                {level, Level},
                {exception, Exception},
                {stacktrace, Stacktrace},
                {extra, [
                    {name, Name},
                    {pid, Pid},
                    {reason, Reason} |
                    Report
                ]}
            ]}
    end.


%% @private
parse_supervisor_report(Level, Pid, Context, Offender, Reason, Supervisor) ->
    {Exception, Stacktrace} = parse_reason(Reason),
    {format("Supervisor ~s had child exit with reason ~s", [format_name(Supervisor), format_reason(Reason)]), [
        {level, Level},
        {logger, supervisors},
        {exception, Exception},
        {stacktrace, Stacktrace},
        {extra, [
            {supervisor, Supervisor},
            {context, Context},
            {pid, Pid},
            {child_pid, proplists:get_value(pid, Offender)},
            {mfa, format_mfa(proplists:get_value(mfargs, Offender))},
            {restart_type, proplists:get_value(restart_type, Offender)},
            {child_type, proplists:get_value(child_type, Offender)},
            {shutdown, proplists:get_value(shutdown, Offender)}
        ]}
    ]}.


%% @private
parse_progress_report(Pid, Started, Supervisor) ->
    Message = case proplists:get_value(name, Started, []) of
        [] -> format("Supervisor ~s started child", [format_name(Supervisor)]);
        Name -> format("Supervisor ~s started ~s", [format_name(Supervisor), format_name(Name)])
    end,
    {Message, [
        {level, info},
        {logger, supervisors},
        {extra, [
            {supervisor, Supervisor},
            {pid, Pid},
            {child_pid, proplists:get_value(pid, Started)},
            {mfa, format_mfa(proplists:get_value(mfargs, Started))},
            {restart_type, proplists:get_value(restart_type, Started)},
            {child_type, proplists:get_value(child_type, Started)},
            {shutdown, proplists:get_value(shutdown, Started)}
        ]}
    ]}.


%% @private
parse_std_error_report(Pid, Report) ->
    Message = case proplists:get_value(message, Report) of
        undefined -> format_string(Report);
        M -> format_string(M)
    end,
    {Toplevel, Extra} = lists:partition(fun
        ({exception, _}) -> true;
        ({stacktrace, _}) -> true;
        (_) -> false
    end, Report),
    {Message, [
        {level, error},
        {extra, [
            {type, std_error},
            {pid, Pid} |
            lists:keydelete(message, 1, Extra)
        ]} |
        Toplevel
    ]}.


%% @private
parse_unknown_report(Level, Pid, Type, Report) ->
  Message = format_string(Report),
    {Message, [
        {level, Level},
        {extra, [
            {type, Type},
            {pid, Pid}
        ]}
    ]}.


%% @private
parse_reason({'function not exported', Stacktrace}) ->
    {{exit, undef}, parse_stacktrace(Stacktrace)};
parse_reason({bad_return, {_MFA, {'EXIT', Reason}}}) ->
    parse_reason(Reason);
parse_reason({bad_return, {MFA, Value}}) ->
    {{exit, {bad_return, Value}}, parse_stacktrace(MFA)};
parse_reason({bad_return_value, Value}) ->
    {{exit, {bad_return, Value}}, []};
parse_reason({{bad_return_value, Value}, MFA}) ->
    {{exit, {bad_return, Value}}, parse_stacktrace(MFA)};
parse_reason({badarg, Stacktrace}) ->
    {{error, badarg}, parse_stacktrace(Stacktrace)};
parse_reason({{badmatch, Value}, Stacktrace}) ->
  {{exit, {badmatch, Value}}, parse_stacktrace(Stacktrace)};
parse_reason({'EXIT', Reason}) ->
    parse_reason(Reason);
parse_reason({Reason, Child}) when is_tuple(Child) andalso element(1, Child) =:= child ->
    parse_reason(Reason);
parse_reason({{Class, Reason}, Stacktrace}) when Class =:= exit; Class =:= error; Class =:= throw ->
    {{Class, Reason}, parse_stacktrace(Stacktrace)};
parse_reason({Reason, Stacktrace}) ->
    case is_elixir() of
        false ->
            {{exit, Reason}, parse_stacktrace(Stacktrace)};
        _ ->
            parse_reason_ex(Reason)
    end;
parse_reason(Reason) ->
    {{exit, Reason}, []}.

%% @private
parse_stacktrace({_, _, _} = MFA) -> [MFA];
parse_stacktrace({_, _, _, _} = MFA) -> [MFA];
parse_stacktrace([{_, _, _} | _] = Trace) -> Trace;
parse_stacktrace([{_, _, _, _} | _] = Trace) -> Trace;
parse_stacktrace(_) -> [].

%% @private
parse_reason_ex({Reason, Stacktrace}) ->
    case 'Elixir.Exception':'exception?'(Reason) of
        false ->
            {{exit, Reason}, parse_stacktrace(Stacktrace)};
        true ->
            {{exit, format_message_ex(Reason)}, parse_stacktrace(Stacktrace)}
    end.

%% @private
format_message_ex(Reason) -> 'Elixir.Exception':message(Reason).

%% @private
%format_stacktrace_ex(Stacktrace) -> 'Elixir.Exception':format_stacktrace(Stacktrace).

%% @private
format_exit(Tag, Name, Reason) when is_pid(Name) ->
    format("~s terminated with reason: ~s", [Tag, format_reason(Reason)]);
format_exit(Tag, Name, Reason) ->
    format("~s ~s terminated with reason: ~s", [Tag, format_name(Name), format_reason(Reason)]).

%% @private
format_name({local, Name}) -> Name;
format_name({global, Name}) -> format_string(Name);
format_name({via, _, Name}) -> format_string(Name);
format_name(Name) -> format_string(Name).

%% @private
format_reason({'function not exported', Trace}) ->
    ["call to undefined function ", format_mfa(Trace)];
format_reason({undef, Trace}) ->
    ["call to undefined function ", format_mfa(Trace)];
format_reason({bad_return, {_MFA, {'EXIT', Reason}}}) ->
    format_reason(Reason);
format_reason({bad_return, {Trace, Val}}) ->
    ["bad return value ", format_term(Val), " from ", format_mfa(Trace)];
format_reason({bad_return_value, Val}) ->
    ["bad return value ", format_term(Val)];
format_reason({{bad_return_value, Val}, Trace}) ->
    ["bad return value ", format_term(Val), " in ", format_mfa(Trace)];
    format_reason({bad_return_from_state_function, Val}) ->
	["bad return value from state function ", format_term(Val)];
format_reason({{bad_return_from_state_function, Val}, Trace}) ->
	["bad return value from state function ", format_term(Val), " in ", format_mfa(Trace)];
format_reason({{badrecord, Record}, Trace}) ->
    ["bad record ", format_term(Record), " in ", format_mfa(Trace)];
format_reason({{case_clause, Value}, Trace}) ->
    ["no case clause matching ", format_term(Value), " in ", format_mfa(Trace)];
format_reason({function_clause, Trace}) ->
    ["no function clause matching ", format_mfa(Trace)];
format_reason({if_clause, Trace}) ->
    ["no true branch found while evaluating if expression in ", format_mfa(Trace)];
format_reason({{try_clause, Value}, Trace}) ->
    ["no try clause matching ", format_term(Value), " in ", format_mfa(Trace)];
format_reason({badarith, Trace}) ->
    ["bad arithmetic expression in ", format_mfa(Trace)];
format_reason({{badmatch, Value}, Trace}) ->
    ["no match of right hand value ", format_term(Value), " in ", format_mfa(Trace)];
format_reason({emfile, _Trace}) ->
    "maximum number of file descriptors exhausted, check ulimit -n";
format_reason({system_limit, [{M, F, _}|_] = Trace}) ->
    Limit = case {M, F} of
        {erlang, open_port} ->
            "maximum number of ports exceeded";
        {erlang, spawn} ->
            "maximum number of processes exceeded";
        {erlang, spawn_opt} ->
            "maximum number of processes exceeded";
        {erlang, list_to_atom} ->
            "tried to create an atom larger than 255, or maximum atom count exceeded";
        {ets, new} ->
            "maximum number of ETS tables exceeded";
        _ ->
            format_mfa(Trace)
    end,
    ["system limit: ", Limit];
format_reason({badarg, Trace}) ->
    ["bad argument in ", format_mfa(Trace)];
format_reason({{badarity, {Fun, Args}}, Trace}) ->
    {arity, Arity} = lists:keyfind(arity, 1, erlang:fun_info(Fun)),
    [io_lib:format("fun called with wrong arity of ~w instead of ~w in ", [length(Args), Arity]), format_mfa(Trace)];
format_reason({noproc, Trace}) ->
    ["no such process or port in call to ", format_mfa(Trace)];
format_reason({{badfun, Term}, Trace}) ->
    ["bad function ", format_term(Term), " in ", format_mfa(Trace)];
format_reason({#{'__exception__' := true} = Reason, Stacktrace}) ->
  [format_message_ex(Reason), 'Elixir.Exception':format_stacktrace(Stacktrace)];
format_reason({Reason, {M, F, A} = Trace}) when is_atom(M), is_atom(F), is_list(A) ->
  [format_reason(Reason), " in ", format_mfa(Trace)];
format_reason({Reason, [{M, F, A}|_] = Trace}) when is_atom(M), is_atom(F), is_integer(A) ->
    [format_reason(Reason), " in ", format_mfa(Trace)];
format_reason({Reason, [{M, F, A, Props}|_] = Trace}) when is_atom(M), is_atom(F), is_integer(A), is_list(Props) ->
    [format_reason(Reason), " in ", format_mfa(Trace)];
format_reason(Reason) ->
    format_term(Reason).

%% @private
format_mfa([{_, _, _} = MFA | _]) ->
    format_mfa(MFA);
format_mfa([{_, _, _, _} = MFA | _]) ->
    format_mfa(MFA);
format_mfa({M, F, A, _}) ->
    format_mfa({M, F, A});
format_mfa({M, F, A}) ->
    format_mfa_platform({M, F, A});
format_mfa(Term) ->
    format_term(Term).

%% @private
format_mfa_platform({M, F, A} = MFA) ->
  case is_elixir() of
    false -> format_mfa_erlang(MFA);
    _     -> 'Elixir.Exception':format_mfa(M, F, A)
  end.

%% @private
format_mfa_erlang({M, F, A}) when is_list(A) ->
  {Format, Args} = format_args(A, [], []),
    format("~w:~w(" ++ Format ++ ")", [M, F | Args]);
format_mfa_erlang({M, F, A}) when is_integer(A) ->
  format("~w:~w/~w", [M, F, A]);
format_mfa_erlang(Term) ->
    format_term(Term).

%% @private
format_args([], FormatAcc, ArgsAcc) ->
    {string:join(lists:reverse(FormatAcc), ", "), lists:reverse(ArgsAcc)};
format_args([Arg | Rest], FormatAcc, ArgsAcc) ->
    format_args(Rest, ["~s" | FormatAcc], [format_term(Arg) | ArgsAcc]).

%% @private
format_string(Term) when is_atom(Term); is_binary(Term) ->
    format("~s", [Term]);
format_string(Term) ->
    try format("~s", [Term]) of
        Result -> Result
    catch
        error:badarg -> format_term(Term)
    end.

%% @private
format_term(Term) ->
    format("~120p", [Term]).

%% @private
format(Format, Data) ->
    iolist_to_binary(io_lib:format(Format, Data)).

%% @private
is_elixir() ->
  case code:is_loaded('Elixir.Exception') of
    false -> false;
    _     -> true
  end.
