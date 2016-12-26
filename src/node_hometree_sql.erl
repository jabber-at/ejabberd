%%%----------------------------------------------------------------------
%%% File    : node_hometree_sql.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Standard tree ordered node plugin with ODBC backend
%%% Created :  1 Dec 2007 by Christophe Romain <christophe.romain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(node_hometree_sql).
-behaviour(gen_pubsub_node).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").

-export([init/3, terminate/2, options/0, features/0,
    create_node_permission/6, create_node/2, delete_node/1,
    purge_node/2, subscribe_node/8, unsubscribe_node/4,
    publish_item/7, delete_item/4, remove_extra_items/3,
    get_entity_affiliations/2, get_node_affiliations/1,
    get_affiliation/2, set_affiliation/3,
    get_entity_subscriptions/2, get_node_subscriptions/1,
    get_subscriptions/2, set_subscriptions/4,
    get_pending_nodes/2, get_states/1, get_state/2,
    set_state/1, get_items/7, get_items/3, get_item/7,
    get_item/2, set_item/1, get_item_name/3, node_to_path/1,
    path_to_node/1,
    get_entity_subscriptions_for_send_last/2, get_last_items/3]).

init(Host, ServerHost, Opts) ->
    node_flat_sql:init(Host, ServerHost, Opts),
    Owner = mod_pubsub:service_jid(Host),
    mod_pubsub:create_node(Host, ServerHost, <<"/home">>, Owner, <<"hometree">>),
    mod_pubsub:create_node(Host, ServerHost, <<"/home/", ServerHost/binary>>, Owner, <<"hometree">>),
    ok.

terminate(Host, ServerHost) ->
    node_flat_sql:terminate(Host, ServerHost).

options() ->
    [{sql, true}, {rsm, true} | node_hometree:options()].

features() ->
    [<<"rsm">> | node_hometree:features()].

create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access) ->
    node_hometree:create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access).

create_node(Nidx, Owner) ->
    node_flat_sql:create_node(Nidx, Owner).

delete_node(Nodes) ->
    node_flat_sql:delete_node(Nodes).

subscribe_node(Nidx, Sender, Subscriber, AccessModel,
	    SendLast, PresenceSubscription, RosterGroup, Options) ->
    node_flat_sql:subscribe_node(Nidx, Sender, Subscriber, AccessModel, SendLast,
	PresenceSubscription, RosterGroup, Options).

unsubscribe_node(Nidx, Sender, Subscriber, SubId) ->
    node_flat_sql:unsubscribe_node(Nidx, Sender, Subscriber, SubId).

publish_item(Nidx, Publisher, Model, MaxItems, ItemId, Payload, PubOpts) ->
    node_flat_sql:publish_item(Nidx, Publisher, Model, MaxItems, ItemId,
	Payload, PubOpts).

remove_extra_items(Nidx, MaxItems, ItemIds) ->
    node_flat_sql:remove_extra_items(Nidx, MaxItems, ItemIds).

delete_item(Nidx, Publisher, PublishModel, ItemId) ->
    node_flat_sql:delete_item(Nidx, Publisher, PublishModel, ItemId).

purge_node(Nidx, Owner) ->
    node_flat_sql:purge_node(Nidx, Owner).

get_entity_affiliations(Host, Owner) ->
    node_flat_sql:get_entity_affiliations(Host, Owner).

get_node_affiliations(Nidx) ->
    node_flat_sql:get_node_affiliations(Nidx).

get_affiliation(Nidx, Owner) ->
    node_flat_sql:get_affiliation(Nidx, Owner).

set_affiliation(Nidx, Owner, Affiliation) ->
    node_flat_sql:set_affiliation(Nidx, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    node_flat_sql:get_entity_subscriptions(Host, Owner).

get_entity_subscriptions_for_send_last(Host, Owner) ->
    node_flat_sql:get_entity_subscriptions_for_send_last(Host, Owner).

get_node_subscriptions(Nidx) ->
    node_flat_sql:get_node_subscriptions(Nidx).

get_subscriptions(Nidx, Owner) ->
    node_flat_sql:get_subscriptions(Nidx, Owner).

set_subscriptions(Nidx, Owner, Subscription, SubId) ->
    node_flat_sql:set_subscriptions(Nidx, Owner, Subscription, SubId).

get_pending_nodes(Host, Owner) ->
    node_flat_sql:get_pending_nodes(Host, Owner).

get_states(Nidx) ->
    node_flat_sql:get_states(Nidx).

get_state(Nidx, JID) ->
    node_flat_sql:get_state(Nidx, JID).

set_state(State) ->
    node_flat_sql:set_state(State).

get_items(Nidx, From, RSM) ->
    node_flat_sql:get_items(Nidx, From, RSM).

get_items(Nidx, JID, AccessModel, PresenceSubscription, RosterGroup, SubId, RSM) ->
    node_flat_sql:get_items(Nidx, JID, AccessModel,
	PresenceSubscription, RosterGroup, SubId, RSM).

get_item(Nidx, ItemId) ->
    node_flat_sql:get_item(Nidx, ItemId).

get_item(Nidx, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_flat_sql:get_item(Nidx, ItemId, JID,
	AccessModel, PresenceSubscription, RosterGroup, SubId).

set_item(Item) ->
    node_flat_sql:set_item(Item).

get_item_name(Host, Node, Id) ->
    node_flat_sql:get_item_name(Host, Node, Id).

get_last_items(Nidx, From, Count) ->
    node_flat_sql:get_last_items(Nidx, From, Count).

node_to_path(Node) ->
    node_hometree:node_to_path(Node).

path_to_node(Path) ->
    node_hometree:path_to_node(Path).

