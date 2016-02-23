%%%-------------------------------------------------------------------
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%% Handle client requests for onboard documents
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_onboard).

-export([init/0
         ,allowed_methods/0
         ,resource_exists/0
         ,validate/1
         ,authorize/1
         ,authenticate/1
         ,put/1
        ]).

-include("crossbar.hrl").

-define(OB_CONFIG_CAT, <<(?CONFIG_CAT)/binary, ".onboard">>).
-define(DEFAULT_FLOW, "{\"data\": { \"id\": \"~s\" }, \"module\": \"user\", \"children\": { \"_\": { \"data\": { \"id\": \"~s\" }, \"module\": \"voicemail\", \"children\": {}}}}").

%%%===================================================================
%%% API
%%%===================================================================
init() ->
    _ = crossbar_bindings:bind(<<"*.authorize">>, ?MODULE, 'authorize'),
    _ = crossbar_bindings:bind(<<"*.authenticate">>, ?MODULE, 'authenticate'),
    _ = crossbar_bindings:bind(<<"*.allowed_methods.onboard">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.onboard">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.validate.onboard">>, ?MODULE, 'validate'),
    _ = crossbar_bindings:bind(<<"*.execute.get.onboard">>, ?MODULE, 'get'),
    _ = crossbar_bindings:bind(<<"*.execute.put.onboard">>, ?MODULE, 'put').


authorize(Context) ->
    authorize(cb_context:req_verb(Context), cb_context:req_nouns(Context)).
authorize(?HTTP_PUT, [{<<"onboard">>,[]}]) -> 'true';
authorize(_, _) -> 'false'.

authenticate(Context) ->
    authenticate(cb_context:req_verb(Context), cb_context:req_nouns(Context)).
authenticate(?HTTP_PUT, [{<<"onboard">>,[]}]) -> 'true';
authenticate(_, _) -> 'false'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
allowed_methods() ->
    [?HTTP_PUT].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
resource_exists() ->
    'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
validate(Context) ->
    validate(Context, cb_context:req_verb(Context)).

validate(Context, ?HTTP_PUT) ->
    JObj = cb_context:req_data(Context),
    Generators = [fun(R) -> create_extensions(JObj, Context, R) end
                  ,fun(R) -> create_phone_numbers(JObj, Context, R) end
                  ,fun(R) -> create_braintree_cards(JObj, Context, R) end
                  ,fun(R) -> create_account(JObj, Context, R) end
                 ],
    case lists:foldr(fun(F, Acc) -> F(Acc) end, {[], wh_json:new()}, Generators) of
        {P, Failures} ->
            case wh_json:is_empty(Failures) of
                'true' ->
                    cb_context:setters(Context, [{fun cb_context:set_doc/2, lists:flatten(P)}
                                                 ,{fun cb_context:set_resp_status/2, 'success'}
                                                ]);
                'false' ->
                    crossbar_util:response_invalid_data(Failures, Context)
            end
    end.

put(Context) ->
    Data = cb_context:doc(Context),
    Context1 = populate_new_account(Data, Context),
    create_response(Context1).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will loop over all the 'extensions' and collect
%% valid context's for users, voicemailboxes, devices, and callflows.
%% Any errors will also be collected.
%% @end
%%--------------------------------------------------------------------
-spec create_extensions(wh_json:object(), cb_context:context(), {proplist(), wh_json:object()}) -> {proplist(), wh_json:object()}.
create_extensions(JObj, Context, Results) ->
    Extensions = wh_json:get_value(<<"extensions">>, JObj, []),
    create_extensions(Extensions, 1, Context, Results).

create_extensions([], _, _, Results) ->
    Results;
