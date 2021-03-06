%%% Copyright (C) 2009 Enrique Marcote, Miguel Rodriguez
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%% o Redistributions of source code must retain the above copyright notice,
%%%   this list of conditions and the following disclaimer.
%%%
%%% o Redistributions in binary form must reproduce the above copyright notice,
%%%   this list of conditions and the following disclaimer in the documentation
%%%   and/or other materials provided with the distribution.
%%%
%%% o Neither the name of ERLANG TRAINING AND CONSULTING nor the names of its
%%%   contributors may be used to endorse or promote products derived from this
%%%   software without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
%%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
%%% LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
%%% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
%%% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
%%% CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
%%% ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%%% POSSIBILITY OF SUCH DAMAGE.
-module(smpp_session).

%%% INCLUDE FILES
-include_lib("oserl/include/oserl.hrl").

%%% EXTERNAL EXPORTS
-export([congestion/3, connect/1, listen/1, tcp_send/2, send_pdu/3]).

%%% SOCKET LISTENER FUNCTIONS EXPORTS
-export([wait_accept/3, wait_recv/3]).

%% TIMER EXPORTS
-export([cancel_timer/1, start_timer/2]).

%%% MACROS
-define(CONNECT_OPTS(Ip),
        case Ip of
            undefined -> [binary, {packet, 0}, {active, false}];
            _         -> [binary, {packet, 0}, {active, false}, {ip, Ip}]
        end).
-define(CONNECT_TIME, 30000).
-define(LISTEN_OPTS(Ip),
        case Ip of
            undefined ->
              [binary, {packet, 0}, {active, false}, {reuseaddr, true}];
            _ ->
              [binary, {packet, 0}, {active, false}, {reuseaddr, true}, {ip, Ip}]
        end).

%%%-----------------------------------------------------------------------------
%%% EXTERNAL EXPORTS
%%%-----------------------------------------------------------------------------
%% Computes the congestion state.
%%
%% - CongestionSt: Current ``congestion_state`` value.
%% - WaitTime: Are the microseconds waiting for the PDU.
%% - Timestamp: Represents the moment when the PDU was received.
%%
%% The time since ``Timestamp`` is the PDU dispatching time.  If
%% this value equals the ``WaitTime`` (i.e. ``DispatchTime/WaitTime = 1``),
%% then we shall assume optimum load (value 85).  Having this in mind the
%% instant congestion state value is calculated.  Notice this value cannot be
%% greater than 99.
congestion(CongestionSt, WaitTime, Timestamp) ->
    case (timer:now_diff(now(), Timestamp) div (WaitTime + 1)) * 85 of
        Val when Val < 1 ->
            0;
        Val when Val > 99 ->  % Out of bounds
            ((19 * CongestionSt) + 99) div 20;
        Val ->
            ((19 * CongestionSt) + Val) div 20
    end.


connect(Opts) ->
    Ip = proplists:get_value(ip, Opts),
    case proplists:get_value(sock, Opts, undefined) of
        undefined ->
            Addr = proplists:get_value(addr, Opts),
            Port = proplists:get_value(port, Opts, ?DEFAULT_SMPP_PORT),
            gen_tcp:connect(Addr, Port, ?CONNECT_OPTS(Ip), ?CONNECT_TIME);
        Sock ->
            case inet:setopts(Sock, ?CONNECT_OPTS(Ip)) of
                ok    -> {ok, Sock};
                Error -> Error
            end
    end.


listen(Opts) ->
    case proplists:get_value(lsock, Opts, undefined) of
        undefined ->
            Addr = proplists:get_value(addr, Opts, default_addr()),
            Port = proplists:get_value(port, Opts, ?DEFAULT_SMPP_PORT),
            gen_tcp:listen(Port, ?LISTEN_OPTS(Addr));
        LSock ->
            Addr = proplists:get_value(addr, Opts, default_addr()),
            case inet:setopts(LSock, ?LISTEN_OPTS(Addr)) of
                ok ->
                    {ok, LSock};
                Error ->
                    Error
            end
    end.


tcp_send(Sock, Data) when is_port(Sock) ->
    try erlang:port_command(Sock, Data) of
        true -> ok
    catch
        error:_Error -> {error, einval}
    end.


