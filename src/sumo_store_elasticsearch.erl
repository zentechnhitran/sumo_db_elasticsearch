%%% @hidden
%%% @doc ElasticSearch store implementation.
%%%
%%% Copyright 2012 Inaka &lt;hello@inaka.net&gt;
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Inaka <hello@inaka.net>
%%%
-module(sumo_store_elasticsearch).
-author("Juan Facorro <juan@inaka.net>").
-license("Apache License 2.0").

-behavior(sumo_store).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Exports.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Public API.
-export([
         init/1,
         create_schema/2,
         persist/2,
         find_by/3,
         find_by/5,
         find_by/6,
         find_all/2,
         find_all/5,
         delete_by/3,
         delete_all/2
        ]).

-export([
  sleep/1,
  wakeup/1
  ]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Types.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-type state() ::
        #{index => binary(),
          pool_name => atom()}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% External API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec init(term()) -> {ok, term()}.
init(Options) ->
  lager:debug("sumo elastic options: ~p~n",[Options]),
    %% ElasticSearch client uses poolboy to handle its own pool of workers
    %% so no pool is required.
    Backend = proplists:get_value(storage_backend, Options),
    % Index = case sumo_backend_elasticsearch:get_index(Backend) of
    %             Idx when is_list(Idx) -> list_to_binary(Idx);
    %             Idx when is_binary(Idx) -> Idx;
    %             _ -> throw(invalid_index)
    %         end,
    Index = 
    case proplists:get_value(index, Options, <<>>) of
      Idx when is_list(Idx) -> list_to_binary(Idx);
      Idx when is_binary(Idx) -> Idx;
       _ -> throw(invalid_index)
     end,
    PoolName = sumo_backend_elasticsearch:get_pool_name(Backend),

    {ok, #{index => Index, pool_name => PoolName}}.

-spec persist(sumo_internal:doc(), state()) ->
  sumo_store:result(sumo_internal:doc(), state()).
persist(Doc, #{index := Index, pool_name := PoolName} = State) ->
  lager:debug("Elastic persist: State: ~p, Doc: ~p~n",[State, Doc]),
    DocName = sumo_internal:doc_name(Doc),
    Type = atom_to_binary(DocName, utf8),

    IdField = sumo_internal:id_field_name(DocName),
    Id =  sumo_internal:get_field(IdField, Doc),

    NewDoc = sleep(Doc),
     lager:debug("Elastic persit: NewDoc: ~p~n",[NewDoc]),
    Fields = sumo_internal:doc_fields(NewDoc),
    lager:debug("Elastic persit: Fields: ~p~n",[Fields]),
    {ok, _Json} = tirerl:insert_doc(PoolName, Index, Type, Id, Fields),
   {UpdateId, Update} =  {Id, #{doc => Fields}},
    % {UpdateId, Update} =
    %     case Id of
    %         undefined ->
    %             {ok, Json} =
    %                 tirerl:insert_doc(PoolName, Index, Type, Id, Fields),
    %             %% Get the Id that was assigned by elasticsearch.
    %             GenId = maps:get(<<"_id">>, Json),
    %             {GenId, #{doc => maps:from_list([{IdField, GenId}])}};
    %         Id ->
    %             {Id, #{doc => Fields}}
    %     end,
    {ok, _ } = tirerl:update_doc(PoolName, Index, Type, UpdateId, Update),
    Doc1 = sumo_internal:set_field(IdField, UpdateId, Doc),

    {ok, Doc1, State}.

-spec delete_by(sumo:schema_name(), sumo:conditions(), state()) ->
  sumo_store:result(sumo_store:affected_rows(), state()).
delete_by(DocName,
          Conditions,
          #{index := Index, pool_name := PoolName} = State) ->
    Query = build_query(Conditions),
    Type = atom_to_binary(DocName, utf8),

    Count = count(PoolName, Index, Type, Query, []),
    ok = delete_by_query(PoolName, Index, Type, Query, []),

    {ok, Count, State}.

-spec delete_all(sumo:schema_name(), state()) ->
  sumo_store:result(sumo_store:affected_rows(), state()).
delete_all(DocName, #{index := Index, pool_name := PoolName} = State) ->
    Type = atom_to_binary(DocName, utf8),
    MatchAll = #{query => #{match_all => #{}}},

    Count = count(PoolName, Index, Type, MatchAll, []),
    ok = delete_by_query(PoolName, Index, Type, MatchAll, []),

    {ok, Count, State}.

-spec find_by(sumo:schema_name(),
              sumo:conditions(),
              non_neg_integer(),
              non_neg_integer(),
              state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_by(DocName, Conditions, Limit, Offset,
        #{index := Index, pool_name := PoolName} = State) ->
    lager:debug("find_by/5: DocName: ~p, Conditions: ~p, Limit: ~p, Offset: ~p, State: ~p~n",[DocName, Conditions, Limit, Offset, State]),
    Type = atom_to_binary(DocName, utf8),
    Query = build_query(Conditions, Limit, Offset),
    Params = [
  %  {<<"content-type">>, <<"application/json">>}
    ],
    lager:debug("PoolName: ~p, Index: ~p, Type: ~p, Query: ~p, Params: ~p~n",[PoolName, Index, Type, Query, Params]),
    SearchResults = tirerl:search(PoolName, Index, Type, Query),
    lager:debug("search result: ~p~n",[SearchResults]),
    {ok, #{<<"hits">> := #{<<"hits">> := Results}}} =SearchResults,
    %    tirerl:search(PoolName, Index, Type, Query),

    Fun = fun(Item) -> wakeup(map_to_doc(DocName, Item)) end,
    Docs = lists:map(Fun, Results),

    {ok, Docs, State}.

-spec find_by(sumo:schema_name(),
              sumo:conditions(),
              sumo:sort(),
              non_neg_integer(),
              non_neg_integer(),
              state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_by(_DocName, _Conditions, _SortFields, _Limit, _Offset, State) ->
lager:debug("find_by/6: DocName: ~p, Conditions: ~p, Sort: ~p, Limit: ~p, Offset: ~p, State: ~p~n",[_DocName, _Conditions, _SortFields, _Limit, _Offset, State]),
    {error, not_supported, State}.

-spec find_by(sumo:schema_name(), sumo:conditions(), state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_by(DocName, Conditions, State) ->
    find_by(DocName, Conditions, 0, 0, State).

-spec find_all(sumo:schema_name(), state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_all(DocName, State) ->
    find_by(DocName, [], State).

-spec find_all(sumo:schema_name(),
               term(),
               non_neg_integer(),
               non_neg_integer(),
               state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_all(DocName, _OrderField, Limit, Offset, State) ->
    find_by(DocName, [], Limit, Offset, State).

-spec create_schema(sumo:schema(), state()) -> sumo_store:result(state()).
create_schema(Schema, #{index := Index, pool_name := PoolName} = State) ->
    lager:debug("create schema: ~p, State: ~p~n",[Schema, State]),
    SchemaName = sumo_internal:schema_name(Schema),
    Type = atom_to_binary(SchemaName, utf8),
    Fields = sumo_internal:schema_fields(Schema),
    Mapping = build_mapping(SchemaName, Fields),
    lager:debug("Is Index 2: ~p~n",[Index]),
     lager:debug("put_mapping Index: ~p, Type: ~p, Mapping: ~p~n",[Index, Type, Mapping]),
    _ = case tirerl:is_index(PoolName, Index) of
        false -> tirerl:create_index(PoolName, Index);
        _ -> ok
    end,
    

    {ok, _} = tirerl:put_mapping(PoolName, Index, Type, Mapping),

    {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal Functions.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

map_to_doc(DocName, Item) ->
    Values = maps:get(<<"_source">>, Item),
    IdField = sumo_internal:id_field_name(DocName),

    Fun = fun (Key, Doc) ->
              FieldName = binary_to_atom(Key, utf8),
              Value = maps:get(Key, Values),
              sumo_internal:set_field(FieldName, Value, Doc)
          end,
    Keys = maps:keys(Values),
    Doc = lists:foldl(Fun, sumo_internal:new_doc(DocName), Keys),
    sumo_internal:set_field(IdField, maps:get(<<"_id">>, Item), Doc).

build_query(Conditions) ->
    build_query(Conditions, 0, 0).

build_query(Conditions, Limit, Offset) ->
    Query = build_query_conditions(Conditions),
    case Limit of
        0 -> Query;
        _ -> Query#{from => Offset,
                    size => Limit}
    end.

build_query_conditions([]) ->
    #{};
build_query_conditions(Conditions) when is_list(Conditions) ->
    QueryConditions = lists:map(fun build_query_conditions/1, Conditions),
    #{query => #{bool => #{must => QueryConditions}}};
build_query_conditions({Key, Value}) when is_list(Value) ->
    #{match => maps:from_list([{Key, list_to_binary(Value)}])};
build_query_conditions({Key, Value}) ->
    #{match => maps:from_list([{Key, Value}])};
build_query_conditions(Expr) ->
    throw({unimplemented_expression, Expr}).

build_mapping(_MappingType, Fields) ->
    Fun =
        fun
            (Field, Acc) ->
                Name = sumo_internal:field_name(Field),
                FieldType = normalize_type(sumo_internal:field_type(Field)),
                maps:put(Name, #{type => FieldType}, Acc)
        end,
    Properties = lists:foldl(Fun, #{}, Fields),
    io:format("Properties: ~p~n",[Properties]),
    %maps:from_list([#{'mappings' => #{'_doc' => #{properties => Properties}}}, #{'settings' => #{index =>  #{number_of_shards =>  1, number_of_replicas => 1}}}]).
    maps:from_list([{'mappings' , #{'_doc' => #{properties => Properties}}},{'settings' , #{index =>  #{number_of_shards =>  1, number_of_replicas => 1}}}]).
% https://www.elastic.co/guide/en/elasticsearch/reference/6.4/sql-data-types.html

normalize_type(date) -> date;
normalize_type(datetime) -> date;
normalize_type(custom) -> text;
normalize_type(string) -> text;
normalize_type(binary) -> text;
%normalize_type(_Type) -> text.
% boolean, float, integer, nested, object
normalize_type(Type) -> 
lager:debug("normalize_type: ~p~n",[Type]),
Type.

%% @private
count(PoolName, Index, Type, Query, Params) ->
    {ok, #{<<"count">> := Count}} =
        tirerl:count(PoolName, Index, Type, Query, Params),
    Count.

%% @private
delete_by_query(PoolName, Index, Type, Query, Params) ->
  {ok, _} = tirerl:delete_by_query(PoolName, Index, Type, Query, Params),
  ok.

-spec sleep(term()) -> term().
%% @private
sleep(Doc) ->
    sumo_utils:doc_transform(fun sleep_fun/1, Doc).

%% @private

sleep_fun({FieldType, _, FieldValue}) when FieldType =:= datetime;
                                           FieldType =:= date ->
    case {FieldType, sumo_utils:is_datetime(FieldValue)} of
      {date, true}     -> iso8601:format({FieldValue, {0, 0, 0}});
      {datetime, true} -> iso8601:format(FieldValue);
      _                -> FieldValue
    end;
sleep_fun({_, _, undefined}) ->
    null;
sleep_fun({custom, _, FieldValue}) ->
    base64:encode(term_to_binary(FieldValue));
sleep_fun({_, _, FieldValue}) ->
    FieldValue.

% sleep_fun(FieldType, _, FieldValue, _) when FieldType =:= datetime;
%                                            FieldType =:= date ->
%     case {FieldType, sumo_utils:is_datetime(FieldValue)} of
%       {date, true}     -> iso8601:format({FieldValue, {0, 0, 0}});
%       {datetime, true} -> iso8601:format(FieldValue);
%       _                -> FieldValue
%     end;
% sleep_fun(_, _, undefined, _) ->
%     null;
% sleep_fun(custom, _, FieldValue, _) ->
%     base64:encode(term_to_binary(FieldValue));
% sleep_fun(_, _, FieldValue, _) ->
%     FieldValue.

%% @private
-spec wakeup(term()) -> term().
wakeup(Doc) ->
    sumo_utils:doc_transform(fun wakeup_fun/1, Doc).

%% @private
wakeup_fun({datetime, _, FieldValue}) ->
    iso8601:parse(FieldValue);
wakeup_fun({date, _, FieldValue}) ->
    {Date, _} = iso8601:parse(FieldValue),
    Date;
wakeup_fun({_, _, null}) ->
    undefined;
wakeup_fun({custom, _, FieldValue}) ->
    binary_to_term(base64:decode(FieldValue));
wakeup_fun({_, _, FieldValue}) ->
    FieldValue.

% wakeup_fun(datetime, _, FieldValue, _) ->
%     iso8601:parse(FieldValue);
% wakeup_fun(date, _, FieldValue, _) ->
%     {Date, _} = iso8601:parse(FieldValue),
%     Date;
% wakeup_fun(_, _, null, _) ->
%     undefined;
% wakeup_fun(custom, _, FieldValue, _) ->
%     binary_to_term(base64:decode(FieldValue));
% wakeup_fun(_, _, FieldValue, _) ->
%     FieldValue.    