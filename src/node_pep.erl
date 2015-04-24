%%% ====================================================================
%%% ``The contents of this file are subject to the Erlang Public License,
%%% Version 1.1, (the "License"); you may not use this file except in
%%% compliance with the License. You should have received a copy of the
%%% Erlang Public License along with this software. If not, it can be
%%% retrieved via the world wide web at http://www.erlang.org/.
%%%
%%%
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%%
%%%
%%% The Initial Developer of the Original Code is ProcessOne.
%%% Portions created by ProcessOne are Copyright 2006-2015, ProcessOne
%%% All Rights Reserved.''
%%% This software is copyright 2006-2015, ProcessOne.
%%%
%%% @copyright 2006-2015 ProcessOne
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
%%% ====================================================================

-module(node_pep).
-behaviour(gen_pubsub_node).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").
-include("logger.hrl").

%%% @doc The module <strong>{@module}</strong> is the pep PubSub plugin.
%%% <p>PubSub plugin nodes are using the {@link gen_pubsub_node} behaviour.</p>

-export([init/3, terminate/2, options/0, features/0,
    create_node_permission/6, create_node/2, delete_node/1,
    purge_node/2, subscribe_node/8, unsubscribe_node/4,
    publish_item/6, delete_item/4, remove_extra_items/3,
    get_entity_affiliations/2, get_node_affiliations/1,
    get_affiliation/2, set_affiliation/3,
    get_entity_subscriptions/2, get_node_subscriptions/1,
    get_subscriptions/2, set_subscriptions/4,
    get_pending_nodes/2, get_states/1, get_state/2,
    set_state/1, get_items/7, get_items/3, get_item/7,
    get_item/2, set_item/1, get_item_name/3, node_to_path/1,
    path_to_node/1]).

init(Host, ServerHost, Opts) ->
    node_hometree:init(Host, ServerHost, Opts),
    complain_if_modcaps_disabled(ServerHost),
    ok.

terminate(Host, ServerHost) ->
    node_hometree:terminate(Host, ServerHost), ok.

options() ->
    [{deliver_payloads, true},
	{notify_config, false},
	{notify_delete, false},
	{notify_retract, false},
	{purge_offline, false},
	{persist_items, false},
	{max_items, 1},
	{subscribe, true},
	{access_model, presence},
	{roster_groups_allowed, []},
	{publish_model, publishers},
	{notification_type, headline},
	{max_payload_size, ?MAX_PAYLOAD_SIZE},
	{send_last_published_item, on_sub_and_presence},
	{deliver_notifications, true},
	{presence_based_delivery, true}].

features() ->
    [<<"create-nodes">>,
	<<"auto-create">>,
	<<"auto-subscribe">>,
	<<"delete-nodes">>,
	<<"delete-items">>,
	<<"filtered-notifications">>,
	<<"modify-affiliations">>,
	<<"outcast-affiliation">>,
	<<"persistent-items">>,
	<<"publish">>,
	<<"purge-nodes">>,
	<<"retract-items">>,
	<<"retrieve-affiliations">>,
	<<"retrieve-items">>,
	<<"retrieve-subscriptions">>,
	<<"subscribe">>].

create_node_permission(Host, ServerHost, _Node, _ParentNode, Owner, Access) ->
    LOwner = jlib:jid_tolower(Owner),
    {User, Server, _Resource} = LOwner,
    Allowed = case LOwner of
	{<<"">>, Host, <<"">>} ->
	    true; % pubsub service always allowed
	_ ->
	    case acl:match_rule(ServerHost, Access, LOwner) of
		allow ->
		    case Host of
			{User, Server, _} -> true;
			_ -> false
		    end;
		_ ->
		    false
	    end
    end,
    {result, Allowed}.

create_node(Nidx, Owner) ->
    node_hometree:create_node(Nidx, Owner).

delete_node(Nodes) ->
    {result, {_, _, Result}} = node_hometree:delete_node(Nodes),
    {result, {[], Result}}.

subscribe_node(Nidx, Sender, Subscriber, AccessModel,
	    SendLast, PresenceSubscription, RosterGroup, Options) ->
    node_hometree:subscribe_node(Nidx, Sender, Subscriber, AccessModel, SendLast,
	PresenceSubscription, RosterGroup, Options).

unsubscribe_node(Nidx, Sender, Subscriber, SubId) ->
    case node_hometree:unsubscribe_node(Nidx, Sender, Subscriber, SubId) of
	{error, Error} -> {error, Error};
	{result, _} -> {result, []}
    end.

publish_item(Nidx, Publisher, Model, MaxItems, ItemId, Payload) ->
    node_hometree:publish_item(Nidx, Publisher, Model, MaxItems, ItemId, Payload).

remove_extra_items(Nidx, MaxItems, ItemIds) ->
    node_hometree:remove_extra_items(Nidx, MaxItems, ItemIds).

