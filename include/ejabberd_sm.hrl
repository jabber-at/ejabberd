-record(session, {sid, usr, us, priority, info}).
-record(session_counter, {vhost, count}).
-type sid() :: {erlang:timestamp(), pid()}.
-type ip() :: {inet:ip_address(), inet:port_number()} | undefined.
-type info() :: [{conn, atom()} | {ip, ip()} | {node, atom()}
                 | {oor, boolean()} | {auth_module, atom()}].
-type prio() :: undefined | integer().