send_pdu(Sock, BinPdu, _Log) when is_list(BinPdu) ->
    case tcp_send(Sock, BinPdu) of
        ok ->
            log(Sock, output, BinPdu),
            ok;
        {error, Reason} ->
            log(Sock, output_error, BinPdu),
            gen_fsm:send_all_state_event(self(), {sock_error, Reason})
    end;


send_pdu(Sock, Pdu, Log) ->
    case smpp_operation:pack(Pdu) of
        {ok, BinPdu} ->
            send_pdu(Sock, BinPdu, Log);
        {error, _CmdId, Status, _SeqNum} ->
            gen_tcp:close(Sock),
            log(Sock, close, <<>>),
            exit({command_status, Status})
    end.

%%%-----------------------------------------------------------------------------
%%% SOCKET LISTENER FUNCTIONS
%%%-----------------------------------------------------------------------------
wait_accept(Pid, LSock, Log) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            case handle_accept(Pid, Sock) of
                true ->
                    log(Sock, accept, <<>>),
                    recv_loop(Pid, Sock, <<>>, Log);
                false ->
                    log(Sock, reject, <<>>),
                    gen_tcp:close(Sock),
                    wait_accept(Pid, LSock, Log)
            end;
        {error, Reason} ->
            gen_fsm:send_all_state_event(Pid, {listen_error, Reason})
    end.


wait_recv(Pid, Sock, Log) ->
    receive activate ->
	recv_loop(Pid, Sock, <<>>, Log) end.

recv_loop(Pid, Sock, Buffer, Log) ->
    inet:setopts(Sock, [{active, once}]),
    Timestamp = now(),
    receive
        {tcp, Sock, Input} ->
            L = timer:now_diff(now(), Timestamp),
            B = handle_input(Sock, Pid, list_to_binary([Buffer, Input]), L, 1, Log),
            recv_loop(Pid, Sock, B, Log);
        {tcp_closed, Sock} ->
            log(Sock, close, <<>>),
            gen_fsm:send_all_state_event(Pid, {sock_error, closed});
        {tcp_error, Sock, Reason} ->
            gen_fsm:send_all_state_event(Pid, {sock_error, Reason})
    end.

%%%-----------------------------------------------------------------------------
%%% TIMER FUNCTIONS
%%%-----------------------------------------------------------------------------
cancel_timer(undefined) ->
    false;
cancel_timer(Ref) ->
    gen_fsm:cancel_timer(Ref).


