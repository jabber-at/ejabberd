# ----------------------------------------------------------------------
#
# ejabberd, Copyright (C) 2002-2015   ProcessOne
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

defmodule ModHttpApiMockTest do
	use ExUnit.Case, async: false

	@author "jsautret@process-one.net"

	# Admin user
	@admin "admin"
	@adminpass "adminpass"
	# Non admin user
	@user "user"
	@userpass "userpass"
	# XMPP domain
	@domain "domain"
	# mocked command
	@command "command_test"
	@acommand String.to_atom(@command)
	# default API version
	@version 0

	require Record
	Record.defrecord :request, Record.extract(:request, from_lib: "ejabberd/include/ejabberd_http.hrl")

	setup_all do
		try do
      :jid.start
      :mnesia.start
			:stringprep.start
      :ejabberd_config.start([@domain], [])
      :ejabberd_commands.init
		rescue
			_ -> :ok
		end
		:mod_http_api.start(@domain, [])
		EjabberdOauthMock.init
		:ok
	end

	setup do
		:meck.unload
		:meck.new :ejabberd_commands
		EjabberdAuthMock.init
		:ok
	end

	test "HTTP GET simple command call with Basic Auth" do
		EjabberdAuthMock.create_user @user, @domain, @userpass

		# Mock a simple command() -> :ok
		:meck.expect(:ejabberd_commands, :get_command_format,
			fn (@acommand, {@user, @domain, @userpass, false}, @version) ->
				{[], {:res, :rescode}}
			end)
    :meck.expect(:ejabberd_commands, :get_command_policy,
			fn (@acommand) -> {:ok, :user} end)
		:meck.expect(:ejabberd_commands, :get_commands,
			fn () -> [@acommand] end)
		:meck.expect(:ejabberd_commands, :execute_command,
			fn (:undefined, {@user, @domain, @userpass, false}, @acommand, [], @version) ->
				:ok
			end)

    :ejabberd_config.add_local_option(:commands, [[{:add_commands, [@acommand]}]])

		# Correct Basic Auth call
		req = request(method: :GET,
									path: ["api", @command],
									q: [nokey: ""],
									# Basic auth
									auth: {@user<>"@"<>@domain, @userpass},
									ip: {{127,0,0,1},60000},
									host: @domain)
		result = :mod_http_api.process([@command], req)

    # history = :meck.history(:ejabberd_commands)

		assert 200 == elem(result, 0) # HTTP code
		assert "0" == elem(result, 2) # command result

		# Bad password
		req = request(method: :GET,
									path: ["api", @command],
									q: [nokey: ""],
									# Basic auth
									auth: {@user<>"@"<>@domain, @userpass<>"bad"},
									ip: {{127,0,0,1},60000},
									host: @domain)
		result = :mod_http_api.process([@command], req)
		assert 401 == elem(result, 0) # HTTP code

		# Check that the command was executed only once
		assert 1 ==
			:meck.num_calls(:ejabberd_commands, :execute_command, :_)

		assert :meck.validate :ejabberd_auth
		assert :meck.validate :ejabberd_commands
	end

	test "HTTP GET simple command call with OAuth" do
		EjabberdAuthMock.create_user @user, @domain, @userpass

		# Mock a simple command() -> :ok
		:meck.expect(:ejabberd_commands, :get_command_format,
			fn (@acommand, {@user, @domain, {:oauth, _token}, false}, @version) ->
					{[], {:res, :rescode}}
			end)
    :meck.expect(:ejabberd_commands, :get_command_policy,
			fn (@acommand) -> {:ok, :user} end)
		:meck.expect(:ejabberd_commands, :get_commands,
			fn () -> [@acommand] end)
		:meck.expect(:ejabberd_commands, :execute_command,
			fn (:undefined, {@user, @domain, {:oauth, _token}, false},
					@acommand, [], @version) ->
					:ok
			end)


		# Correct OAuth call
		token = EjabberdOauthMock.get_token @user, @domain, @command
		req = request(method: :GET,
									path: ["api", @command],
									q: [nokey: ""],
									# OAuth
									auth: {:oauth, token, []},
									ip: {{127,0,0,1},60000},
									host: @domain)
		result = :mod_http_api.process([@command], req)
		assert 200 == elem(result, 0) # HTTP code
		assert "0" == elem(result, 2) # command result

		# Wrong OAuth token
		req = request(method: :GET,
									path: ["api", @command],
									q: [nokey: ""],
									# OAuth
									auth: {:oauth, "bad"<>token, []},
									ip: {{127,0,0,1},60000},
									host: @domain)
		result = :mod_http_api.process([@command], req)
		assert 401 == elem(result, 0) # HTTP code

		# Expired OAuth token
		token = EjabberdOauthMock.get_token @user, @domain, @command, 1
		:timer.sleep 1500
		req = request(method: :GET,
									path: ["api", @command],
									q: [nokey: ""],
									# OAuth
									auth: {:oauth, token, []},
									ip: {{127,0,0,1},60000},
									host: @domain)
		result = :mod_http_api.process([@command], req)
		assert 401 == elem(result, 0) # HTTP code

		# Wrong OAuth scope
		token = EjabberdOauthMock.get_token @user, @domain, "bad_command"
		:timer.sleep 1500
		req = request(method: :GET,
									path: ["api", @command],
									q: [nokey: ""],
									# OAuth
									auth: {:oauth, token, []},
									ip: {{127,0,0,1},60000},
									host: @domain)
		result = :mod_http_api.process([@command], req)
		assert 401 == elem(result, 0) # HTTP code

		# Check that the command was executed only once
		assert 1 ==
			:meck.num_calls(:ejabberd_commands, :execute_command, :_)

		assert :meck.validate :ejabberd_auth
		assert :meck.validate :ejabberd_commands
		#assert :ok = :meck.history(:ejabberd_commands)
	end


end
