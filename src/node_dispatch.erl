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

-module(node_dispatch).
-behaviour(gen_pubsub_node).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").

%%% @doc <p>The <strong>{@module}</strong> module is a PubSub plugin whose
%%% goal is to republished each published item to all its children.</p>
%%% <p>Users cannot subscribe to this node, but are supposed to subscribe to
%%% its children.</p>
%%% This module can not work with virtual nodetree

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
    node_hometree:init(Host, ServerHost, Opts).

terminate(Host, ServerHost) ->
    node_hometree:terminate(Host, ServerHost).

options() ->
    [{deliver_payloads, true},
	{notify_config, false},
	{notify_delete, false},
	{notify_retract, true},
	{purge_offline, false},
	{persist_items, true},
	{max_items, ?MAXITEMS},
	{subscribe, true},
	{access_model, presence},
	{roster_groups_allowed, []},
	{publish_model, publishers},
	{notification_type, headline},
	{max_payload_size, ?MAX_PAYLOAD_SIZE},
	{send_last_published_item, never},
	{deliver_notifications, true},
	{presence_based_delivery, false}].

features() ->
    [<<"create-nodes">>,
	<<"delete-nodes">>,
	<<"instant-nodes">>,
	<<"outcast-affiliation">>,
	<<"persistent-items">>,
	<<"publish">>,
	<<"retrieve-items">>].

create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access) ->
    node_hometree:create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access).

create_node(Nidx, Owner) ->
    node_hometree:create_node(Nidx, Owner).

delete_node(Nodes) ->
    node_hometree:delete_node(Nodes).

subscribe_node(_Nidx, _Sender, _Subscriber, _AccessModel, _SendLast, _PresenceSubscription,
	    _RosterGroup, _Options) ->
    {error, ?ERR_FORBIDDEN}.

unsubscribe_node(_Nidx, _Sender, _Subscriber, _SubId) ->
    {error, ?ERR_FORBIDDEN}.

publish_item(Nidx, Publisher, PublishModel, MaxItems, ItemId, Payload) ->
    case nodetree_tree:get_node(Nidx) of
	#pubsub_node{nodeid = {Host, Node}} ->
	    lists:foreach(fun (SubNode) ->
			node_hometree:publish_item(SubNode#pubsub_node.id,
			    Publisher, PublishModel, MaxItems,
			    ItemId, Payload)
		end,
		nodetree_tree:get_subnodes(Host, Node, Publisher)),
	    {result, {default, broadcast, []}};
	Error ->
	    Error
    end.

remove_extra_items(_Nidx, _MaxItems, ItemIds) ->
    {result, {ItemIds, []}}.

delete_item(_Nidx, _Publisher, _PublishModel, _ItemId) ->
    {error, ?ERR_ITEM_NOT_FOUND}.

purge_node(_Nidx, _Owner) ->
    {error, ?ERR_FORBIDDEN}.

get_entity_affiliations(_Host, _Owner) ->
    {result, []}.

get_node_affiliations(_Nidx) ->
    {result, []}.

get_affiliation(_Nidx, _Owner) ->
    {result, none}.

set_affiliation(Nidx, Owner, Affiliation) ->
    node_hometree:set_affiliation(Nidx, Owner, Affiliation).

get_entity_subscriptions(_Host, _Owner) ->
    {result, []}.

get_node_subscriptions(Nidx) ->
    node_hometree:get_node_subscriptions(Nidx).

get_subscriptions(_Nidx, _Owner) ->
    {result, []}.

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