start_timer(#timers_smpp{response_time = infinity}, {response_timer, _}) ->
    undefined;
start_timer(#timers_smpp{response_time = infinity}, enquire_link_failure) ->
    undefined;
start_timer(#timers_smpp{enquire_link_time = infinity}, enquire_link_timer) ->
    undefined;
start_timer(#timers_smpp{session_init_time = infinity}, session_init_timer) ->
    undefined;
start_timer(#timers_smpp{inactivity_time = infinity}, inactivity_timer) ->
    undefined;
start_timer(#timers_smpp{response_time = Time}, {response_timer, _} = Msg) ->
    gen_fsm:start_timer(Time, Msg);
start_timer(#timers_smpp{response_time = Time}, enquire_link_failure) ->
    gen_fsm:start_timer(Time, enquire_link_failure);
start_timer(#timers_smpp{enquire_link_time = Time}, enquire_link_timer) ->
    gen_fsm:start_timer(Time, enquire_link_timer);
start_timer(#timers_smpp{session_init_time = Time}, session_init_timer) ->
    gen_fsm:start_timer(Time, session_init_timer);
start_timer(#timers_smpp{inactivity_time = Time}, inactivity_timer) ->
    gen_fsm:start_timer(Time, inactivity_timer).

%%%-----------------------------------------------------------------------------
%%% INTERNAL FUNCTIONS
%%%-----------------------------------------------------------------------------
default_addr() ->
    {ok, Host} = inet:gethostname(),
    {ok, Addr} = inet:getaddr(Host, inet),
    Addr.


handle_accept(Pid, Sock) ->
    case inet:peername(Sock) of
        {ok, {Addr, _Port}} ->
            gen_fsm:sync_send_event(Pid, {accept, Sock, Addr});
        {error, _Reason} ->  % Most probably the socket is closed
            false
    end.


handle_input(Sock, Pid, <<CmdLen:32, Rest/binary>> = Buffer, Lapse, N, Log) ->
    Now = now(), % PDU received.  PDU handling starts now!
    Len = CmdLen - 4,
    case Rest of
        <<PduRest:Len/binary-unit:8, NextPdus/binary>> ->
            BinPdu = <<CmdLen:32, PduRest/binary>>,
            case catch smpp_operation:unpack(BinPdu) of
                {ok, Pdu} ->
                    log(Sock, input, BinPdu),
                    %% smpp_log_mgr:pdu(Log, BinPdu),
                    CmdId = smpp_operation:get_value(command_id, Pdu),
                    Event = {input, CmdId, Pdu, (Lapse div N), Now},
                    gen_fsm:send_all_state_event(Pid, Event);
                {error, _CmdId, _Status, _SeqNum} = Event ->
                    log(Sock, input_error, BinPdu),
                    gen_fsm:send_all_state_event(Pid, Event);
                {'EXIT', _What} ->
                    log(Sock, input_error_unknown, BinPdu),
                    Event = {error, 0, ?ESME_RUNKNOWNERR, 0},
                    gen_fsm:send_all_state_event(Pid, Event)
            end,
            % The buffer may carry more than one SMPP PDU.
            handle_input(Sock, Pid, NextPdus, Lapse, N + 1, Log);
        _IncompletePdu ->
            Buffer
    end;
handle_input(_Sock, _Pid, Buffer, _Lapse, _N, _Log) ->
    Buffer.

log(Socket, Type, BinPduu) ->
    BinPdu = iolist_to_binary(BinPduu),
    case inet:peername(Socket) of
        {ok, {RemoteAddr, RemotePort}} ->
            case inet:sockname(Socket) of
                {ok, {LocalAddr, LocalPort}} ->
                    case Type of
                        accept ->
                            lager:info([
                                    {imem_table, 'smpp@'},
                                    {originator_addr, RemoteAddr},
                                    {originator_port, RemotePort},
                                    {destination_addr, LocalAddr},
                                    {destination_port, LocalPort},
                                    {data, BinPdu}
                                    ], "ACCEPT");
                        close ->
                            lager:info([
                                    {imem_table, 'smpp@'},
                                    {originator_addr, RemoteAddr},
                                    {originator_port, RemotePort},
                                    {destination_addr, LocalAddr},
                                    {destination_port, LocalPort},
                                    {data, BinPdu}
                                    ], "CLOSE");

                        reject ->
                            lager:info([
                                    {imem_table, 'smpp@'},
                                    {originator_addr, RemoteAddr},
                                    {originator_port, RemotePort},
                                    {destination_addr, LocalAddr},
                                    {destination_port, LocalPort},
                                    {data, BinPdu}
                                    ], "REJECT");

                        input ->
                            lager:info([
                                    {imem_table, 'smpp@'},
                                    {originator_addr, RemoteAddr},
                                    {originator_port, RemotePort},
                                    {destination_addr, LocalAddr},
                                    {destination_port, LocalPort},
                                    {data, BinPdu}
                                    ], "INPUT");

                        input_error ->
                            lager:info([
                                    {imem_table, 'smpp_parse_error@'},
                                    {originator_addr, RemoteAddr},
                                    {originator_port, RemotePort},
                                    {destination_addr, LocalAddr},
                                    {destination_port, LocalPort},
                                    {data, BinPdu}
                                    ], "ERROR");

                        input_error_unknown ->
                            lager:info([
                                    {imem_table, 'smpp_unknown_parse_error@'},
                                    {originator_addr, RemoteAddr},
                                    {originator_port, RemotePort},
                                    {destination_addr, LocalAddr},
                                    {destination_port, LocalPort},
                                    {data, BinPdu}
                                    ], "ERROR");

                        output ->
                            lager:info([
                                    {imem_table, 'smpp@'},
                                    {originator_addr, LocalAddr},
                                    {originator_port, LocalPort},
                                    {destination_addr, RemoteAddr},
                                    {destination_port, RemotePort},
                                    {data, BinPdu}
                                    ], "OUTPUT");

                        output_error ->
                            lager:info([
                                    {imem_table, 'smpp_send_error@'},
                                    {originator_addr, LocalAddr},
                                    {originator_port, LocalPort},
                                    {destination_addr, RemoteAddr},
                                    {destination_port, RemotePort},
                                    {data, BinPdu}
                                    ], "ERROR")
                    end;
                {error, _} ->
                    ok
            end;
        {error, _} ->
            ok
    end.

