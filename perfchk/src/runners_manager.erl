-module(runners_manager).

-behaviour(gen_server).

-export([start_link/0, run/0]).

-define(SAUCE_USER_ENV, "SAUCE_USER").
-define(SAUCE_ACCESS_KEY_ENV, "SAUCE_ACCESS_KEY").
-define(CONCURRENT_TESTS, 4).

-include("print.hrl").
-include("perfchk.hrl").

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

start_link() ->
    Url = application:get_env(perfchk, url, undefined),
    SauceUser = application:get_env(perfchk, sauce_user, os:get_env_var(?SAUCE_USER_ENV)),
    SauceAccessKey = application:get_env(perfchk, sauce_key, os:get_env_var(?SAUCE_ACCESS_KEY_ENV)),
    TestName = application:get_env(perfchk, test_name, "PerfChk SL Test"),
    ConcurrentTests = application:get_env(perfchk, concurrent_tests, ?CONCURRENT_TESTS),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Url, SauceUser, SauceAccessKey, TestName, ConcurrentTests], []).

run() ->
    gen_server:cast(?MODULE, run).

init([Url, SauceUser, SauceAccessKey, TestName, ConcurrentTests]) ->
    {ok, #sauce{url=Url, user=SauceUser, key=SauceAccessKey, test_name=TestName, concurrent_tests=ConcurrentTests}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(run, #sauce{url=Url, user=SauceUser, key=SauceAccessKey, test_name=TestName, concurrent_tests=ConcurrentTests} = State) ->
    case lists:any(fun(P) -> is_undefined(P) end, [Url, SauceUser, SauceAccessKey]) of
        true ->
            print_help();
        false ->
            ?print("Starting remote session as $dc", [SauceUser]),
            EncodedAuthString = base64:encode_to_string(lists:append([SauceUser,":",SauceAccessKey])),
            BasicAuth = [{"Authorization","Basic " ++ EncodedAuthString}],
            {ok, Processes} = start_concurrent_sessions(Url, SauceUser, BasicAuth, TestName, ConcurrentTests),
            {ok, Pid} = start_check_session(Url, SauceUser, BasicAuth, TestName),
            ?print("Checking performance of $dc", [Url]),
            ?print("Parallel tests launched ($dc)...", [integer_to_list(ConcurrentTests)]),
            quit_when_all_done([Pid|Processes])
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

start_concurrent_sessions(Url, SauceUser, BasicAuth, TestName, N) ->
    start_concurrent_sessions(Url, SauceUser, BasicAuth, TestName, N, []).

start_concurrent_sessions(_Url, _SauceUser, _BasicAuth, _TestName, 0, Processes) ->
    {ok, Processes};
start_concurrent_sessions(Url, SauceUser, BasicAuth, TestName, N, Processes) ->
    {ok, Pid} = start_session(Url, SauceUser, BasicAuth, TestName),
    start_concurrent_sessions(Url, SauceUser, BasicAuth, TestName, N-1, [Pid|Processes]).

start_session(Url, SauceUser, BasicAuth, TestName) ->
    {ok, Pid} = runners_sup:start_child(Url, SauceUser, BasicAuth, TestName),
    runner:check_performance(Pid, noreply),
    {ok, Pid}.

start_check_session(Url, SauceUser, BasicAuth, TestName) ->
    {ok, Pid} = runners_sup:start_child(Url, SauceUser, BasicAuth, TestName),
    runner:check_performance(Pid, reply),
    {ok, Pid}.

quit_when_all_done([]) ->
    init:stop(),
    ok;
quit_when_all_done([Process|Porocesses] = All) ->
    case process_info(Process) of
        undefined -> quit_when_all_done(Porocesses);
        _Alive ->
            timer:sleep(200),
            quit_when_all_done(All)
    end.

is_undefined(Value) ->
    Value =:= undefined.

print_help() ->
    ?print("~n%b~n", ["Erlang PrfChk Usage"]),
    ?print("Check your website performance using your SauceLabs account and compare metrics with tests done in the past.~n"),
    ?print("Command:"),
    ?print("erl -pa _build/default/lib/jiffy/ebin -pa _build/default/lib/perfchk/ebin or ./run.sh~n"),
    ?print("Parameters (all but name required):"),
    ?print("-u     URL of your website"),
    ?print("-u     Your SauceLabs username"),
    ?print("-k     Your SauceLabs access key~n"),
    ?print("-n     Test name~n"),
    ?print("You may skip -u and -k variables if you'd keep this values in env in %dr and %dr~n",
           [?SAUCE_USER_ENV, ?SAUCE_ACCESS_KEY_ENV]).
