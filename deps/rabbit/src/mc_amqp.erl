-module(mc_amqp).
-behaviour(mc).

-include_lib("amqp10_common/include/amqp10_framing.hrl").
-include("mc.hrl").

-export([
         init/1,
         size/1,
         x_header/2,
         property/2,
         routing_headers/2,
         convert_to/3,
         convert_from/3,
         protocol_state/2,
         prepare/2
        ]).

-import(rabbit_misc,
        [maps_put_truthy/3,
         maps_put_falsy/3
        ]).

-type message_section() ::
    #'v1_0.header'{} |
    #'v1_0.delivery_annotations'{} |
    #'v1_0.message_annotations'{} |
    #'v1_0.properties'{} |
    #'v1_0.application_properties'{} |
    #'v1_0.data'{} |
    #'v1_0.amqp_sequence'{} |
    #'v1_0.amqp_value'{} |
    #'v1_0.footer'{}.

-define(SIMPLE_VALUE(V), is_binary(V) orelse
                         is_number(V) orelse
                         is_boolean(V)).

-type amqp10_data() :: [#'v1_0.amqp_sequence'{} | #'v1_0.data'{}] | #'v1_0.amqp_value'{}.
-type amqp_map() :: [{term(), term()}].
-type opt(T) :: T | undefined.

%% This representation is used when the message was originally sent with
%% a protocol other than AMQP and the message was not read from a stream.
-record(msg_body_decoded,
        {
         header :: opt(#'v1_0.header'{}),
         delivery_annotations = []:: list(),
         message_annotations = [] :: list(),
         properties :: opt(#'v1_0.properties'{}),
         application_properties = [] :: list(),
         data = [] :: amqp10_data(),
         footer = [] :: list()
        }).

%% This representation is used when we received the message from
%% an AMQP client or when we read the message from a stream.
%% This message was parsed up to the section preceding the body.
-record(msg_body_encoded,
        {
         header :: opt(#'v1_0.header'{}),
         delivery_annotations = [] :: amqp_map(),
         message_annotations = [] :: amqp_map(),
         properties :: opt(#'v1_0.properties'{}),
         application_properties = [] :: amqp_map(),
         bare_and_footer = uninit :: uninit | binary(),
         %% byte position within bare_and_footer where body starts
         bare_and_footer_body_pos = uninit :: uninit | non_neg_integer()
        }).

%% This representation is how we store the message on disk in classic queues
%% and quorum queues. For better performance and less disk usage, we omit the
%% header because the header fields we're interested in are already set as mc
%% annotations. We store the original bare message unaltered to preserve
%% message hashes on the binary encoding of the bare message [§3.2].
%% The record is called v1 just in case we ever want to introduce a new v2
%% on disk representation in the future.
-record(v1,
        {
         delivery_annotations = [] :: amqp_map(),
         message_annotations = [] :: amqp_map(),
         bare_and_footer :: binary()
        }).

-opaque state() :: #msg_body_decoded{} | #msg_body_encoded{} | #v1{}.

-export_type([
              state/0,
              message_section/0
             ]).

init(Payload) when is_binary(Payload) ->
    Sections = amqp10_framing:decode_bin(Payload, [server_mode]),
    Msg = msg_body_encoded(Sections, Payload),
    Anns = essential_properties(Msg),
    {Msg, Anns}.

convert_from(?MODULE, Sections, _Env) when is_list(Sections) ->
    msg_body_decoded(Sections);
convert_from(_SourceProto, _, _Env) ->
    not_implemented.

convert_to(?MODULE, Msg, _Env) ->
    Msg;
convert_to(TargetProto, Msg, Env) ->
    TargetProto:convert_from(?MODULE, msg_to_sections(Msg), Env).

size(#v1{bare_and_footer = Body}) ->
    {_MetaSize = 0, byte_size(Body)}.

x_header(Key, Msg) ->
    message_annotation(Key, Msg, undefined).

property(correlation_id, #msg_body_encoded{properties = #'v1_0.properties'{correlation_id = Corr}}) ->
    Corr;
property(message_id, #msg_body_encoded{properties = #'v1_0.properties'{message_id = MsgId}}) ->
    MsgId;
property(user_id, #msg_body_encoded{properties = #'v1_0.properties'{user_id = UserId}}) ->
    UserId;
property(subject, #msg_body_encoded{properties = #'v1_0.properties'{subject = Subject}}) ->
    Subject;
property(to, #msg_body_encoded{properties = #'v1_0.properties'{to = To}}) ->
    To;
property(_Prop, #msg_body_encoded{}) ->
    undefined.

routing_headers(Msg, Opts) ->
    IncludeX = lists:member(x_headers, Opts),
    X = case IncludeX of
            true ->
                message_annotations_as_simple_map(Msg);
            false ->
                []
        end,
    List = application_properties_as_simple_map(Msg, X),
    maps:from_list(List).

get_property(durable, Msg) ->
    case Msg of
        #msg_body_encoded{header = #'v1_0.header'{durable = Durable}}
          when is_boolean(Durable) ->
            Durable;
        #msg_body_encoded{header = #'v1_0.header'{durable = {boolean, Durable}}} ->
            Durable;
        _ ->
            %% fallback in case the source protocol was old AMQP 0.9.1
            case message_annotation(<<"x-basic-delivery-mode">>, Msg, 2) of
                {ubyte, 2} ->
                    true;
                _ ->
                    false
            end
    end;
get_property(timestamp, Msg) ->
    case Msg of
        #msg_body_encoded{properties = #'v1_0.properties'{creation_time = {timestamp, Ts}}} ->
            Ts;
        _ ->
            undefined
    end;
get_property(ttl, Msg) ->
    case Msg of
        #msg_body_encoded{header = #'v1_0.header'{ttl = {uint, Ttl}}} ->
            Ttl;
        _ ->
            %% fallback in case the source protocol was AMQP 0.9.1
            case message_annotation(<<"x-basic-expiration">>, Msg, undefined) of
                {utf8, Expiration}  ->
                    {ok, Ttl} = rabbit_basic:parse_expiration(Expiration),
                    Ttl;
                _ ->
                    undefined
            end
    end;
get_property(priority, Msg) ->
    case Msg of
        #msg_body_encoded{header = #'v1_0.header'{priority = {ubyte, Priority}}} ->
            Priority;
        _ ->
            %% fallback in case the source protocol was AMQP 0.9.1
            case message_annotation(<<"x-basic-priority">>, Msg, undefined) of
                {_, Priority}  ->
                    Priority;
                _ ->
                    undefined
            end
    end.

%% protocol_state/2 serialises the protocol state outputting an AMQP encoded message.
-spec protocol_state(state(), mc:annotations()) -> iolist().
protocol_state(Msg0 = #msg_body_decoded{header = Header0,
                                        message_annotations = MA0}, Anns) ->
    FirstAcquirer = first_acquirer(Anns),
    Header = case Header0 of
                 undefined ->
                     #'v1_0.header'{first_acquirer = FirstAcquirer};
                 #'v1_0.header'{} ->
                     Header0#'v1_0.header'{first_acquirer = FirstAcquirer}
             end,
    MA = protocol_state_message_annotations(MA0, Anns),
    Msg = Msg0#msg_body_decoded{header = Header,
                                message_annotations = MA},
    Sections = msg_to_sections(Msg),
    encode(Sections);
protocol_state(#msg_body_encoded{header = Header0,
                                 delivery_annotations = DA,
                                 message_annotations = MA0,
                                 bare_and_footer = BareAndFooter}, Anns) ->
    FirstAcquirer = first_acquirer(Anns),
    Header = case Header0 of
                 undefined ->
                     #'v1_0.header'{first_acquirer = FirstAcquirer};
                 #'v1_0.header'{} ->
                     Header0#'v1_0.header'{first_acquirer = FirstAcquirer}
             end,
    MA = protocol_state_message_annotations(MA0, Anns),
    Sections = to_sections(Header, DA, MA, []),
    [encode(Sections), BareAndFooter];
protocol_state(#v1{delivery_annotations = DA,
                   message_annotations = MA0,
                   bare_and_footer = BareAndFooter}, Anns) ->
    Durable = case Anns of
                  #{?ANN_DURABLE := D} -> D;
                  _ -> true
              end,
    Priority = case Anns of
                   #{?ANN_PRIORITY := P} -> {ubyte, P};
                   _ -> undefined
               end,
    Ttl = case Anns of
              #{ttl := V} -> {uint, V};
              _ -> undefined
          end,
    Header = #'v1_0.header'{durable = Durable,
                            priority = Priority,
                            ttl = Ttl,
                            first_acquirer = first_acquirer(Anns)},
    MA = protocol_state_message_annotations(MA0, Anns),
    Sections = to_sections(Header, DA, MA, []),
    [encode(Sections), BareAndFooter].

prepare(read, Msg) ->
    Msg;
prepare(store, Msg = #v1{}) ->
    Msg;
prepare(store, #msg_body_encoded{delivery_annotations = DA,
                                 message_annotations = MA,
                                 bare_and_footer = BF}) ->
    #v1{delivery_annotations = DA,
        message_annotations = MA,
        bare_and_footer = BF}.

%% internal

msg_to_sections(#msg_body_decoded{header = H,
                                  delivery_annotations = DAC,
                                  message_annotations = MAC,
                                  properties = P,
                                  application_properties = APC,
                                  data = Data,
                                  footer = FC}) ->
    S0 = case FC of
             [] ->
                 [];
             _ ->
                 [#'v1_0.footer'{content = FC}]
         end,
    S = case Data of
            #'v1_0.amqp_value'{} ->
                [Data | S0];
            _ when is_list(Data) ->
                Data ++ S0
        end,
    to_sections(H, DAC, MAC, P, APC, S);
msg_to_sections(#msg_body_encoded{header = H,
                                  delivery_annotations = DAC,
                                  message_annotations = MAC,
                                  properties = P,
                                  application_properties = APC,
                                  bare_and_footer = BareAndFooter,
                                  bare_and_footer_body_pos = BodyPos}) ->
    BodyAndFooterBin = binary_part(BareAndFooter,
                                   BodyPos,
                                   byte_size(BareAndFooter) - BodyPos),
    %% TODO do not parse entire AMQP encoded amqp-value or amqp-sequence section body
    BodyAndFooter = amqp10_framing:decode_bin(BodyAndFooterBin),
    to_sections(H, DAC, MAC, P, APC, BodyAndFooter);
msg_to_sections(#v1{delivery_annotations = DAC,
                    message_annotations = MAC,
                    bare_and_footer = BareAndFooterBin}) ->
    %% TODO do not parse entire AMQP encoded amqp-value or amqp-sequence section body
    BareAndFooter = amqp10_framing:decode_bin(BareAndFooterBin),
    to_sections(undefined, DAC, MAC, BareAndFooter).

to_sections(H, DAC, MAC, P, APC, Tail) ->
    S0 = case APC of
             [] ->
                 Tail;
             _ ->
                 [#'v1_0.application_properties'{content = APC} | Tail]
         end,
    S = case P of
            undefined ->
                S0;
            _ ->
                [P | S0]
        end,
    to_sections(H, DAC, MAC, S).

to_sections(H, DAC, MAC, Tail) ->
    S0 = case MAC of
             [] ->
                 Tail;
             _ ->
                 [#'v1_0.message_annotations'{content = MAC} | Tail]
         end,
    S = case DAC of
            [] ->
                S0;
            _ ->
                [#'v1_0.delivery_annotations'{content = DAC} | S0]
        end,
    case H of
        undefined ->
            S;
        _ ->
            [H | S]
    end.

-spec protocol_state_message_annotations(amqp_map(), mc:annotations()) -> amqp_map().
protocol_state_message_annotations(MA, Anns) ->
    maps:fold(
      fun(?ANN_EXCHANGE, Exchange, L) ->
              maps_upsert(<<"x-exchange">>, {utf8, Exchange}, L);
         (?ANN_ROUTING_KEYS, RKeys, L) ->
              RKey = hd(RKeys),
              maps_upsert(<<"x-routing-key">>, {utf8, RKey}, L);
         (<<"x-", _/binary>> = K, V, L)
           when V =/= undefined ->
              %% any x-* annotations get added as message annotations
              maps_upsert(K, mc_util:infer_type(V), L);
         (<<"timestamp_in_ms">>, V, L) ->
              maps_upsert(<<"x-opt-rabbitmq-received-time">>, {timestamp, V}, L);
         (_, _, Acc) ->
              Acc
      end, MA, Anns).

maps_upsert(Key, TaggedVal, KVList) ->
    TaggedKey = {symbol, Key},
    Elem = {TaggedKey, TaggedVal},
    lists:keystore(TaggedKey, 1, KVList, Elem).

encode(Sections) when is_list(Sections) ->
    [amqp10_framing:encode_bin(Section) || Section <- Sections,
                                           not is_empty(Section)].

is_empty(#'v1_0.header'{durable = undefined,
                        priority = undefined,
                        ttl = undefined,
                        first_acquirer = undefined,
                        delivery_count = undefined}) ->
    true;
is_empty(#'v1_0.delivery_annotations'{content = []}) ->
    true;
is_empty(#'v1_0.message_annotations'{content = []}) ->
    true;
is_empty(#'v1_0.properties'{message_id = undefined,
                            user_id = undefined,
                            to = undefined,
                            subject = undefined,
                            reply_to = undefined,
                            correlation_id = undefined,
                            content_type = undefined,
                            content_encoding = undefined,
                            absolute_expiry_time = undefined,
                            creation_time = undefined,
                            group_id = undefined,
                            group_sequence = undefined,
                            reply_to_group_id = undefined}) ->
    true;
is_empty(#'v1_0.application_properties'{content = []}) ->
    true;
is_empty(#'v1_0.footer'{content = []}) ->
    true;
is_empty(_) ->
    false.

message_annotation(_Key, #msg_body_encoded{message_annotations = []},
                   Default) ->
    Default;
message_annotation(Key, #msg_body_encoded{message_annotations = Content},
                   Default)
  when is_binary(Key) ->
    mc_util:amqp_map_get(Key, Content, Default).

message_annotations_as_simple_map(#msg_body_encoded{message_annotations = []}) ->
    [];
message_annotations_as_simple_map(#msg_body_encoded{message_annotations = Content}) ->
    %% the section record format really is terrible
    lists:filtermap(fun({{symbol, K}, {_T, V}})
                          when ?SIMPLE_VALUE(V) ->
                            {true, {K, V}};
                       (_) ->
                            false
                    end, Content).

application_properties_as_simple_map(#msg_body_encoded{application_properties = []}, L) ->
    L;
application_properties_as_simple_map(#msg_body_encoded{application_properties = Content},
                                     L) ->
    %% the section record format really is terrible
    lists:foldl(fun({{utf8, K}, {_T, V}}, Acc)
                      when ?SIMPLE_VALUE(V) ->
                        [{K, V} | Acc];
                   ({{utf8, K}, V}, Acc)
                     when V =:= undefined orelse is_boolean(V) ->
                        [{K, V} | Acc];
                   (_, Acc)->
                        Acc
                end, L, Content).

msg_body_decoded(Sections) ->
    msg_body_decoded(Sections, #msg_body_decoded{}).

msg_body_decoded([], Acc) ->
    Acc;
msg_body_decoded([#'v1_0.header'{} = H | Rem], Msg) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{header = H});
msg_body_decoded([#'v1_0.message_annotations'{content = MAC} | Rem], Msg) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{message_annotations = MAC});
msg_body_decoded([#'v1_0.properties'{} = P | Rem], Msg) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{properties = P});
msg_body_decoded([#'v1_0.application_properties'{content = APC} | Rem], Msg) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{application_properties = APC});
msg_body_decoded([#'v1_0.delivery_annotations'{content = DAC} | Rem], Msg) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{delivery_annotations = DAC});
msg_body_decoded([#'v1_0.data'{} = D | Rem], #msg_body_decoded{data = Body} = Msg)
  when is_list(Body) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{data = Body ++ [D]});
msg_body_decoded([#'v1_0.amqp_sequence'{} = D | Rem], #msg_body_decoded{data = Body} = Msg)
  when is_list(Body) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{data = Body ++ [D]});
msg_body_decoded([#'v1_0.footer'{content = FC} | Rem], Msg) ->
    msg_body_decoded(Rem, Msg#msg_body_decoded{footer = FC});
msg_body_decoded([#'v1_0.amqp_value'{} = B | Rem], #msg_body_decoded{} = Msg) ->
    %% an amqp value can only be a singleton
    msg_body_decoded(Rem, Msg#msg_body_decoded{data = B}).

msg_body_encoded(Sections, Payload) ->
    msg_body_encoded(Sections, Payload, #msg_body_encoded{}).

msg_body_encoded([#'v1_0.header'{} = H | Rem], Payload, Msg) ->
    msg_body_encoded(Rem, Payload, Msg#msg_body_encoded{header = H});
msg_body_encoded([#'v1_0.delivery_annotations'{content = DAC} | Rem], Payload, Msg) ->
    msg_body_encoded(Rem, Payload, Msg#msg_body_encoded{delivery_annotations = DAC});
msg_body_encoded([#'v1_0.message_annotations'{content = MAC} | Rem], Payload, Msg) ->
    msg_body_encoded(Rem, Payload, Msg#msg_body_encoded{message_annotations = MAC});
msg_body_encoded([{{pos, Pos}, #'v1_0.properties'{} = Props} | Rem], Payload, Msg) ->
    %% properties is the first bare message section
    Bin = binary_part_bare_and_footer(Payload, Pos),
    msg_body_encoded(Rem, Pos, Msg#msg_body_encoded{properties = Props,
                                                    bare_and_footer = Bin});
msg_body_encoded([{{pos, Pos}, #'v1_0.application_properties'{content = APC}} | Rem], Payload, Msg)
  when is_binary(Payload) ->
    %% application-properties is the first bare message section
    Bin = binary_part_bare_and_footer(Payload, Pos),
    msg_body_encoded(Rem, Pos, Msg#msg_body_encoded{application_properties = APC,
                                                    bare_and_footer = Bin});
msg_body_encoded([{{pos, _Pos}, #'v1_0.application_properties'{content = APC}} | Rem], BarePos, Msg)
  when is_integer(BarePos) ->
    msg_body_encoded(Rem, BarePos, Msg#msg_body_encoded{application_properties = APC});
%% Base case: we assert the last part contains the mandatory body:
msg_body_encoded([{{pos, Pos}, body}], Payload, Msg)
  when is_binary(Payload) ->
    %% The body is the first bare message section.
    Bin = binary_part_bare_and_footer(Payload, Pos),
    Msg#msg_body_encoded{bare_and_footer = Bin,
                         bare_and_footer_body_pos = 0};
msg_body_encoded([{{pos, Pos}, body}], BarePos, Msg)
  when is_integer(BarePos) ->
    Msg#msg_body_encoded{bare_and_footer_body_pos = Pos - BarePos}.

%% We extract the binary part of the payload exactly once when the bare message starts.
binary_part_bare_and_footer(Payload, Start) ->
    binary_part(Payload, Start, byte_size(Payload) - Start).

key_find(K, [{{_, K}, {_, V}} | _]) ->
    V;
key_find(K, [_ | Rem]) ->
    key_find(K, Rem);
key_find(_K, []) ->
    undefined.

-spec first_acquirer(mc:annotations()) -> boolean().
first_acquirer(Anns) ->
    Redelivered = case Anns of
                      #{redelivered := R} -> R;
                      _ -> false
                  end,
    not Redelivered.

recover_deaths([], Acc) ->
    Acc;
recover_deaths([{map, Kvs} | Rem], Acc) ->
    Queue = key_find(<<"queue">>, Kvs),
    Reason = binary_to_atom(key_find(<<"reason">>, Kvs)),
    DA0 = case key_find(<<"original-expiration">>, Kvs) of
              undefined ->
                  #{};
              Exp ->
                  #{ttl => binary_to_integer(Exp)}
          end,
    RKeys = [RK || {_, RK} <- key_find(<<"routing-keys">>, Kvs)],
    Ts = key_find(<<"time">>, Kvs),
    DA = DA0#{first_time => Ts,
              last_time => Ts},
    recover_deaths(Rem,
                   Acc#{{Queue, Reason} =>
                        #death{anns = DA,
                               exchange = key_find(<<"exchange">>, Kvs),
                               count = key_find(<<"count">>, Kvs),
                               routing_keys = RKeys}}).

essential_properties(#msg_body_encoded{message_annotations = MA} = Msg) ->
    Durable = get_property(durable, Msg),
    Priority = get_property(priority, Msg),
    Timestamp = get_property(timestamp, Msg),
    Ttl = get_property(ttl, Msg),

    Deaths = case message_annotation(<<"x-death">>, Msg, undefined) of
                 {list, DeathMaps}  ->
                     %% TODO: make more correct?
                     Def = {utf8, <<>>},
                     {utf8, FstQ} = message_annotation(<<"x-first-death-queue">>, Msg, Def),
                     {utf8, FstR} = message_annotation(<<"x-first-death-reason">>, Msg, Def),
                     {utf8, LastQ} = message_annotation(<<"x-last-death-queue">>, Msg, Def),
                     {utf8, LastR} = message_annotation(<<"x-last-death-reason">>, Msg, Def),
                     #deaths{first = {FstQ, binary_to_atom(FstR)},
                             last = {LastQ, binary_to_atom(LastR)},
                             records = recover_deaths(DeathMaps, #{})};
                 _ ->
                     undefined
             end,
    Anns = maps_put_falsy(
             ?ANN_DURABLE, Durable,
             maps_put_truthy(
               ?ANN_PRIORITY, Priority,
               maps_put_truthy(
                 ?ANN_TIMESTAMP, Timestamp,
                 maps_put_truthy(
                   ttl, Ttl,
                   maps_put_truthy(
                     deaths, Deaths,
                     #{}))))),
    case MA of
        [] ->
            Anns;
        _ ->
            lists:foldl(
              fun ({{symbol, <<"x-routing-key">>},
                    {utf8, Key}}, Acc) ->
                      maps:update_with(?ANN_ROUTING_KEYS,
                                       fun(L) -> [Key | L] end,
                                       [Key],
                                       Acc);
                  ({{symbol, <<"x-cc">>},
                    {list, CCs0}}, Acc) ->
                      CCs = [CC || {_T, CC} <- CCs0],
                      maps:update_with(?ANN_ROUTING_KEYS,
                                       fun(L) -> L ++ CCs end,
                                       CCs,
                                       Acc);
                  ({{symbol, <<"x-exchange">>},
                    {utf8, Exchange}}, Acc) ->
                      Acc#{?ANN_EXCHANGE => Exchange};
                  (_, Acc) ->
                      Acc
              end, Anns, MA)
    end.
