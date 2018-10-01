# ----------------------------------------------------------------------
#
# ejabberd, Copyright (C) 2002-2017   ProcessOne
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# ----------------------------------------------------------------------

defmodule ModRosterMock do
	@author "jsautret@process-one.net"

	require Record
	Record.defrecord :roster, Record.extract(:roster, from_lib: "ejabberd/include/mod_roster.hrl")
	Record.defrecord :roster_version, Record.extract(:roster_version, from_lib: "ejabberd/include/mod_roster.hrl")

	@agent __MODULE__

	def init(domain, module) do
		try do
			Agent.stop(@agent)
		catch
			:exit, _e -> :ok
		end

		{:ok, _pid} = Agent.start_link(fn -> %{} end, name: @agent)

    mock_with_meck

		:ejabberd_mnesia.create(:mod_roster_mnesia, :roster,
			[ram_copies: [node()],
			 attributes: Keyword.keys(roster(roster())),
			  index: [:us]])
		:ejabberd_mnesia.create(:mod_roster_mnesia, :roster_version,
			[ram_copies: [node()],
			 attributes: Keyword.keys(roster_version(roster_version()))])
    #:mod_roster.stop(domain)
    :gen_mod.start_module(domain, :mod_roster)
  end

	def	mock_with_meck do
#		mock(:gen_mod, :db_type,
#			fn (_server, :mod_roster_mnesia)  ->
#				:mnesia
#				 end)
#
#		mock(:mnesia, :transaction,
#			fn (_server, function)  ->
#				{:atomic, function.()}
#			end)
#
#		mock(:mnesia, :write,
#			fn (Item)  ->
#				throw Item
#				{:atomic, :ok}
#			end)

		mock(:mod_roster_mnesia, :init,
			fn (_server, _opts)  ->
        :ok
			end)
		mock(:mod_roster_mnesia, :transaction,
			fn (_server, function)  ->
				{:atomic, function.()}
			end)

		mock(:mod_roster_mnesia, :update_roster_t,
				 fn (user, domain, {u, d, _r}, item) ->
					 add_roster_item(user, domain, u<>"@"<>d,
													 roster(item, :name),
													 roster(item, :subscription),
													 roster(item, :groups),
													 roster(item, :ask),
													 roster(item, :askmessage))
				 end)

		mock(:mod_roster_mnesia, :invalidate_roster_cache,
			fn (_user, _server)  ->
				:ok
			end)

	end

	def add_roster_item(user, domain, jid, nick, subs \\ :none, groups \\ [],
											ask \\ :none, askmessage \\ "")
	when is_binary(user) and byte_size(user) > 0
	and  is_binary(domain) and byte_size(domain) > 0
	and  is_binary(jid) and byte_size(jid) > 0
	and  is_binary(nick)
	and  is_atom(subs)
	and  is_list(groups)
	and  is_atom(ask)
	and  is_binary(askmessage)
		do
		Agent.update(@agent, fn roster ->
			Map.put(roster, {user, domain, jid}, %{nick: nick,
																						 subs: subs, groups: groups,
																						 ask: ask,	askmessage: askmessage})
		end)
	end

	def remove_roster_item(user, domain, jid) do
		Agent.update(@agent, fn roster ->
			Map.delete(roster, {user, domain, jid})
		end)
	end

	def get_rosters() do
		Agent.get(@agent, fn roster -> roster end)
	end

	def get_roster(user, domain) do
		Agent.get(@agent, fn roster ->
		for {u, d, jid} <- Map.keys(roster), u == user, d == domain,
				do: {{u, d, jid}, Map.fetch!(roster, {u, d, jid})}
		end)
	end

	def	to_record({{user, domain, jid}, r}) do
		roster(usj: {user, domain, jid},
					 us: {user, domain},
					 jid: :jid.from_string(jid),
					 subscription: r.subs,
					 ask: r.ask,
					 groups: r.groups,
					 askmessage: r.askmessage
		)
	end
	def to_records(rosters) do
		for item <- rosters, do: to_record(item)
	end

####################################################################
#     Helpers
####################################################################

	# TODO refactor: Move to ejabberd_test_mock
	def mock(module, function, fun) do
		try do
			:meck.new(module, [:non_strict, :passthrough, :unstick])
		catch
			:error, {:already_started, _pid} -> :ok
		end

		:meck.expect(module, function, fun)
	end

end
