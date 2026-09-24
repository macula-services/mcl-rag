%% @doc `mcl-rag/info', the procedure mcl_om 0.28 answers for this service with
%% no code of its own: who it is, its versions and what it advertises.
%%
%% Built from this service's real info/0 and its real capabilities/0 with
%% `info' added the way mcl_om:boot/2 adds it, then sent through macula's own
%% frame codec, the path a reply takes. What arrives must be text, never bytes,
%% and name this service, its procedures and the mcl_om 0.28 / macula 12.2 pair
%% it was built with (12.2 under an older mcl_om lets a failed publish
%% announcement kill the publishing process).
-module(mcl_rag_info_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SERVICE, mcl_rag_service).
-define(ORG, <<"mcl-rag">>).

info_round_trip_test_() ->
    {setup, fun configure/0, fun unconfigure/1,
     fun(_) ->
         Reply = through_the_codec(mcl_om_info:render(facts())),
         #{name := Name, version := Version} = ?SERVICE:info(),
         Own = [<<(?ORG)/binary, "/", N/binary>> || #{name := N} <- ?SERVICE:capabilities()],
         [?_assertEqual({text, Name}, maps:get(name, Reply)),
          ?_assertEqual({text, Version}, maps:get(version, Reply)),
          ?_assertEqual({text, ?ORG}, maps:get(org, Reply)),
          ?_assertEqual([{text, C} || C <- [<<(?ORG)/binary, "/info">> | Own]],
                        maps:get(capabilities, Reply)),
          ?_assertEqual([], [V || V <- lists:flatten(maps:values(Reply)), is_binary(V)]),
          ?_assertMatch({text, <<"0.28.", _/binary>>}, maps:get(mcl_om_version, Reply)),
          ?_assertMatch({text, <<"12.2.", _/binary>>}, maps:get(macula_version, Reply))]
     end}.

%% The service must leave `info' to mcl_om: declaring its own refuses boot.
the_service_does_not_declare_info_test_() ->
    {setup, fun configure/0, fun unconfigure/1,
     fun(_) -> ?_assertMatch([_ | _], mcl_om_info:with_info(?SERVICE:capabilities())) end}.

%% What mcl_om_info:answer/1 gathers on a live node, from this service's own
%% sources instead of a running mcl_om.
facts() ->
    #{name := Name, version := Version, description := Description} = ?SERVICE:info(),
    Caps = mcl_om_info:with_info(?SERVICE:capabilities()),
    #{name => Name, version => Version, description => Description,
      service_name => Name, box => <<"test-box">>, org => ?ORG,
      node_id => <<16#ab:256>>,
      macula_version => vsn(macula), mcl_om_version => vsn(mcl_om),
      uptime_s => 1, status => ok,
      capabilities => [<<(?ORG)/binary, "/", N/binary>> || #{name := N} <- Caps]}.

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.

through_the_codec(Payload) ->
    {ok, Key} = macula_node_keys:generate(identity, pq_hybrid, #{puzzle_difficulty => 0}),
    Spec = #{request_id => crypto:strong_rand_bytes(16),
             realm => crypto:hash(sha256, <<"io.macula">>),
             procedure => <<(?ORG)/binary, "/info">>,
             target => macula_node_keys:key_id(Key),
             deadline => erlang:system_time(millisecond) + 60_000,
             payload => Payload},
    {ok, Decoded, <<>>} = macula_frame:decode(macula_frame:encode(macula_frame:call(Spec, Key))),
    {ok, #{payload := Delivered}} = macula_frame:verify_request(Decoded, pq_hybrid),
    %% Keys arrive as sent, CBOR text (`{text, <<"name">>}'); values keep their
    %% `{text, _}' tags, which is what the assertions look at.
    maps:from_list([{key(K), V} || {K, V} <- maps:to_list(Delivered)]).

key({text, K}) -> binary_to_existing_atom(K);
key(K) when is_atom(K) -> K.

%% What a service's capabilities/0 may read at boot: the crypto profile, the
%% realm and its trust key, and the org.
configure() ->
    {ok, Realm} = macula_node_keys:generate(realm, pq_hybrid, #{}),
    ok = application:set_env(macula, crypto_profile, pq_hybrid),
    ok = application:set_env(mcl_om, realm, binary:encode_hex(crypto:hash(sha256, <<"io.macula">>), lowercase)),
    ok = application:set_env(mcl_om, realm_key,
                             binary:encode_hex(macula_node_keys:public_key(Realm), lowercase)),
    ok = application:set_env(mcl_om, org, ?ORG).

unconfigure(_) ->
    [application:unset_env(A, K) || {A, K} <- [{macula, crypto_profile}, {mcl_om, realm},
                                              {mcl_om, realm_key}, {mcl_om, org}]],
    ok.
