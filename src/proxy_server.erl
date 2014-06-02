-module(proxy_server).

-export([start/0]).

-export([start_process/0,
        start_process/1,
        accept/1,
        start_server/0]).


-include("utils.hrl").

%% WORKER_NUMS    - how many process will spawn when server start
%% WORKER_TIMEOUT - an available process will exit after this timeout ,
%%                  this is used for reduce the spawned work process.

-define(CONNECT_RETRY_TIMES, 2).
-define(WORKER_NUMS, 30).
-define(WORKER_TIMEOUT, 600000).
-define(TIMEOUT, 10000).


-define(LOG(Msg), io:format(Msg)).
-define(LOG(Msg, Args), io:format(Msg, Args)).

-define(SOCK_OPTIONS,
        [binary,
         {reuseaddr, true},
         {active, false},
         {nodelay, true}
        ]).



start() ->
    Conf = application:get_all_env(proxy_server),
    ListenPort = proplists:get_value(listen_port, Conf, 0),
    ListenIP = proplists:get_value(listen_ip, Conf, {0,0,0,0}),
    {ok, Socket} = gen_tcp:listen(ListenPort, [{ip, ListenIP} | ?SOCK_OPTIONS]),
    {ok, {Ip,PortNum}} = inet:sockname(Socket),
    put(sockname, {Ip,PortNum}),
    ?LOG("Proxy server listen on ~p : ~p~n", [Ip, PortNum]),
    register(proxy_gate, self()),
    register(server, spawn(?MODULE, start_server, [])),
    accept(Socket).


accept(Socket) ->
    {ok, Client} = gen_tcp:accept(Socket),
    server ! choosepid,
    receive
        {ok, Pid} ->
            ok = gen_tcp:controlling_process(Client, Pid),
            Pid ! {connect, Client},
            accept(Socket);
        {stop, From, _Reason} ->
            From ! {ack, stop},
            ?LOG("Calling stop reason: ~p~n", [_Reason]),
            gen_tcp:close(Socket)
    after ?TIMEOUT ->
            gen_tcp:close(Client),
            accept(Socket)
    end.



start_server() ->
    loop(start_workers(?WORKER_NUMS)).

%% main loop, accept new connections, reuse workers, and purge dead workers.
loop(Workers) ->
    NewWorkers =
    receive
        choosepid ->
            manage_workers(choosepid, Workers);
        {'DOWN', _Ref, process, Pid, timeout} ->
            manage_workers(timeout, Workers, Pid);
        {reuse, Pid} ->
            manage_workers(reuse, Workers, Pid)
    end,
    loop(NewWorkers).


%% spawn some works as works pool.
start_workers(Num) ->
    start_workers(Num, []).

start_workers(0, Workers) ->
    Workers;
start_workers(Num, Workers) ->
    {Pid, _Ref} = spawn_monitor(?MODULE, start_process, []),
    start_workers(Num-1, [Pid | Workers]).



manage_workers(choosepid, []) ->
    [Head | Tail] = start_workers(?WORKER_NUMS),
    proxy_gate ! {ok, Head},
    Tail;

manage_workers(choosepid, [Head | Tail]) ->
    proxy_gate ! {ok, Head},
    Tail.

manage_workers(timeout, Works, Pid) ->
    ?LOG("Clear timeout pid: ~p~n", [Pid]),
    lists:delete(Pid, Works);

manage_workers(reuse, Works, Pid) ->
    ?LOG("Reuse Pid, back to pool: ~p~n", [Pid]),
    %% this reused pid MUST put at the tail or works list,
    %% for other works can be chosen and use.
    Works ++ [Pid].


start_process() ->
    receive
        {connect, Client} ->
            start_process(Client),
            server ! {reuse, self()},
            start_process()
    after ?WORKER_TIMEOUT ->
        exit(timeout)
    end.


start_process(Client) ->
    try
        parse_version(Client)
    catch
        E:R ->
            ?LOG("EXCEPTION ~p:~p (~p)~n",[E,R,erlang:get_stacktrace()])
    after
        gen_tcp:close(Client)
    end.

parse_version(Sock) ->
    {ok, <<4>>} = gen_tcp:recv(Sock, 1),
    ?LOG("vsn 4~n"),
    parse_command(Sock).

parse_command(Sock) ->
    ?LOG("cmd ~n"),
    {ok, <<1>>} = gen_tcp:recv(Sock, 1), % only support stream conns
    parse_port(Sock).

parse_port(Sock) ->
    ?LOG("port ~n"),
    {ok, <<Port:16/big>>} = gen_tcp:recv(Sock,2),
    parse_invalid_ip(Sock, Port).

parse_invalid_ip(Sock, Port) ->
    ?LOG("fake ip~n"),
    case gen_tcp:recv(Sock, 4) of
        {ok, <<0,0,0,Other>>} -> % socks4a
            true = Other =/= 0,
            parse_user_id_4a(Sock, Port, <<>>);
        {ok, <<A/big,B/big,C/big,D/big>>} ->
            parse_user_id_4(Sock, Port, <<>>, {A,B,C,D})
    end.

