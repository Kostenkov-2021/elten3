# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "thread"

module EltenLink
  module Relay
    DEFAULT_HOST = "relay.elten.link"
    DEFAULT_PORT = 8244
    VERSION = 1
    MAX_FRAME = 128 * 1024
    MAX_RELIABLE_DATA = 64 * 1024
    MAX_UNRELIABLE_DATA = 1200
    MAX_DATAGRAM = 1400
    MAX_PARTICIPANTS = 32
    DEFAULT_LIMITS = {
      max_frame: MAX_FRAME,
      max_reliable_data: MAX_RELIABLE_DATA,
      max_unreliable_data: MAX_UNRELIABLE_DATA,
      max_datagram: MAX_DATAGRAM,
      max_metadata: 8 * 1024,
      max_participants: MAX_PARTICIPANTS,
      fast_path_timeout: 12.0,
      session_timeout: 20.0,
      ping_interval: 5.0
    }.freeze
    MAGIC = "ELR1".b

    DATAGRAM_REGISTER = 1
    DATAGRAM_REGISTERED = 2
    DATAGRAM_MESSAGE = 3
    DATAGRAM_FORWARDED = 4
    DATAGRAM_PING = 5
    DATAGRAM_PONG = 6
    DATAGRAM_READY = 7

    class Error < StandardError; end
    class ConnectionError < Error; end
    class AuthenticationError < Error; end
    class TimeoutError < Error; end
    class MessageTooLarge < Error; end

    class RemoteError < Error
      attr_reader :code

      def initialize(code, message = nil)
        @code = code.to_s
        super(message.to_s.empty? ? @code.tr("_", " ") : message.to_s)
      end
    end

    class ResponseWaiter
      def initialize
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @done = false
      end

      def resolve(value = nil, error = nil)
        @mutex.synchronize do
          return if @done
          @done = true
          @value = value
          @error = error
          @condition.broadcast
        end
      end

      def wait(timeout)
        deadline = monotonic + timeout.to_f
        @mutex.synchronize do
          until @done
            remaining = deadline - monotonic
            raise TimeoutError, "Relay request timed out" if remaining <= 0
            @condition.wait(@mutex, remaining)
          end
          raise @error if @error != nil
          @value
        end
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class Client
      STOP_WRITER = Object.new

      attr_reader :app_id, :user, :latency

      def initialize(app_id:, user:, token:, host: DEFAULT_HOST, port: DEFAULT_PORT, timeout: 5,
                     tls_context: nil, event_sink: nil)
        @app_id = app_id.to_s
        @user = user.to_s
        @token = token.to_s
        @host = host.to_s
        @port = port.to_i
        @timeout = timeout.to_f
        @tls_context = tls_context
        @event_sink = event_sink
        raise AuthenticationError, "Elten user is not logged in" if @user.empty? || @token.empty?
        raise ArgumentError, "app_id is required" if @app_id.empty? || @app_id == "0"

        @mutex = Mutex.new
        @request_mutex = Mutex.new
        @udp_mutex = Mutex.new
        @requests = {}
        @outgoing = SizedQueue.new(512)
        @request_serial = SecureRandom.random_number(1 << 30)
        @udp_pings = {}
        @latency = nil
        @last_udp_pong = 0.0
        @last_control_pong = monotonic
        @udp_registered = false
        @limits = DEFAULT_LIMITS.dup
        @closed = false
        @closing = false
        connect_control
      rescue Exception
        close if @mutex != nil
        raise
      end

      def create_session(metadata:, participant_metadata:, capacity:, public_state:, encryption:)
        request(
          "create_session",
          "metadata" => metadata,
          "participant_metadata" => participant_metadata,
          "capacity" => capacity,
          "public" => public_state,
          "encryption" => encryption
        )
      end

      def public_sessions
        Array(request("public_sessions"))
      end

      def join_public_session(session_id:, participant_metadata:)
        request(
          "join_public_session",
          "session_id" => session_id.to_s,
          "participant_metadata" => participant_metadata
        )
      end

      def invite(session_id:, user:, metadata:)
        request("invite", "session_id" => session_id.to_s, "user" => user.to_s, "metadata" => metadata)
      end

      def cancel_invitation(invitation_id:)
        request("cancel_invitation", "invitation_id" => invitation_id.to_s)
      end

      def accept_invitation(invitation_id:, participant_metadata:)
        request(
          "accept_invitation",
          "invitation_id" => invitation_id.to_s,
          "participant_metadata" => participant_metadata
        )
      end

      def reject_invitation(invitation_id:)
        request("reject_invitation", "invitation_id" => invitation_id.to_s)
      end

      def leave_session(session_id:)
        request("leave_session", "session_id" => session_id.to_s)
      end

      def close_session(session_id:)
        request("close_session", "session_id" => session_id.to_s)
      end

      def remove_participant(session_id:, participant_id:)
        request("remove_participant", "session_id" => session_id.to_s, "participant_id" => participant_id.to_s)
      end

      def transfer_ownership(session_id:, participant_id:)
        request("transfer_ownership", "session_id" => session_id.to_s, "participant_id" => participant_id.to_s)
      end

      def set_session_public(session_id:, public_state:)
        request("set_session_public", "session_id" => session_id.to_s, "public" => public_state)
      end

      def send_reliable(session_id:, epoch:, message_id:, targets:, envelope:)
        request(
          "reliable",
          "session_id" => session_id.to_s,
          "epoch" => epoch.to_i,
          "message_id" => message_id.to_i,
          "targets" => targets,
          "data" => Base64.strict_encode64(envelope)
        )
      end

      def send_unreliable(session_id:, epoch:, message_id:, targets:, envelope:)
        if fast_path?
          begin
            packet = message_datagram(session_id, epoch, message_id, targets, envelope)
            return true if send_datagram(packet)
          rescue ArgumentError
            nil
          end
        end
        send_frame({
          "type" => "unreliable",
          "session_id" => session_id.to_s,
          "epoch" => epoch.to_i,
          "message_id" => message_id.to_i,
          "targets" => targets,
          "data" => Base64.strict_encode64(envelope)
        }, important: false)
      end

      def acknowledge(session_id:, sender_id:, message_id:, status:)
        send_frame({
          "type" => "ack",
          "session_id" => session_id.to_s,
          "sender_id" => sender_id.to_s,
          "message_id" => message_id.to_i,
          "status" => status.to_s
        }, important: false)
      end

      def fast_path?
        @udp_registered && monotonic - @last_udp_pong <= limit(:fast_path_timeout)
      end

      def limits
        @mutex.synchronize { @limits.dup }
      end

      def limit(name)
        @mutex.synchronize { @limits.fetch(name.to_sym) }
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def close
        shutdown(ConnectionError.new("Relay client was closed"), :closed, notify: false)
      end

      private

      def connect_control
        raw = Socket.tcp(@host, @port, connect_timeout: @timeout)
        raw.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        context = @tls_context || default_tls_context
        ssl = OpenSSL::SSL::SSLSocket.new(raw, context)
        ssl.sync_close = true
        ssl.hostname = @host if ssl.respond_to?(:hostname=)
        connect_tls(ssl)
        ssl.post_connection_check(@host)
        @control = ssl
        @writer_thread = Thread.new { writer_loop }
        @reader_thread = Thread.new { reader_loop }
        login = request(
          "login",
          { "version" => VERSION, "user" => @user, "token" => @token, "app_id" => @app_id },
          timeout: @timeout
        )
        @client_id = login["client_id"].to_s
        @datagram_secret = Base64.strict_decode64(login["datagram_secret"].to_s)
        apply_limits(login["limits"])
        start_datagrams
        @heartbeat_thread = Thread.new { heartbeat_loop }
      rescue RemoteError => error
        if ["authentication_failed", "not_authenticated"].include?(error.code)
          raise AuthenticationError, error.message
        end
        raise
      rescue AuthenticationError
        raise
      rescue Exception => error
        raise ConnectionError, "Cannot connect to relay service: #{error.message}"
      ensure
        if ssl == nil || @control != ssl
          begin
            ssl&.close
          rescue Exception
            nil
          end
          begin
            raw&.close
          rescue Exception
            nil
          end
        end
        @token = nil
      end

      def default_tls_context
        return ::EltenAPI::TLS.client_context if defined?(::EltenAPI::TLS)

        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true)
        context
      end

      def connect_tls(socket)
        deadline = monotonic + @timeout
        loop do
          socket.connect_nonblock
          return
        rescue IO::WaitReadable, OpenSSL::SSL::SSLErrorWaitReadable
          raise TimeoutError, "TLS connection timed out" if monotonic >= deadline
          IO.select([socket], nil, nil, 0.1)
        rescue IO::WaitWritable, OpenSSL::SSL::SSLErrorWaitWritable
          raise TimeoutError, "TLS connection timed out" if monotonic >= deadline
          IO.select(nil, [socket], nil, 0.1)
        end
      end

      def writer_loop
        loop do
          frame = @outgoing.pop
          break if frame.equal?(STOP_WRITER)
          @control.write(frame)
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => error
        fail_connection(ConnectionError.new(error.message), :connection_lost) unless @closing
      end

      def reader_loop
        loop { handle_frame(read_frame(@control)) }
      rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError, JSON::ParserError => error
        fail_connection(ConnectionError.new(error.message), :connection_lost) unless @closing
      end

      def heartbeat_loop
        until closed?
          if monotonic - @last_control_pong > limit(:session_timeout)
            fail_connection(ConnectionError.new("Relay heartbeat timed out"), :connection_lost)
            break
          end
          nonce = SecureRandom.hex(8)
          send_frame({ "type" => "ping", "nonce" => nonce }, important: false)
          probe_datagrams
          sleep(limit(:ping_interval))
        end
      rescue Exception => error
        Log.warning("Relay heartbeat failed: #{error.class}: #{error.message}") if defined?(Log) && !closed?
      end

      def request(type, fields = {}, timeout: 5, **keywords)
        fields = fields.merge(keywords)
        waiter = ResponseWaiter.new
        request_id = nil
        @request_mutex.synchronize do
          raise ConnectionError, "Relay client is closed" if closed?
          @request_serial += 1
          request_id = @request_serial.to_s
          @requests[request_id] = waiter
        end
        send_frame({ "type" => type, "request_id" => request_id }.merge(fields))
        waiter.wait(timeout)
      ensure
        @request_mutex.synchronize { @requests.delete(request_id) } if request_id != nil
      end

      def send_frame(object, important: true)
        payload = JSON.generate(object).b
        raise MessageTooLarge, "Relay control frame is too large" if payload.bytesize > limit(:max_frame)
        @outgoing.push([payload.bytesize].pack("N") + payload, true)
        true
      rescue ThreadError
        fail_connection(ConnectionError.new("Relay send queue is full"), :overloaded) if important
        false
      end

      def read_frame(io)
        header = read_exact(io, 4)
        size = header.unpack1("N")
        raise IOError, "Invalid relay frame" if size <= 0 || size > limit(:max_frame)
        JSON.parse(read_exact(io, size), max_nesting: 24, create_additions: false)
      end

      def read_exact(io, size)
        output = +"".b
        while output.bytesize < size
          part = io.read(size - output.bytesize)
          raise EOFError if part == nil || part.empty?
          output << part
        end
        output
      end

      def handle_frame(frame)
        return unless frame.is_a?(Hash)
        case frame["type"]
        when "response" then handle_response(frame)
        when "ping" then send_frame({ "type" => "pong", "nonce" => frame["nonce"] }, important: false)
        when "pong" then @last_control_pong = monotonic
        else emit_event(frame)
        end
      end

      def handle_response(frame)
        waiter = @request_mutex.synchronize { @requests[frame["request_id"].to_s] }
        return if waiter == nil
        if frame["ok"] == true
          waiter.resolve(frame["result"])
        else
          waiter.resolve(nil, RemoteError.new(frame["error"], frame["message"]))
        end
      end

      def emit_event(frame)
        return if @event_sink == nil || !@event_sink.respond_to?(:relay_event, true)
        @event_sink.__send__(:relay_event, self, frame)
      end

      def start_datagrams
        @datagram = UDPSocket.new
        @datagram.connect(@host, @port)
        @datagram_thread = Thread.new { datagram_reader_loop }
        send_registration
      rescue IOError, SystemCallError, SocketError => error
        @datagram&.close rescue nil
        @datagram = nil
        Log.warning("Relay fast path unavailable: #{error.class}: #{error.message}") if defined?(Log)
      end

      def datagram_reader_loop
        until closed?
          packet = @datagram.recv(limit(:max_datagram) + 1)
          next if packet.bytesize > limit(:max_datagram)
          parsed = parse_datagram(packet)
          next if parsed == nil
          case parsed[:type]
          when DATAGRAM_REGISTERED
            next unless parsed[:client_id] == @client_id
            @udp_registered = true
            send_datagram_ping
          when DATAGRAM_PONG
            sent = @udp_mutex.synchronize { @udp_pings.delete(parsed[:nonce]) }
            if sent != nil
              @last_udp_pong = monotonic
              @latency = @last_udp_pong - sent
              send_datagram(MAGIC + [DATAGRAM_READY].pack("C"))
            end
          when DATAGRAM_FORWARDED
            emit_event(
              "type" => "message",
              "kind" => "unreliable",
              "session_id" => parsed[:session_id],
              "sender_id" => parsed[:sender_id],
              "epoch" => parsed[:epoch],
              "message_id" => parsed[:message_id],
              "raw_data" => parsed[:envelope]
            )
          end
        end
      rescue IOError, SystemCallError
        @udp_registered = false
      end

      def probe_datagrams
        return if @datagram == nil
        @udp_registered = false if monotonic - @last_udp_pong > limit(:fast_path_timeout)
        send_registration unless @udp_registered
        send_datagram_ping if @udp_registered
      end

      def send_registration
        packet = MAGIC + [DATAGRAM_REGISTER].pack("C") + id_bytes(@client_id) + @datagram_secret
        send_datagram(packet)
      end

      def send_datagram_ping
        nonce = SecureRandom.random_number(1 << 64)
        @udp_mutex.synchronize do
          @udp_pings[nonce] = monotonic
          @udp_pings.shift while @udp_pings.size > 8
        end
        send_datagram(MAGIC + [DATAGRAM_PING, nonce].pack("CQ>"))
      end

      def send_datagram(packet)
        return false if @datagram == nil
        @datagram.send(packet, 0) == packet.bytesize
      rescue IOError, SystemCallError
        @udp_registered = false
        false
      end

      def message_datagram(session_id, epoch, message_id, targets, envelope)
        targets = Array(targets)
        raise ArgumentError, "too many targets" if targets.size > limit(:max_participants)
        packet = MAGIC + [DATAGRAM_MESSAGE].pack("C") + id_bytes(session_id)
        packet << [epoch.to_i, message_id.to_i, targets.size].pack("NQ>C")
        targets.each { |target| packet << id_bytes(target) }
        packet << envelope
        raise ArgumentError, "datagram too large" if packet.bytesize > limit(:max_datagram)
        packet
      end

      def apply_limits(values)
        return unless values.is_a?(Hash)
        parsed = DEFAULT_LIMITS.each_with_object({}) do |(name, default), output|
          value = values[name.to_s]
          next if !value.is_a?(Numeric) || value <= 0
          output[name] = default.is_a?(Float) ? value.to_f : value.to_i
        end
        @mutex.synchronize { @limits.merge!(parsed) }
      end

      def parse_datagram(packet)
        data = packet.to_s.b
        return nil if data.bytesize < 5 || data.byteslice(0, 4) != MAGIC
        type = data.getbyte(4)
        case type
        when DATAGRAM_REGISTERED
          return nil unless data.bytesize == 21
          { type: type, client_id: bytes_id(data.byteslice(5, 16)) }
        when DATAGRAM_PONG
          return nil unless data.bytesize == 13
          { type: type, nonce: data.byteslice(5, 8).unpack1("Q>") }
        when DATAGRAM_FORWARDED
          return nil if data.bytesize < 69
          {
            type: type,
            session_id: bytes_id(data.byteslice(5, 16)),
            sender_id: bytes_id(data.byteslice(21, 16)),
            epoch: data.byteslice(37, 4).unpack1("N"),
            message_id: data.byteslice(41, 8).unpack1("Q>"),
            envelope: data.byteslice(49..-1)
          }
        end
      end

      def id_bytes(id)
        value = id.to_s
        raise ArgumentError, "invalid identifier" unless value.match?(/\A[0-9a-f]{32}\z/i)
        [value].pack("H*")
      end

      def bytes_id(bytes)
        bytes.unpack1("H*")
      end

      def close_transport
        @outgoing&.push(STOP_WRITER, true) rescue nil
        @control&.close rescue nil
        @datagram&.close rescue nil
      end

      def fail_connection(error, reason)
        shutdown(error, reason, notify: true)
      end

      def shutdown(error, reason, notify:)
        changed = @mutex.synchronize do
          next false if @closed
          @closing = true
          @closed = true
          true
        end
        return false unless changed
        close_transport
        waiters = @request_mutex.synchronize do
          current = @requests.values
          @requests = {}
          current
        end
        waiters.each { |waiter| waiter.resolve(nil, error) }
        if notify && @event_sink != nil && @event_sink.respond_to?(:relay_closed, true)
          @event_sink.__send__(:relay_closed, self, error, reason)
        end
        true
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