delete_item(Nidx, Publisher, PublishModel, ItemId) ->
    node_hometree:delete_item(Nidx, Publisher, PublishModel, ItemId).

purge_node(Nidx, Owner) ->
    node_hometree:purge_node(Nidx, Owner).

get_entity_affiliations(Host, Owner) ->
    {_, D, _} = SubKey = jlib:jid_tolower(Owner),
    SubKey = jlib:jid_tolower(Owner),
    GenKey = jlib:jid_remove_resource(SubKey),
    States = mnesia:match_object(#pubsub_state{stateid = {GenKey, '_'}, _ = '_'}),
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (#pubsub_state{stateid = {_, N}, affiliation = A}, Acc) ->
		    case NodeTree:get_node(N) of
			#pubsub_node{nodeid = {{_, D, _}, _}} = Node -> [{Node, A} | Acc];
			_ -> Acc
		    end
	    end,
	    [], States),
    {result, Reply}.


get_node_affiliations(Nidx) ->
    node_hometree:get_node_affiliations(Nidx).

get_affiliation(Nidx, Owner) ->
    node_hometree:get_affiliation(Nidx, Owner).

set_affiliation(Nidx, Owner, Affiliation) ->
    node_hometree:set_affiliation(Nidx, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    {U, D, _} = SubKey = jlib:jid_tolower(Owner),
    GenKey = jlib:jid_remove_resource(SubKey),
    States = case SubKey of
	GenKey ->
	    mnesia:match_object(#pubsub_state{stateid = {{U, D, '_'}, '_'}, _ = '_'});
	_ ->
	    mnesia:match_object(#pubsub_state{stateid = {GenKey, '_'}, _ = '_'})
	    ++
	    mnesia:match_object(#pubsub_state{stateid = {SubKey, '_'}, _ = '_'})
    end,
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (#pubsub_state{stateid = {J, N}, subscriptions = Ss}, Acc) ->
		    case NodeTree:get_node(N) of
			#pubsub_node{nodeid = {{_, D, _}, _}} = Node ->
			    lists:foldl(fun
				    ({subscribed, SubId}, Acc2) ->
					[{Node, subscribed, SubId, J} | Acc2];
				    ({pending, _SubId}, Acc2) ->
					[{Node, pending, J} | Acc2];
				    (S, Acc2) ->
					[{Node, S, J} | Acc2]
				end,
				Acc, Ss);
			_ ->
			    Acc
		    end
	    end,
	    [], States),
    {result, Reply}.

get_node_subscriptions(Nidx) ->
    node_hometree:get_node_subscriptions(Nidx).

get_subscriptions(Nidx, Owner) ->
    node_hometree:get_subscriptions(Nidx, Owner).

set_subscriptions(Nidx, Owner, Subscription, SubId) ->
    node_hometree:set_subscriptions(Nidx, Owner, Subscription, SubId).

get_pending_nodes(Host, Owner) ->
    node_hometree:get_pending_nodes(Host, Owner).

get_states(Nidx) ->
    node_hometree:get_states(Nidx).

get_state(Nidx, JID) ->
    node_hometree:get_state(Nidx, JID).

set_state(State) ->
    node_hometree:set_state(State).

get_items(Nidx, From, RSM) ->
    node_hometree:get_items(Nidx, From, RSM).

get_items(Nidx, JID, AccessModel, PresenceSubscription, RosterGroup, SubId, RSM) ->
    node_hometree:get_items(Nidx, JID, AccessModel,
	PresenceSubscription, RosterGroup, SubId, RSM).

get_item(Nidx, ItemId) ->
    node_hometree:get_item(Nidx, ItemId).

get_item(Nidx, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_hometree:get_item(Nidx, ItemId, JID, AccessModel,
	PresenceSubscription, RosterGroup, SubId).

set_item(Item) ->
    node_hometree:set_item(Item).

get_item_name(Host, Node, Id) ->
    node_hometree:get_item_name(Host, Node, Id).

node_to_path(Node) ->
    node_flat:node_to_path(Node).

path_to_node(Path) ->
    node_flat:path_to_node(Path).

%%%
%%% Internal
%%%

%% @doc Check mod_caps is enabled, otherwise show warning.
%% The PEP plugin for mod_pubsub requires mod_caps to be enabled in the host.
%% Check that the mod_caps module is enabled in that Jabber Host
%% If not, show a warning message in the ejabberd log file.
complain_if_modcaps_disabled(ServerHost) ->
    case gen_mod:is_loaded(ServerHost, mod_caps) of
	false ->
	    ?WARNING_MSG("The PEP plugin is enabled in mod_pubsub "
		"of host ~p. This plugin requires mod_caps "
		"to be enabled, but it isn't.",
		[ServerHost]);
	true -> ok
    end.