parse_user_id_4a(Sock, Port, UserId) ->
    ?LOG("uid (iter)~n"),
    case gen_tcp:recv(Sock, 1) of
        {ok, <<0>>} -> parse_domain(Sock, Port, UserId, <<>>);
        {ok, Byte} -> parse_user_id_4a(Sock, Port, <<UserId/binary, Byte>>)
    end.

parse_user_id_4(Sock, Port, UserId, {A,B,C,D}=Ip) ->
    ?LOG("uid (iter)~n"),
    case gen_tcp:recv(Sock, 1) of
        {ok, <<0>>} -> 
            Response = <<0,16#5a/big-integer,Port:16/big,A/big,B/big,C/big,D/big>>,
            gen_tcp:send(Sock, Response),
            communicate(Sock, Ip, Port);
        {ok, Byte} -> parse_user_id_4(Sock, Port, <<UserId/binary, Byte>>, Ip)
    end.

parse_domain(Sock, Port, UserId, Host) ->
    case gen_tcp:recv(Sock, 1) of
        {ok, <<0>>} ->
            ?LOG("0-host~n"),
            StrHost = binary_to_list(Host),
            ?LOG("Host Resolve: ~p -> ~p~n",[Host, catch inet:getaddr(StrHost, inet)]),
            {ok, {A,B,C,D}} = inet:getaddr(StrHost, inet),
            Response = <<0,16#5a/big-integer,Port:16/big,A/big,B/big,C/big,D/big>>,
            ?LOG("Response: ~p -> ~p~n", [Sock, Response]),
            gen_tcp:send(Sock, Response),
            communicate(Sock, StrHost, Port);
        {ok, Byte} ->
            parse_domain(Sock, Port, UserId, <<Host/binary, Byte/binary>>)
    end.

%        {error, _Error} ->
%            ?LOG("start Sock4 recv client error: ~p~n", [_Error]),
%            gen_tcp:close(Client)
%    end,
%    ok.

%parse_address(Client, AType) when AType =:= <<?IPV4>> ->
%    {ok, Data} = gen_tcp:recv(Client, 6),
%    <<_,Port:16,_FakeIp:4, 0, Destination/binary>> = Data,
%    Address = list_to_tuple( binary_to_list(Destination) ),
%    communicate(Client, Address, Port);
%
%parse_address(Client, AType) when AType =:= <<?IPV6>> ->
%    {ok, Data} = gen_tcp:recv(Client, 18),
%    <<_,Port:16, _FakeIp:4, 0, Destination/binary>> = Data,
%    Address = list_to_tuple( binary_to_list(Destination) ),
%    communicate(Client, Address, Port);
%
%parse_address(Client, AType) when AType =:= <<?DOMAIN>> ->
%    {ok, Data} = gen_tcp:recv(Client, 3),
%    <<Port:16, DomainLen:8>> = Data,
%
%    {ok, DataRest} = gen_tcp:recv(Client, DomainLen),
%    Destination = DataRest,
%
%    Address = binary_to_list(Destination),
%    communicate(Client, Address, Port);
%
%parse_address(Client, _AType) ->
%    %% receive the invalid data. close the connection
%    ?LOG("Invalid data!~n", []),
%    gen_tcp:close(Client).

%<<4,1,1,187,0,0,0,1,0,97,117,115,51,46,109,111,122,105,108,108,97,46,111,114,103,0>>

communicate(Client, Address, Port) ->
    ?LOG("Address: ~p, Port: ~p~n", [Address, Port]),

    case connect_target(Address, Port, ?CONNECT_RETRY_TIMES) of
        {ok, TargetSocket} ->
            transfer(Client, TargetSocket);
        error ->
            ?LOG("Connect Address Error: ~p:~p~n", [Address, Port]),
            gen_tcp:close(Client)
    end.



connect_target(_, _, 0) ->
    error;
connect_target(Address, Port, Times) ->
    case gen_tcp:connect(Address, Port, ?SOCK_OPTIONS, ?TIMEOUT) of
        {ok, TargetSocket} ->
            {ok, TargetSocket};
        {error, _Error} ->
            connect_target(Address, Port, Times-1)
    end.


transfer(Client, Remote) ->
    inet:setopts(Remote, [{active, once}]),
    inet:setopts(Client, [{active, once}]),
    receive
        {tcp, Client, Request} ->
            case gen_tcp:send(Remote, Request) of
                ok ->
                    transfer(Client, Remote);
                {error, _Error} ->
                    ok
            end;
        {tcp, Remote, Response} ->
            %% client maybe close the connection when data transferring
            case gen_tcp:send(Client, Response) of
                ok ->
                    transfer(Client, Remote);
                {error, _Error} ->
                    ok
            end;
        {tcp_closed, Client} ->
            ok;
        {tcp_closed, Remote} ->
            ok;
        {tcp_error, Client, _Reason} ->
            ok;
        {tcp_error, Remote, _Reason} ->
            ok
    end,

    gen_tcp:close(Remote),
    gen_tcp:close(Client),
    ok.
