%% -------------------------------------------------------------------
%%
%% register_test: Register Test Suite
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

-module(register_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

register_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun register1/0, 
            fun register2/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(server1, ?MODULE, server1, [
        {from, "sip:server1@nksip"},
        registrar,
        {transports, [{udp, all, 5060}, {tls, all, 5061}]},
        {supported, "100rel,timer,path"},        % No outbound
        {registrar_min_time, 60}
    ]),

    {ok, _} = nksip:start(client1, ?MODULE, client1, [
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]},
        {supported, "100rel,timer,path"}        % No outbound
    ]),

    {ok, _} = nksip:start(client2, ?MODULE, client2, [
        {from, "sip:client2@nksip"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).


register1() ->
    Min = nksip_config:get(registrar_min_time),
    MinB = nksip_lib:to_binary(Min),
    Max = nksip_config:get(registrar_max_time),
    MaxB = nksip_lib:to_binary(Max),
    Def = nksip_config:get(registrar_default_time),
    DefB = nksip_lib:to_binary(Def),
    
    % Method not allowed
    {ok, 405, []} = nksip_uac:register(client2, "sip:127.0.0.1:5070", []),

    {ok, 200, Values1} = nksip_uac:register(client1, "sip:127.0.0.1", 
                        [unregister_all, {meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values1,
    [] = nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),
    
    Ref = make_ref(),
    Self = self(),
    RespFun = fun(Reply) -> Self ! {Ref, Reply} end,
    {async, _} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                [async, {callback, RespFun}, contact, get_request,
                                 {meta, [<<"contact">>]}, {supported, ""}]),
    [CallId, CSeq] = receive 
        {Ref, {req, Req2}} -> nksip_sipmsg:fields(Req2, [call_id, cseq_num])
        after 2000 -> error(register1)
    end,
    Contact2 = receive 
        {Ref, {ok, 200, [{<<"contact">>, [C2]}]}} -> C2
        after 2000 -> error(register1) 
    end,

    Name = <<"client1">>,
    [#uri{
        user = Name, 
        domain = Domain, 
        port = Port, 
        ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, DefB}]
    }] = 
        nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),
    {ok, UUID} = nksip:get_uuid(client1),
    C1_UUID = <<$", UUID/binary, $">>,
    MakeContact = fun(Exp) ->
        list_to_binary([
            "<sip:", Name, "@", Domain, ":", nksip_lib:to_binary(Port),
            ">;+sip.instance=", C1_UUID, ";expires=", Exp])
        end,

    Contact2 = MakeContact(DefB),


    {ok, 400, Values3} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq_num, CSeq}, contact,
                                     {meta, [reason_phrase]}]),
    [{reason_phrase, <<"Rejected Old CSeq">>}] = Values3,

    {ok, 200, []} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq_num, CSeq+1}, contact]),

    {ok, 400, []} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq_num, CSeq+1}, 
                                     unregister_all]),
    Opts3 = [{expires, Min-1}, contact, {meta, [<<"min-expires">>]}],
    {ok, 423, Values4} = nksip_uac:register(client1, "sip:127.0.0.1", Opts3),
    [{_, [MinB]}] = Values4,
    
    Opts4 = [{expires, Max+1}, contact, {meta, [<<"contact">>]}],
    {ok, 200, Values5} = nksip_uac:register(client1, "sip:127.0.0.1", Opts4),
    [{_, [Contact5]}] = Values5,
    Contact5 = MakeContact(MaxB),
    [#uri{user=Name, domain=Domain, port=Port, 
         ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, MaxB}]}] = 
        nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),

    Opts5 = [{expires, Min}, contact, {meta, [<<"contact">>]}],
    ExpB = nksip_lib:to_binary(Min),
    {ok, 200, Values6} = nksip_uac:register(client1, "sip:127.0.0.1", Opts5),
    [{_, [Contact6]}] = Values6,
    Contact6 = MakeContact(ExpB),
    [#uri{user=Name, domain=Domain, port=Port, 
          ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, ExpB}]}] = 
        nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),

    Expire = nksip_lib:timestamp()+Min,
    [#reg_contact{
            contact = #uri{
                user = <<"client1">>, domain=Domain, port=Port, 
                ext_opts=[{<<"+sip.instance">>, C1_UUID}, {<<"expires">>, ExpB}]}, 
            expire = Expire,
            q = 1.0
    }] = nksip_registrar:get_info(server1, sip, <<"client1">>, <<"nksip">>),



    % true = lists:member(Reg1, nksip_registrar:internal_get_all()),

    % Simulate a request coming at the server from 127.0.0.1:Port, 
    % From is sip:client1@nksip,
    Request1 = #sipmsg{
                app_id = element(2, nksip:find_app(server1)), 
                from = {#uri{scheme=sip, user= <<"client1">>, domain= <<"nksip">>}, <<>>},
                transport = #transport{
                                proto = udp, 
                                remote_ip = {127,0,0,1}, 
                                remote_port=Port}},

    true = nksip_registrar:is_registered(Request1),

    {ok, Ip} = nksip_lib:to_ip(Domain),
    
    % Now coming from the Contact's registered address
    Request2 = Request1#sipmsg{transport=(Request1#sipmsg.transport)
                                                #transport{remote_ip=Ip}},
    true = nksip_registrar:is_registered(Request2),

    ok = nksip_registrar:delete(server1, sip, <<"client1">>, <<"nksip">>),
    not_found  = nksip_registrar:delete(server1, sip, <<"client1">>, <<"nksip">>),
    ok.


