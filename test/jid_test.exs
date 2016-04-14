# ----------------------------------------------------------------------
#
# ejabberd, Copyright (C) 2002-2016   ProcessOne
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

defmodule JidTest do
  @author "mremond@process-one.net"

  use ExUnit.Case, async: true

  require Record
  Record.defrecord :jid, Record.extract(:jid, from_lib: "ejabberd/include/jlib.hrl")

  setup_all do
    :stringprep.start
    :jid.start
  end

  test "create a jid from a binary" do
    jid = :jid.from_string("test@localhost/resource")
    assert jid(jid, :user) == "test"
    assert jid(jid, :server) == "localhost"
    assert jid(jid, :resource) == "resource"
  end

  test "Check that sending a list to from_string/1 does not crash the jid process" do
    {:error, :need_jid_as_binary} = :jid.from_string('test@localhost/resource')
  end
end
