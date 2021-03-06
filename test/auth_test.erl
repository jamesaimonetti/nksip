%% -------------------------------------------------------------------
%%
%% auth_test: Authentication Tests
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

-module(auth_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

auth_test_() ->
  {setup, spawn, 
      fun() -> start() end,
      fun(_) -> stop() end,
      [
          fun digest/0, 
          fun invite/0, 
          fun dialog/0, 
          fun proxy/0
      ]
  }.


start() ->
    tests_util:start_nksip(),
    {ok, _} = nksip:start(server1, ?MODULE, server1, [
        {from, "sip:server1@nksip"},
        registrar,
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}]}
    ]),

    {ok, _} = nksip:start(server2, ?MODULE, server2, [
        {from, "sip:server2@nksip"},
        {local_host, "localhost"},
        {transports, [{udp, all, 5061}]}
    ]),

    {ok, _} = nksip:start(client1, ?MODULE, client1, [
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}]}
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, client2, [
        {from, "sip:client2@nksip"},
        {pass, "jj"},
        {pass, {"4321", "client1"}},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5071}]}
    ]),

    {ok, _} = nksip:start(client3, ?MODULE, client3, [
        {from, "sip:client3@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5072}]}
    ]),
    
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(server2),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2),
    ok = nksip:stop(client3).


digest() ->
    client1 = client1,
    client2 = client2,
    Sipclient1 = "sip:127.0.0.1:5070",
    SipC2 = "sip:127.0.0.1:5071",

    {ok, 401, []} = nksip_uac:options(client1, SipC2, []),
    {ok, 200, []} = nksip_uac:options(client1, SipC2, [{pass, "1234"}]),
    {ok, 403, []} = nksip_uac:options(client1, SipC2, [{pass, "12345"}]),
    {ok, 200, []} = nksip_uac:options(client1, SipC2, [{pass, {"1234", "client2"}}]),
    {ok, 403, []} = nksip_uac:options(client1, SipC2, [{pass, {"1234", "other"}}]),

    HA1 = nksip_auth:make_ha1("client1", "1234", "client2"),
    {ok, 200, []} = nksip_uac:options(client1, SipC2, [{pass, HA1}]),
    
    % Pass is invalid, but there is a valid one in SipApp's options
    {ok, 200, []} = nksip_uac:options(client2, Sipclient1, []),
    {ok, 200, []} = nksip_uac:options(client2, Sipclient1, [{pass, "kk"}]),
    {ok, 403, []} = nksip_uac:options(client2, Sipclient1, [{pass, {"kk", "client1"}}]),

    Self = self(),
    Ref = make_ref(),
    Fun = fun({ok, 200, []}) -> Self ! {Ref, digest_ok} end,
    {async, _} = nksip_uac:options(client1, SipC2, [async, {callback, Fun}, {pass, HA1}]),
    ok = tests_util:wait(Ref, [digest_ok]),
    ok.



invite() ->
    SipC3 = "sip:127.0.0.1:5072",
    {Ref, RepHd} = tests_util:get_ref(),

    % client3 does not support dialog's authentication, only digest is used
    {ok, 401, [{cseq_num, CSeq}]} = 
        nksip_uac:invite(client1, SipC3, [{meta, [cseq_num]}]),
    {ok, 200, [{dialog_id, DialogId1}]} = nksip_uac:invite(client1, SipC3, 
                                             [{pass, "abcd"}, RepHd]),
    ok = nksip_uac:ack(client1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client3, ack}]),
    {ok, 401, []} = nksip_uac:options(client1, DialogId1, []),
    {ok, 200, []} = nksip_uac:options(client1, DialogId1, [{pass, "abcd"}]),

    {ok, 401, _} = nksip_uac:invite(client1, DialogId1, []),

    {ok, 200, _} = nksip_uac:invite(client1, DialogId1, [{pass, "abcd"}]),
    {req, ACK3} = nksip_uac:ack(client1, DialogId1, [get_request]),
    CSeq = nksip_sipmsg:field(ACK3, cseq_num) - 8,
    ok = tests_util:wait(Ref, [{client3, ack}]),

    % client1 does support dialog's authentication
    DialogId3 = nksip_dialog:field(client1, DialogId1, remote_id),
    {ok, 200, [{cseq_num, CSeq2}]} = 
        nksip_uac:options(client3, DialogId3, [{meta, [cseq_num]}]),
    {ok, 200, [{dialog_id, DialogId3}]} = 
        nksip_uac:invite(client3, DialogId3, [RepHd]),
    ok = nksip_uac:ack(client3, DialogId3, [RepHd]),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, [{_, CSeq3}]} = nksip_uac:bye(client3, DialogId3, [{meta, [cseq_num]}]),
    ok = tests_util:wait(Ref, [{client1, bye}]),
    CSeq3 = CSeq2 + 2,
    ok.


