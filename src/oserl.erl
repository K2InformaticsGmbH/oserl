-module(oserl).

-export([
        start/0,
        stop/0
    ]).

start() ->
    application:start(common_lib),
    application:start(?MODULE).

stop() ->
    application:stop(?MODULE),
    application:stop(common_lib).
