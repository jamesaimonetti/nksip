%% -------------------------------------------------------------------
%%
%% path_test: Path (RFC3327) Tests
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(path_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

path_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0
        ]
    }.

% This configuration resembles the example in RFC3327
start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(p1, ?MODULE, p1, [
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]}
    ]),

    {ok, _} = nksip:start(p2, ?MODULE, p2, [
        {local_host, "localhost"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),

    {ok, _} = nksip:start(p3, ?MODULE, p3, [
        {local_host, "localhost"},
        {transports, [{udp, all, 5080}, {tls, all, 5081}]}
    ]),

    {ok, _} = nksip:start(registrar, ?MODULE, registrar, [
        registrar,
        {local_host, "localhost"},
        {transports, [{udp, all, 5090}, {tls, all, 5091}]}
    ]),

    {ok, _} = nksip:start(ua1, ?MODULE, ua1, [
        {from, "sip:ua1@nksip"},
        {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 0}, {tls, all, 0}]}
    ]),

    {ok, _} = nksip:start(ua2, ?MODULE, ua2, [
        {route, "<sip:127.0.0.1:5090;lr>"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, any}, {tls, all, any}]}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(p1),
    ok = nksip:stop(p2),
    ok = nksip:stop(p3),
    ok = nksip:stop(registrar),
    ok = nksip:stop(ua1),
    ok = nksip:stop(ua2).


basic() ->
    nksip_registrar:clear(registrar),
    
    % We didn't send the Supported header, so first proxy 
    % (P1, configured to include Path) sends a 421 (Extension Required)
    {ok, 421, [{<<"require">>, [<<"path">>]}]} = 
        nksip_uac:register(ua1, "sip:nksip", [{meta,[<<"require">>]}, {supported, ""}]),

    % If the request arrives at registrar, having a valid Path header and
    % no Supported: path, it returns a 420 (Bad Extension)
    {ok, 420, [{<<"unsupported">>, [<<"path">>]}]} = 
        nksip_uac:register(ua1, "<sip:nksip?Path=sip:mypath>", 
                        [{route, "<sip:127.0.0.1:5090;lr>"}, 
                         {meta, [<<"unsupported">>]}, {supported, ""}]),


    {ok, 200, [{<<"path">>, Path}]} = 
        nksip_uac:register(ua1, "sip:nksip", [supported, contact, {meta, [<<"path">>]}]),
    [P1, P2] = nksip_parse:uris(Path),

    [#reg_contact{
        contact = #uri{scheme = sip,user = <<"ua1">>,domain = <<"127.0.0.1">>},
        path = [
            #uri{scheme = sip,domain = <<"localhost">>,port = 5080,
                    opts = [<<"lr">>]} = P1Uri,
            #uri{scheme = sip,domain = <<"localhost">>,port = 5061,
                    opts = [{<<"transport">>,<<"tls">>}, <<"lr">>]} = P2Uri
        ]
    }] = nksip_registrar:get_info(registrar, sip, <<"ua1">>, <<"nksip">>),


    P1 = P1Uri,
    P2 = P2Uri,

    % Now, if send a request to UA1, the registrar inserts the stored path
    % as routes, and requests pases throw P3, P1 and to UA1
    {ok, 200, [{_, [<<"ua1,p1,p3">>]}]} = 
        nksip_uac:options(ua2, "sip:ua1@nksip", [{meta,[<<"x-nk-id">>]}]),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.

% P1 is the outbound proxy.
% It domain is 'nksip', it sends the request to P2, inserting Path and x-nk-id headers
% If not, simply proxies the request adding a x-nk-id header
route(_, _, _, Domain, _, p1=State) ->
    Base = [{insert, "x-nk-id", "p1"}],
    case Domain of 
        <<"nksip">> -> 
            Opts = [{route, "<sip:127.0.0.1:5071;lr;transport=tls>"}, 
                     path, record_route|Base],
            {reply, {proxy, ruri, Opts}, State};
        _ -> 
            {reply, {proxy, ruri, Base}, State}
    end;

% P2 is an intermediate proxy.
% For 'nksip' domain, sends the request to P3, inserting x-nk-id header
% For other, simply proxies and adds header
route(_, _, _, Domain, _,  p2=State) ->
    Base = [{insert, "x-nk-id", "p2"}],
    case Domain of 
        <<"nksip">> -> 
            Opts = [{route, "<sip:127.0.0.1:5080;lr;transport=tcp>"}|Base],
            {reply, {proxy, ruri, Opts}, State};
        _ -> 
            {reply, {proxy, ruri, Base}, State}
    end;


% P3 is the SBC. 
% For 'nksip', it sends everything to the registrar, inserting Path header
% For other proxies the request
route(_, _, _, Domain, _, p3=State) ->
    Base = [{insert, "x-nk-id", "p3"}],
    case Domain of 
        <<"nksip">> -> 
            Opts = [{route, "<sip:127.0.0.1:5090;lr>"}, path, record_route|Base],
            {reply, {proxy, ruri, Opts}, State};
        _ -> 
            {reply, {proxy, ruri, [record_route|Base]}, State}
    end;


% P4 is a dumb router, only adds a header
% For 'nksip', it sends everything to the registrar, inserting Path header
% For other proxies the request
route(_, _, _, _, _, p4=State) ->
    Base = [{insert, "x-nk-id", "p4"}, path, record_route],
    {reply, {proxy, ruri, Base}, State};


% Registrar is the registrar proxy for "nksip" domain
route(_ReqId, Scheme, User, Domain, _From, registrar=State) ->
    case Domain of
        <<"nksip">> when User == <<>> ->
            {reply, process, State};
        <<"nksip">> ->
            case nksip_registrar:find(registrar, Scheme, User, Domain) of
                [] -> 
                    {reply, temporarily_unavailable, State};
                UriList -> 
                    {reply, {proxy, UriList}, State}
            end;
        _ ->
            {reply, {proxy, ruri, []}, State}
    end;

route(_, _, _, _, _, State) ->
    {reply, process, State}.


invite(ReqId, _Meta, _From, AppId=State) ->
    case nksip_request:header(AppId, ReqId, <<"x-nk-op">>) of
        [<<"ok">>] -> {reply, ok, State};
        _ -> {reply, 603, State}
    end.


options(ReqId, _Meta, _From, AppId=State) ->
    Ids = nksip_request:header(AppId, ReqId, <<"x-nk-id">>),
    Hds = [{add, "x-nk-id", nksip_lib:bjoin([AppId|Ids])}],
    {reply, {ok, [contact|Hds]}, State}.