dialog() ->
    SipC2 = "sip:127.0.0.1:5071",
    {Ref, RepHd} = tests_util:get_ref(),

    {ok, 200, [{dialog_id, DialogId1}]} = nksip_uac:invite(client1, SipC2, 
                                            [{pass, "1234"}, RepHd]),
    ok = nksip_uac:ack(client1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    [{udp, {127,0,0,1}, 5071}] = nksip_uac_lib:get_authorized_list(client1, DialogId1),
    DialogId2 = nksip_dialog:field(client1, DialogId1, remote_id),
    [{udp, {127,0,0,1}, 5070}] = nksip_uac_lib:get_authorized_list(client2, DialogId2),

    {ok, 200, []} = nksip_uac:options(client1, DialogId1, []),
    {ok, 200, []} = nksip_uac:options(client2, DialogId2, []),

    ok = nksip_uac_lib:clear_authorized_list(client2, DialogId2),
    {ok, 401, []} = nksip_uac:options(client1, DialogId1, []),
    {ok, 200, []} = nksip_uac:options(client1, DialogId1, [{pass, "1234"}]),
    {ok, 200, []} = nksip_uac:options(client1, DialogId1, []),

    ok = nksip_uac_lib:clear_authorized_list(client1, DialogId1),
    [] = nksip_uac_lib:get_authorized_list(client1, DialogId1),

    % Force an invalid password, because the SipApp config has a valid one
    {ok, 403, []} = nksip_uac:options(client2, DialogId2, [{pass, {"invalid", "client1"}}]),
    {ok, 200, []} = nksip_uac:options(client2, DialogId2, []),
    {ok, 200, []} = nksip_uac:options(client2, DialogId2, [{pass, {"invalid", "client1"}}]),

    {ok, 200, []} = nksip_uac:bye(client1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, bye}]),
    ok.