create_extensions([Exten|Extens], Iteration, Context, {PassAcc, FailAcc}) ->
    Generators = [fun(R) -> create_exten_callflow(Exten, Iteration, Context, R) end
                  ,fun(R) -> create_vmbox(Exten, Iteration, Context, R) end
                  ,fun(R) -> create_device(Exten, Iteration, Context, R) end
                  ,fun(R) -> create_user(Exten, Iteration, Context, R) end
                 ],
    {P, F} = lists:foldr(fun(F, Acc) -> F(Acc) end, {[], wh_json:new()}, Generators),
    case wh_json:is_empty(F) of
        'true' ->
            create_extensions(Extens, Iteration + 1, Context, {[P|PassAcc], FailAcc});
        'false' ->
            Failures = wh_json:set_value([<<"extensions">>, wh_util:to_binary(Iteration)], F, FailAcc),
            create_extensions(Extens, Iteration + 1, Context, {[P|PassAcc], Failures})
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use the bindings to validate and create a context
%% record to generate an account.  Any failure will be added to the error
%% json object.
%% @end
%%--------------------------------------------------------------------
-spec create_account(wh_json:object(), cb_context:context(), {proplist(), wh_json:object()}) ->
                            {proplist(), wh_json:object()}.
create_account(JObj, Context, {Pass, Fail}) ->
    Account = wh_json:get_value(<<"account">>, JObj, wh_json:new()),
    Generators = [fun(J) -> wh_doc:set_id(J, couch_mgr:get_uuid()) end
                 ],
    NewReqData = lists:foldr(fun(F, J) -> F(J) end, Account, Generators),
    Payload = [cb_context:setters(Context, [{fun cb_context:set_req_data/2, NewReqData}
                                            ,{fun cb_context:set_req_nouns/2, [{?WH_ACCOUNTS_DB, []}]}
                                           ])
              ],
    Context1 = crossbar_bindings:fold(<<"*.validate.accounts">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> {[{?WH_ACCOUNTS_DB, Context1}|Pass], Fail};
        {'error', {_, _, Errors}} -> {Pass, wh_json:set_value(<<"account">>, Errors, Fail)}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use the bindings to validate and create a context
%% record to generate an account.  Any failure will be added to the error
%% json object.
%% @end
%%--------------------------------------------------------------------
-spec create_phone_numbers(wh_json:object(), cb_context:context(), {proplist(), wh_json:object()}) ->
                                  {proplist(), wh_json:object()}.
create_phone_numbers(JObj, Context, Results) ->
    PhoneNumbers = wh_json:get_value(<<"phone_numbers">>, JObj),
    lists:foldr(fun(Number, R) ->
                        create_phone_number(Number
                                            ,wh_json:get_value([<<"phone_numbers">>, Number], JObj)
                                            ,Context, R)
                end, Results, wh_json:get_keys(PhoneNumbers)).

create_phone_number(Number, Properties, Context, {Pass, Fail}) ->
    Payload = [cb_context:setters(Context, [{fun cb_context:set_req_data/2, Properties}
                                            ,{fun cb_context:set_account_db/2, <<"--">>}
                                           ])
               ,Number
               ,<<"activate">>
              ],
    Context1 = crossbar_bindings:fold(<<"*.validate.phone_numbers">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> {[{<<"phone_numbers">>, cb_context:store(Context1, 'number', Number)}|Pass], Fail};
        {'error', {_, _, Errors}} -> {Pass, wh_json:set_value(<<"phone_numbers">>, Errors, Fail)}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use the bindings to validate and create a context
%% record to generate an braintree_customer.  Any failure will be added to the error
%% json object.
%% @end
%%--------------------------------------------------------------------
-spec create_braintree_cards(wh_json:object(), cb_context:context(), {proplist(), wh_json:object()}) -> {proplist(), wh_json:object()}.
create_braintree_cards(JObj, Context, {Pass, Fail}) ->
    Account = get_context_jobj(<<"accounts">>, Pass),
    case wh_doc:id(Account) of
        'undefined' ->
            Error = wh_json:set_value([<<"account_id">>, <<"required">>], <<"account failed validation">>, wh_json:new()),
            {Pass, wh_json:set_value(<<"braintree">>, Error, Fail)};
        AccountId ->
            Customer = wh_json:get_value(<<"braintree">>, JObj, wh_json:new()),
            Generators = [fun(J) ->
                                  case wh_json:get_ne_value(<<"credit_card">>, J) of
                                      'undefined' -> wh_json:set_value(<<"credit_card">>, wh_json:new(), J);
                                      _Else -> J
                                  end
                          end
                         ],
            NewReaData = lists:foldr(fun(F, J) -> F(J) end, Customer, Generators),
            Payload = [cb_context:setters(Context, [{fun cb_context:set_req_data/2, NewReaData}
                                                    ,{fun cb_context:set_account_id/2, AccountId}
                                                    ,{fun cb_context:set_req_verb/2, ?HTTP_POST}
                                                   ])
                       ,<<"customer">>
                      ],
            Context1 = crossbar_bindings:fold(<<"*.validate.braintree">>, Payload),
            case cb_context:response(Context1) of
                {'ok', _} -> {[{<<"braintree">>, Context1}|Pass], Fail};
                {'error', {_, _, Errors}} -> {Pass, wh_json:set_value(<<"braintree">>, Errors, Fail)}
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use the bindings to validate and create a context
%% record to generate a user.  Any failure will be added to the error
%% json object.
%% @end
%%--------------------------------------------------------------------
-spec create_user(wh_json:object(), pos_integer(), cb_context:context(), {proplist(), wh_json:object()})
                       -> {proplist(), wh_json:object()}.
create_user(JObj, Iteration, Context, {Pass, Fail}) ->
    User = wh_json:get_value(<<"user">>, JObj, wh_json:new()),
    Generators = [fun(J) -> wh_doc:set_id(J, couch_mgr:get_uuid()) end
                  ,fun(J) when Iteration =:= 1 ->
                           %% ensure the first user is a admin
                           wh_json:set_value(<<"priv_level">>, <<"admin">>, J);
                      (J) -> J
                   end
                  ,fun(J) ->
                           case wh_json:get_ne_value(<<"first_name">>, J) of
                               'undefined' ->
                                   wh_json:set_value(<<"first_name">>, <<"User">>, J);
                               _ -> J
                           end
                   end
                  ,fun(J) ->
                           case wh_json:get_ne_value(<<"last_name">>, J) of
                               'undefined' ->
                                   wh_json:set_value(<<"last_name">>, wh_util:to_binary(Iteration), J);
                               _ -> J
                           end
                   end
                  ,fun(J) ->
                           case wh_json:get_ne_value(<<"username">>, User) of
                               'undefined' ->
                                   Email = wh_json:get_ne_value(<<"email">>, J),
                                   FirstName = wh_json:get_ne_value(<<"first_name">>, J),
                                   LastName = wh_json:get_ne_value(<<"last_name">>, J),
                                   Username = generate_username(Email, FirstName, LastName),
                                   wh_json:set_value(<<"username">>, Username, J);
                               _Else -> J
                           end
                   end
                 ],
    NewReqData = lists:foldr(fun(F, J) -> F(J) end, User, Generators),
    Payload = [cb_context:set_req_data(Context, NewReqData)],
    Context1 = crossbar_bindings:fold(<<"*.validate.users">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> {[{<<"users">>, cb_context:store(Context1, 'iteration', Iteration)}|Pass], Fail};
        {'error', {_, _, Errors}} -> {Pass, wh_json:set_value(<<"users">>, Errors, Fail)}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use the bindings to validate and create a context
%% record to generate a device.  Any failure will be added to the error
%% json object.
%% @end
%%--------------------------------------------------------------------
-spec create_device(wh_json:object(), pos_integer(), cb_context:context(), {proplist(), wh_json:object()})
                         -> {proplist(), wh_json:object()}.
create_device(JObj, Iteration, Context, {Pass, Fail}) ->
    Device = wh_json:get_value(<<"device">>, JObj, wh_json:new()),
    Generators = [fun(J) -> wh_doc:set_id(J, couch_mgr:get_uuid()) end
                  ,fun(J) ->
                           User = get_context_jobj(<<"users">>, Pass),
                           case wh_doc:id(User) of
                               'undefined' -> J;
                               OwnerId -> wh_json:set_value(<<"owner_id">>, OwnerId, J)
                           end
                   end
                  ,fun(J) ->
                           case wh_json:get_ne_value(<<"name">>, J) of
                               'undefined' ->
                                   User = get_context_jobj(<<"users">>, Pass),
                                   FirstName = wh_json:get_value(<<"first_name">>, User, <<"User">>),
                                   LastName = wh_json:get_value(<<"last_name">>, User, wh_util:to_binary(Iteration)),
                                   Name = list_to_binary([FirstName, " ", LastName, "'s Device"]),
                                   wh_json:set_value(<<"name">>, Name, J);
                               _ ->
                                   J
                           end
                   end
                  ,fun(J) ->
                           case kz_device:sip_username(J) of
                               'undefined' ->
                                   Strength = whapps_config:get_integer(?OB_CONFIG_CAT, <<"device_username_strength">>, 3),
                                   kz_device:set_sip_username(J, list_to_binary(["user_", wh_util:rand_hex_binary(Strength)]));
                               _ ->
                                   J
                           end
                   end
                  ,fun(J) ->
                           case kz_device:sip_password(J) of
                               'undefined' ->
                                   Strength = whapps_config:get_integer(?OB_CONFIG_CAT, <<"device_pwd_strength">>, 6),
                                   kz_device:set_sip_password(J, wh_util:rand_hex_binary(Strength));
                               _ ->
                                   J
                           end
                   end
                 ],
    NewReqData = lists:foldr(fun(F, J) -> F(J) end, Device, Generators),
    Payload = [cb_context:set_req_data(Context, NewReqData)],
    Context1 = crossbar_bindings:fold(<<"*.validate.devices">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> {[{<<"devices">>, cb_context:store(Context1, 'iteration', Iteration)}|Pass], Fail};
        {'error', {_, _, Errors}} -> {Pass, wh_json:set_value(<<"devices">>, Errors, Fail)}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use the bindings to validate and create a context
%% record to generate a vmbox.  Any failure will be added to the error
%% json object.
%% @end
%%--------------------------------------------------------------------
-spec create_vmbox(wh_json:object(), pos_integer(), cb_context:context(), {proplist(), wh_json:object()})
                        -> {proplist(), wh_json:object()}.
create_vmbox(JObj, Iteration, Context, {Pass, Fail}) ->
    VMBox = wh_json:get_value(<<"vmbox">>, JObj, wh_json:new()),
    Generators = [fun(J) -> wh_doc:set_id(J, couch_mgr:get_uuid()) end
                  ,fun(J) ->
                           User = get_context_jobj(<<"users">>, Pass),
                           case wh_doc:id(User) of
                               'undefined' -> J;
                               OwnerId -> wh_json:set_value(<<"owner_id">>, OwnerId, J)
                           end
                   end
                  ,fun(J) ->
                           case wh_json:get_ne_value(<<"mailbox">>, J) of
                               'undefined' ->
                                   StartExten = whapps_config:get_integer(?OB_CONFIG_CAT, <<"default_vm_start_exten">>, 3 * ?MILLISECONDS_IN_SECOND),
                                   wh_json:set_value(<<"mailbox">>, wh_util:to_binary(StartExten + Iteration), J);
                               _ ->
                                   J
                           end
                   end
                  ,fun(J) ->
                           case wh_json:get_ne_value(<<"name">>, J) of
                               'undefined' ->
                                   User = get_context_jobj(<<"users">>, Pass),
                                   FirstName = wh_json:get_value(<<"first_name">>, User, <<"User">>),
                                   LastName = wh_json:get_value(<<"last_name">>, User, wh_util:to_binary(Iteration)),
                                   Name = list_to_binary([FirstName, " ", LastName, "'s Voicemail"]),
                                   wh_json:set_value(<<"name">>, Name, J);
                               _ ->
                                   J
                           end
                   end
                 ],
    NewReqData = lists:foldr(fun(F, J) -> F(J) end, VMBox, Generators),
    Payload = [cb_context:set_req_data(Context, NewReqData)],
    Context1 = crossbar_bindings:fold(<<"*.validate.vmboxes">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> {[{<<"vmboxes">>, cb_context:store(Context1, 'iteration', Iteration)}|Pass], Fail};
        {'error', {_, _, Errors}} -> {Pass, wh_json:set_value(<<"vmboxes">>, Errors, Fail)}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use the bindings to validate and create a context
%% record to generate a extension callflow.  Any failure will be added
%% to the error json object.
%% @end
%%--------------------------------------------------------------------
-spec create_exten_callflow(wh_json:object(), pos_integer(), cb_context:context(), {proplist(), wh_json:object()})
                                 -> {proplist(), wh_json:object()}.
create_exten_callflow(JObj, Iteration, Context, {Pass, Fail}) ->
    Callflow = wh_json:get_value(<<"callflow">>, JObj, wh_json:new()),
    Generators = [fun(J) ->
                          User = get_context_jobj(<<"users">>, Pass),
                          VMBox = get_context_jobj(<<"vmboxes">>, Pass),
                          DefaultFlow = whapps_config:get_string(?OB_CONFIG_CAT, <<"default_extension_callflow">>
                                                                     ,wh_util:to_binary(?DEFAULT_FLOW)),
                          Flow = wh_json:decode(io_lib:format(DefaultFlow, [wh_doc:id(User)
                                                                            ,wh_doc:id(VMBox)
                                                                           ])),
                          wh_json:set_value(<<"flow">>, Flow, J)
                  end
                  ,fun(J) -> wh_doc:set_id(J, couch_mgr:get_uuid()) end
                  ,fun(J) ->
                           case [Num || Num <- wh_json:get_ne_value(<<"numbers">>, J, [])
                                            , not wh_util:is_empty(Num)]
                           of
                               [] ->
                                   StartExten = whapps_config:get_integer(?OB_CONFIG_CAT
                                                                          ,<<"default_callflow_start_exten">>
                                                                              ,2 * ?MILLISECONDS_IN_SECOND),
                                   wh_json:set_value(<<"numbers">>, [wh_util:to_binary(StartExten + Iteration)], J);
                               Numbers -> wh_json:set_value(<<"numbers">>, Numbers, J)
                           end
                   end
                 ],
    NewReqData = lists:foldr(fun(F, J) -> F(J) end, Callflow, Generators),
    Payload = [cb_context:set_req_data(Context, NewReqData)],
    Context1 = crossbar_bindings:fold(<<"*.validate.callflows">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> {[{<<"callflows">>, cb_context:store(Context1, 'iteration', Iteration)}|Pass], Fail};
        {'error', {_, _, Errors}} -> {Pass, wh_json:set_value(<<"callflows">>, Errors, Fail)}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will loop over the prevously generated context records
%% providing each to the respective 'put' binding in order to create
%% the objects.  Starts with the account :)
%% @end
%%--------------------------------------------------------------------
-spec populate_new_account(proplist(), cb_context:context()) -> cb_context:context().
-spec populate_new_account(proplist(), ne_binary(), wh_json:object()) -> wh_json:object().

populate_new_account(Props, _) ->
    Context = props:get_value(?WH_ACCOUNTS_DB, Props),
    Context1 = crossbar_bindings:fold(<<"*.execute.put.accounts">>, [cb_context:set_resp_status(Context, 'error')]),
    AccountDb = cb_context:account_db(Context1),
    AccountId = cb_context:account_id(Context1),
    case cb_context:response(Context1) of
        {'error', _} ->
            cb_context:setters(Context1, [{fun cb_context:set_account_id/2, 'undefined'}
                                          ,{fun cb_context:set_account_db/2, 'undefined'}
                                         ]);
        {'ok', _} ->
            Results = populate_new_account(prepare_props(Props), AccountDb, wh_json:new()),
            case wh_json:get_ne_value(<<"errors">>, Results) of
                'undefined' ->
                    lager:debug("new account created ~s (~s)", [AccountId, AccountDb]),
                    notfy_new_account(cb_context:doc(Context1)),
                    cb_context:set_doc(Context1, wh_json:set_value(<<"account_id">>, AccountId, Results));
                Failures ->
                    lager:debug("account creation errors: ~p", [Failures]),
                    catch (crossbar_bindings:fold(<<"*.execute.delete.accounts">>, [Context1, AccountId])),
                    Ctx2 = cb_context:setters(Context1, [{fun cb_context:set_doc/2, wh_json:delete_key(<<"owner_id">>, Results)}
                                                         ,{fun cb_context:set_account_id/2, 'undefined'}
                                                         ,{fun cb_context:set_account_db/2, 'undefined'}
                                                         ,{fun cb_context:set_resp_data/2, wh_json:new()}
                                                        ]),
                    crossbar_util:response_invalid_data(Failures, Ctx2)
            end
    end.

populate_new_account([], _, Results) ->
    Results;

populate_new_account([{<<"phone_numbers">>, Context}|Props], AccountDb, Results) ->
    Number = cb_context:fetch(Context, 'number'),
    AccountId = wh_util:format_account_id(AccountDb, 'raw'),
    Payload = [cb_context:setters(Context, [{fun cb_context:set_resp_status/2, 'error'}
                                            ,{fun cb_context:set_account_db/2, AccountDb}
                                            ,{fun cb_context:set_auth_account_id/2, AccountId}
                                            ,{fun cb_context:set_account_id/2, AccountId}
                                           ])
               ,Number
               ,<<"activate">>
              ],
    Context1 = crossbar_bindings:fold(<<"*.execute.put.phone_numbers">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> populate_new_account(Props, AccountDb, Results);
        {'error', {_, _, Errors}} ->
            populate_new_account(Props, AccountDb
                                 ,wh_json:set_value([<<"errors">>, <<"phone_numbers">>, Number], Errors, Results))
    end;

populate_new_account([{<<"braintree">>, Context}|Props], AccountDb, Results) ->
    AccountId = wh_util:format_account_id(AccountDb, 'raw'),
    Payload = [cb_context:setters(Context, [{fun cb_context:set_resp_status/2, 'error'}
                                            ,{fun cb_context:set_account_db/2, AccountDb}
                                            ,{fun cb_context:set_account_id/2, AccountId}
                                            ,{fun cb_context:set_req_verb/2, ?HTTP_POST}
                                           ])
               ,<<"customer">>
              ],
    Context1 = crossbar_bindings:fold(<<"*.execute.post.braintree">>, Payload),
    case cb_context:response(Context1) of
        {'ok', _} -> populate_new_account(Props, AccountDb, Results);
        {'error', {_, _, Errors}} ->
            populate_new_account(Props, AccountDb
                                 ,wh_json:set_value([<<"errors">>, <<"braintree">>], Errors, Results))
    end;

populate_new_account([{Event, Context}|Props], AccountDb, Results) ->
    Iteration = cb_context:fetch(Context, 'iteration'),
    Payload = [cb_context:setters(Context, [{fun cb_context:set_account_db/2, AccountDb}
                                            ,{fun cb_context:set_resp_status/2, 'error'}
                                           ])],
    Context1 = crossbar_bindings:fold(<<"*.execute.put.", Event/binary>>, Payload),
    JObj = cb_context:doc(Context1),
    case cb_context:response(Context1) of
        {'ok', _} ->
            case wh_json:get_value(<<"priv_level">>, JObj) of
                <<"admin">> ->
                    populate_new_account(Props, AccountDb
                                         ,wh_json:set_value(<<"owner_id">>, wh_doc:id(JObj), Results));
                _ ->
                    populate_new_account(Props, AccountDb, Results)
            end;
        {'error', {_, _, Errors}} ->
            populate_new_account(Props, AccountDb
                                 ,wh_json:set_value([<<"errors">>, Event, wh_util:to_binary(Iteration)], Errors, Results))
    end.

prepare_props(Props) ->
    lists:sort(fun({<<"braintree">>, _}, {_, _}) -> 'true';
                  (_, _) -> 'false'
               end, proplists:delete(?WH_ACCOUNTS_DB, Props)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Helper function to get the create object out of the successful
%% context records for a specific key.
%% @end
%%--------------------------------------------------------------------
-spec get_context_jobj(ne_binary(), proplist()) -> wh_json:object().
get_context_jobj(Key, Pass) ->
    case props:get_value(Key, Pass) of
        Context when is_tuple(Context) -> cb_context:doc(Context);
        _ -> wh_json:new()
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to create a token and save it to the token db
%% @end
%%--------------------------------------------------------------------
-spec create_response(cb_context:context()) -> cb_context:context().
create_response(Context) ->
    JObj = cb_context:doc(Context),
    case cb_context:account_id(Context) of
        'undefined' ->
            crossbar_util:response_invalid_data(JObj, Context);
        AccountId ->
            Token = [{<<"account_id">>, AccountId}
                     ,{<<"owner_id">>, wh_json:get_value(<<"owner_id">>, JObj)}
                     ,{<<"created">>, calendar:datetime_to_gregorian_seconds(calendar:universal_time())}
                     ,{<<"modified">>, calendar:datetime_to_gregorian_seconds(calendar:universal_time())}
                     ,{<<"method">>, wh_util:to_binary(?MODULE)}
                    ],
            case couch_mgr:save_doc(?KZ_TOKEN_DB, wh_json:from_list(Token)) of
                {'ok', Doc} ->
                    AuthToken = wh_doc:id(Doc),
                    lager:debug("created new local auth token ~s", [AuthToken]),
                    Context1 = cb_context:setters(Context, [{fun cb_context:set_auth_token/2, AuthToken}
                                                            ,{fun cb_context:set_auth_doc/2, Doc}
                                                           ]),
                    crossbar_util:response(wh_json:set_value(<<"auth_token">>, AuthToken, JObj), Context1);
                {'error', R} ->
                    lager:debug("could not create new local auth token, ~p", [R]),
                    crossbar_util:response('error', 'undefined', 400, JObj, Context)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to create a token and save it to the token db
%% @end
%%--------------------------------------------------------------------
-spec notfy_new_account(wh_json:object()) -> 'ok'.
notfy_new_account(JObj) ->
    Notify = [{<<"Account-Name">>, kz_account:name(JObj)}
              ,{<<"Account-Realm">>, kz_account:realm(JObj)}
              ,{<<"Account-API-Key">>, kz_account:api_key(JObj)}
              ,{<<"Account-ID">>, wh_doc:account_id(JObj)}
              ,{<<"Account-DB">>, wh_doc:account_db(JObj)}
              | wh_api:default_headers(?APP_VERSION, ?APP_NAME)
             ],
    wapi_notifications:publish_new_account(Notify).

-spec generate_username(api_binary(), api_binary(), api_binary()) ->
                               ne_binary().
generate_username('undefined', 'undefined', _) ->
    wh_util:rand_hex_binary(3);
generate_username('undefined', _, 'undefined') ->
    wh_util:rand_hex_binary(3);
generate_username('undefined', <<FirstLetter:1/binary, _/binary>>, LastName) ->
    <<FirstLetter/binary, (wh_util:to_binary(LastName))/binary>>;
generate_username(Email, _, _) ->
    Email.