register2() ->
    nksip_registrar:internal_clear(),

    Opts1 = [contact, {expires, 300}],
    FromS = {from, <<"sips:client1@nksip">>},

    {ok, 200, Values1} = nksip_uac:register(client1, "sip:127.0.0.1", 
                            [unregister_all, {meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values1,
    [] = nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),

    {ok, 200, Values2} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                            [FromS, unregister_all, 
                                             {meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values2,
    [] = nksip_registrar:find(server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(client1, "sip:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, 
                                            "<sip:127.0.0.1;transport=tcp>", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, 
                                            "<sip:127.0.0.1;transport=tls>", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, "sips:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, "sip:127.0.0.1", 
                    [{contact, "tel:123456"}, {expires, 300}]),

    {ok, UUID1} = nksip:get_uuid(client1),
    QUUID1 = <<$", UUID1/binary, $">>,

    % Now we register a different AOR (with sips)
    % ManualContact = <<"<sips:client1@127.0.0.1:5071>;+sip.instance=", QUUID1/binary>>,
    ManualContact = <<"<sips:client1@127.0.0.1:5071>">>,
    {ok, 200, Values3} = nksip_uac:register(client1, "sips:127.0.0.1", 
                        [{contact, ManualContact}, {from, "sips:client1@nksip"},
                         {meta, [<<"contact">>]}, {expires, 300}]),
    [{<<"contact">>, Contact3}] = Values3,
    Contact3Uris = nksip_parse:uris(Contact3),

    {ok, 200, Values4} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                            [{meta,[parsed_contacts]}]),
    [{parsed_contacts, Contacts4}] = Values4, 
    [
        #uri{scheme=sip, port=5070, opts=[], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5070, opts=[{<<"transport">>, <<"tcp">>}], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5071, opts=[{<<"transport">>, <<"tls">>}], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sips, port=5071, opts=[],
            ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=tel, domain=(<<"123456">>), opts=[], 
             ext_opts=[{<<"expires">>, <<"300">>}]}
    ]  = lists:sort(Contacts4),

    [#uri{scheme=sips, port=5071, opts=[], ext_opts=[{<<"expires">>, <<"300">>}]}] = 
        Contact3Uris,
    [#uri{scheme=sips, user = <<"client1">>, domain=_Domain, port = 5071}] =
        nksip_registrar:find(server1, sips, <<"client1">>, <<"nksip">>),

    Contact = <<"<sips:client1@127.0.0.1:5071>;expires=0">>,
    {ok, 200, []} = nksip_uac:register(client1, "sips:127.0.0.1", 
                                        [{contact, Contact}, {from, "sips:client1@nksip"},
                                         {expires, 300}]),
    [] = nksip_registrar:find(server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(client2, 
                                        "sip:127.0.0.1", [unregister_all]),
    [] = nksip_registrar:find(server1, sip, <<"client2">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", 
                                [{local_host, "aaa"}, contact]),
    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", 
                                [{contact, "<sip:bbb>;q=2.1;expires=180, <sips:ccc>;q=3"}]),
    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", 
                                [{contact, <<"<sip:ddd:444;transport=tcp>;q=2.1">>}]),
    [
        [
            #uri{user = <<"client2">>, domain = <<"aaa">>, ext_opts = ExtOpts1}
        ],
        [
            #uri{user= <<>>, domain = <<"ddd">>,port = 444,
                opts = [{<<"transport">>,<<"tcp">>}],
               ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"3600">>}]},
             #uri{user = <<>>, domain = <<"bbb">>, port = 0,
                opts = [], ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"180">>}]}
        ],
        [
            #uri{user = <<>>, domain = <<"ccc">>, port = 0, 
                opts = [], ext_opts = [{<<"q">>,<<"3">>},{<<"expires">>,<<"3600">>}]}
        ]
    ] = nksip_registrar:qfind(server1, sip, <<"client2">>, <<"nksip">>),
    true = lists:member({<<"expires">>,<<"3600">>}, ExtOpts1),

    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", [unregister_all]),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    nksip:put(Id, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, Id}.

route(_ReqId, Scheme, User, Domain, _From, AppId=State) when AppId==server1 ->
    Opts = [
        record_route,
        {insert, "x-nk-server", AppId}
    ],
    {ok, Domains} = nksip:get(server1, domains),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            {reply, {process, Opts}, State};
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(server1, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList, Opts}, State}
            end;
        _ ->
            {reply, {proxy, ruri, Opts}, State}
    end;

route(_, _, _, _, _, State) ->
    {reply, process, State}.