proxy() ->
    S1 = "sip:127.0.0.1",
    {Ref, RepHd} = tests_util:get_ref(),

    {ok, 407, []} = nksip_uac:register(client1, S1, []),
    {ok, 200, []} = nksip_uac:register(client1, S1, [{pass, "1234"}, unregister_all]),
    
    {ok, 200, []} = nksip_uac:register(client2, S1, [{pass, "4321"}, unregister_all]),
    
    % Users are not registered and no digest
    {ok, 407, []} = nksip_uac:options(client1, S1, []),
    % client2's SipApp has a password, but it is invalid
    {ok, 403, []} = nksip_uac:options(client2, S1, []),

    % We don't want the registrar to store outbound info, so that no 
    % Route header will be added to lookups (we are doing to do special routing)
    {ok, 200, []} = nksip_uac:register(client1, S1, 
                                       [{pass, "1234"}, contact, {supported, ""}]),
    {ok, 200, []} = nksip_uac:register(client2, S1, 
                                       [{pass, "4321"}, contact, {supported, ""}]),

    % % Authorized because of previous registration
    {ok, 200, []} = nksip_uac:options(client1, S1, []),
    {ok, 200, []} = nksip_uac:options(client2, S1, []),
    
    % The request is authorized at server1 (registered) but not server server2
    % (server1 will proxy to server2)
    Route = {route, "<sip:127.0.0.1;lr>"},
    {ok, 407, [{realms, [<<"server2">>]}]} = 
        nksip_uac:invite(client1, "sip:client2@nksip", [Route, {meta, [realms]}]),

    % Now the request reaches client2, and it is not authorized there. 
    % client2 replies with 401, but we generate a new request with the SipApp's invalid
    % password
    {ok, 403, _} = nksip_uac:invite(client1, "sip:client2@nksip", 
                                      [Route, {pass, {"1234", "server2"}}, 
                                       RepHd]),

    % Server1 accepts because of previous registration
    % Server2 replies with 407, and we generate a new request
    % Server2 now accepts and sends to client2
    % client2 replies with 401, and we generate a new request
    % Server2 and client2 accepts their digests
    {ok, 200, [{dialog_id, DialogId1}]} = nksip_uac:invite(client1, "sip:client2@nksip", 
                                            [Route, {pass, {"1234", "server2"}},
                                            {pass, {"1234", "client2"}},
                                            {supported, ""},    % No outbound
                                            RepHd]),
    % Server2 inserts a Record-Route, so every in-dialog request is sent to Server2
    % ACK uses the same authentication headers from last invite
    ok = nksip_uac:ack(client1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    % Server2 and client2 accepts the request because of dialog authentication
    {ok, 200, []} = nksip_uac:options(client1, DialogId1, []),
    % The same for client1
    DialogId2 = nksip_dialog:field(client1, DialogId1, remote_id),
    {ok, 200, []} = nksip_uac:options(client2, DialogId2, []),
    {ok, 200, []} = nksip_uac:bye(client2, DialogId2, []),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.


get_user_pass(_ReqId, User, Realm, AppId=State) ->
    Reply = if
        AppId==server1; AppId==server2 ->
            % Password for user "client1", any realm, is "1234"
            % For user "client2", any realm, is "4321"
            case User of
                <<"client1">> -> "1234";
                <<"client2">> -> "4321";
                _ -> false
            end;
        true ->
            % Password for any user in realm "client1" is "4321",
            % for any user in realm "client2" is "1234", and for "client3" is "abcd"
            case Realm of 
                <<"client1">> ->
                    % A hash can be used instead of the plain password
                    nksip_auth:make_ha1(User, "4321", "client1");
                <<"client2">> ->
                    "1234";
                <<"client3">> ->
                    "abcd";
                _ ->
                    false
            end
    end,
    {reply, Reply, State}.


% Authorization is only used for "auth" suite
authorize(_ReqId, Auth, _From, AppId=State) when AppId==server1; AppId==server2 ->
    % lager:warning("AUTH AT ~p: ~p", [Id, Auth]),
    Reply = case lists:member(dialog, Auth) orelse lists:member(register, Auth) of
        true ->
            true;
        false ->
            BinId = nksip_lib:to_binary(AppId) ,
            case nksip_lib:get_value({digest, BinId}, Auth) of
                true -> true;
                false -> false;
                undefined -> {proxy_authenticate, BinId}
            end
    end,
    {reply, Reply, State};

% client3 doesn't support dialog authorization
authorize(_ReqId, Auth, _From, AppId=State) ->
    case AppId=/=client3 andalso lists:member(dialog, Auth) of
        true ->
            {reply, true, State};
        false ->
            BinId = nksip_lib:to_binary(AppId) ,
            case nksip_lib:get_value({digest, BinId}, Auth) of
                true -> {reply, true, State}; % At least one user is authenticated
                false -> {reply, false, State}; % Failed authentication
                undefined -> {reply, {authenticate, BinId}, State} % No auth header
            end
    end.




% Route for server1 in auth tests
% Finds the user and proxies to server2
route(_ReqId, Scheme, User, Domain, _From, Id=State) when Id==server1 ->
    Opts = [{route, "<sip:127.0.0.1:5061;lr>"}],
    case User of
        <<>> -> 
            {reply, process, State};
        _ when Domain =:= <<"127.0.0.1">> ->
            {reply, proxy, State};
        _ ->
            case nksip_registrar:find(server1, Scheme, User, Domain) of
                [] -> 
                    {reply, temporarily_unavailable, State};
                UriList ->
                    {reply, {proxy, UriList, Opts}, State}
            end
    end;

route(_ReqId, _Scheme, _User, _Domain, _From, Id=State) when Id==server2 ->
    {reply, {proxy, ruri, [record_route]}, State};

route(_, _, _, _, _, State) ->
    {reply, process, State}.


invite(ReqId, Meta, _From, AppId=State) ->
    tests_util:save_ref(AppId, ReqId, Meta),
    {reply, ok, State}.


reinvite(ReqId, Meta, From, State) ->
    invite(ReqId, Meta, From, State).


ack(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, ack),
    {reply, ok, State}.


bye(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, bye),
    {reply, ok, State}.

dialog_update(_DialogId, _Update, State) ->
    {noreply, State}.



