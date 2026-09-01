# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "thread"
require "zlib"

module EltenAPI
  module Communication
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
    class PeerUnavailable < Error; end
    class SessionClosed < Error; end
    class MessageTooLarge < Error; end
    class NotOwner < Error; end
    class StaleKey < Error; end

    class RemoteError < Error
      attr_reader :code

      def initialize(code, message = nil)
        @code = code.to_s
        super(message.to_s.empty? ? @code.tr("_", " ") : message.to_s)
      end
    end

    class DeliveryError < Error
      attr_reader :delivery

      def initialize(delivery)
        @delivery = delivery
        super("Message was not delivered to every participant")
      end
    end

    module Crypto
      module_function

      def encrypt(data, bits, key, iv: nil)
        data = binary(data)
        bits = validate(bits, key)
        iv ||= SecureRandom.random_bytes(16)
        raise ArgumentError, "IV must have 16 bytes" unless iv.bytesize == 16
        clear = [Zlib.crc32(data)].pack("N") + data
        iv + crypt(clear, bits, key, iv, true)
      end

      def decrypt(envelope, bits, key)
        envelope = binary(envelope)
        raise Error, "Invalid encrypted message" if envelope.bytesize < 20
        bits = validate(bits, key)
        iv = envelope.byteslice(0, 16)
        clear = crypt(envelope.byteslice(16..-1), bits, key, iv, false)
        checksum = clear.byteslice(0, 4).unpack1("N")
        data = clear.byteslice(4..-1).to_s.b
        raise Error, "Message checksum mismatch" unless Zlib.crc32(data) == checksum
        data
      rescue OpenSSL::Cipher::CipherError
        raise Error, "Cannot decrypt message"
      end

      def binary(data)
        raise ArgumentError, "data must be a String" unless data.is_a?(String)
        data.b
      end

      def validate(bits, key)
        bits = bits.to_i
        raise ArgumentError, "encryption must be 0, 128, 192 or 256" unless [0, 128, 192, 256].include?(bits)
        expected = bits / 8
        raise ArgumentError, "invalid session key" unless key.to_s.b.bytesize == expected
        bits
      end

      def crypt(data, bits, key, iv, encrypting)
        return data.b if bits.zero?
        cipher = OpenSSL::Cipher.new("AES-#{bits}-CTR")
        encrypting ? cipher.encrypt : cipher.decrypt
        cipher.key = key
        cipher.iv = iv
        cipher.update(data) + cipher.final
      end
    end

    class EventQueue
      def initialize
        @items = []
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      def push(item)
        @mutex.synchronize do
          @items << item
          @condition.signal
        end
        item
      end

      alias << push

      def pop(timeout: nil)
        deadline = timeout == nil ? nil : monotonic + timeout.to_f
        @mutex.synchronize do
          while @items.empty?
            if deadline == nil
              @condition.wait(@mutex)
            else
              remaining = deadline - monotonic
              return nil if remaining <= 0
              @condition.wait(@mutex, remaining)
            end
          end
          @items.shift
        end
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class Waiter
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
            raise TimeoutError, "Communication request timed out" if remaining <= 0
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

    class Participant
      attr_reader :id, :user, :metadata, :state

      def initialize(session, data)
        @session = session
        update(data)
      end

      def owner?
        @session.owner_id == @id
      end

      def update(data)
        @id = data["id"].to_s
        @user = data["user"].to_s
        @metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
        @state = (data["state"] || "active").to_sym
        self
      end

      def mark(state)
        @state = state.to_sym
      end
    end

    class Message
      attr_reader :sender, :data, :id, :kind

      def initialize(sender:, data:, id:, kind:)
        @sender = sender
        @data = data.b.freeze
        @id = id.to_i
        @kind = kind.to_sym
      end

      def reliable?
        @kind == :reliable
      end

      def unreliable?
        @kind == :unreliable
      end
    end

    class Delivery
      attr_reader :message_id

      def initialize(session, message_id, statuses)
        @session = session
        @message_id = message_id.to_i
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @statuses = statuses.transform_keys(&:to_s).transform_values { |value| value.to_sym }
        @participants = {}
        @statuses.each_key { |id| @participants[id] = session.participant(id) }
      end

      def update(participant_id, status)
        @mutex.synchronize do
          @statuses[participant_id.to_s] = status.to_sym
          @participants[participant_id.to_s] ||= @session.participant(participant_id)
          @condition.broadcast
        end
        self
      end

      def fail_pending(status = :failed)
        @mutex.synchronize do
          @statuses.each_key { |id| @statuses[id] = status.to_sym if @statuses[id] == :pending }
          @condition.broadcast
        end
        self
      end

      def complete?
        @mutex.synchronize { !@statuses.value?(:pending) }
      end

      def results
        @mutex.synchronize do
          @statuses.each_with_object({}) do |(id, status), output|
            output[@participants[id] || id] = status
          end
        end
      end

      def delivered_to
        results.select { |_, status| status == :delivered }.keys
      end

      def failed_for
        results.reject { |_, status| status == :delivered }.keys
      end

      def wait(timeout: nil)
        deadline = timeout == nil ? nil : monotonic + timeout.to_f
        @mutex.synchronize do
          while @statuses.value?(:pending)
            if deadline == nil
              @condition.wait(@mutex)
            else
              remaining = deadline - monotonic
              raise TimeoutError, "Delivery confirmation timed out" if remaining <= 0
              @condition.wait(@mutex, remaining)
            end
          end
        end
        self
      end

      def wait!(timeout: nil)
        wait(timeout: timeout)
        raise DeliveryError, self unless @mutex.synchronize { @statuses.values.all? { |status| status == :delivered } }
        self
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class OutgoingInvitation
      attr_reader :id, :user, :status, :participant

      def initialize(endpoint, id, user)
        @endpoint = endpoint
        @id = id.to_s
        @user = user.to_s
        @status = :pending
        @waiter = Waiter.new
      end

      def wait_until_accepted(timeout: 30)
        result = @waiter.wait(timeout)
        raise PeerUnavailable, "Invitation was #{@status}" unless @status == :accepted
        result
      end

      def cancel
        @endpoint.cancel_invitation(self)
      end

      def update(status, participant = nil)
        @status = status.to_sym
        @participant = participant
        @waiter.resolve(participant)
      end
    end

    class Invitation
      attr_reader :id, :sender, :metadata, :session_metadata, :participants, :status

      def initialize(endpoint, data)
        @endpoint = endpoint
        @id = data["id"].to_s
        @metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
        session = data["session"].is_a?(Hash) ? data["session"] : {}
        @session_metadata = session["metadata"].is_a?(Hash) ? session["metadata"] : {}
        @participants = Array(session["participants"]).map { |item| InvitationParticipant.new(item) }
        @sender = InvitationParticipant.new(data["sender"] || {})
        @status = :pending
      end

      def accept(metadata: {})
        raise SessionClosed, "Invitation is #{@status}" unless @status == :pending
        session = @endpoint.accept_invitation(self, metadata)
        @status = :accepted
        session
      end

      def reject
        return false unless @status == :pending
        @endpoint.reject_invitation(self)
        @status = :rejected
        true
      end

      def close(status)
        @status = status.to_sym if @status == :pending
      end
    end

    class InvitationParticipant
      attr_reader :id, :user, :metadata

      def initialize(data)
        @id = data["id"].to_s
        @user = data["user"].to_s
        @metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
        @owner = data["owner"] == true
      end

      def owner?
        @owner
      end
    end

    class PublicSession
      attr_reader :id, :metadata, :capacity, :encryption, :participants

      def initialize(data)
        @id = data["id"].to_s
        @metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
        @capacity = data["capacity"].to_i
        @encryption = data["encryption"].to_i
        @participants = Array(data["participants"]).map { |item| InvitationParticipant.new(item) }
      end

      def full?
        @participants.size >= @capacity
      end
    end

    class Session
      attr_reader :id, :metadata, :capacity, :encryption, :owner_id, :state

      def initialize(endpoint, data)
        @endpoint = endpoint
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @callbacks = Hash.new { |hash, key| hash[key] = [] }
        @messages = EventQueue.new
        @participants = {}
        @keys = {}
        @state = :open
        apply_snapshot(data)
      end

      def participants
        @mutex.synchronize { @participants.values.dup }
      end

      def participant(id)
        @mutex.synchronize { @participants[id.to_s] }
      end

      def owner
        participant(@owner_id)
      end

      def public?
        @mutex.synchronize { @public == true }
      end

      def public=(value)
        raise ArgumentError, "public must be true or false" unless value == true || value == false
        @endpoint.set_session_public(self, value)
        change_visibility(value)
        value
      end

      def invite(user, metadata: {})
        ensure_open!
        @endpoint.invite(self, user, metadata)
      end

      def invite_all(users, metadata: {})
        Array(users).map { |user| invite(user, metadata: metadata) }
      end

      def send_reliable(data, to: nil)
        ensure_open!
        validate_size!(data, @endpoint.limit(:max_reliable_data))
        @endpoint.send_reliable(self, data.b, target_ids(to))
      end

      def send_unreliable(data, to: nil)
        ensure_open!
        validate_size!(data, @endpoint.limit(:max_unreliable_data))
        @endpoint.send_unreliable(self, data.b, target_ids(to))
        nil
      end

      def receive(timeout: nil)
        @messages.pop(timeout: timeout)
      end

      def leave
        return false if @state == :closed
        @endpoint.leave_session(self)
        close_local(:left)
        true
      end

      def close
        ensure_open!
        raise NotOwner, "Only the session owner can close it" unless owner&.id == @endpoint.member_id(@id)
        @endpoint.close_session(self)
        close_local(:closed)
        true
      end

      def remove(participant, reason: nil)
        ensure_participant!(participant)
        @endpoint.remove_participant(self, participant)
        true
      end

      def transfer_ownership(participant)
        ensure_participant!(participant)
        @endpoint.transfer_ownership(self, participant)
        true
      end

      def on_reliable(&block); register_callback(:reliable, &block); end
      def on_unreliable(&block); register_callback(:unreliable, &block); end
      def on_participant_joined(&block); register_callback(:participant_joined, &block); end
      def on_participant_left(&block); register_callback(:participant_left, &block); end
      def on_owner_changed(&block); register_callback(:owner_changed, &block); end
      def on_closed(&block); register_callback(:closed, &block); end

      def wait_for_participant(user = nil, timeout: 30)
        deadline = monotonic + timeout.to_f
        @mutex.synchronize do
          loop do
            found = @participants.values.find do |participant|
              participant.id != @endpoint.member_id(@id) && (user == nil || participant.user.casecmp?(user.to_s))
            end
            return found if found != nil
            raise SessionClosed, "Session is closed" if @state == :closed
            remaining = deadline - monotonic
            raise TimeoutError, "Participant did not join in time" if remaining <= 0
            @condition.wait(@mutex, remaining)
          end
        end
      end

      def current_key
        @mutex.synchronize { [@epoch, @keys[@epoch]] }
      end

      def decrypt(epoch, envelope)
        key = @mutex.synchronize { @keys[epoch.to_i] }
        raise StaleKey, "Unknown key epoch #{epoch}" if key == nil
        Crypto.decrypt(envelope, @encryption, key)
      end

      def apply_key(epoch, key)
        Crypto.validate(@encryption, key)
        @mutex.synchronize do
          @epoch = epoch.to_i
          @keys[@epoch] = key.b
          @keys.delete(@keys.keys.min) while @keys.size > 32
        end
      end

      def add_participant(data)
        participant = nil
        @mutex.synchronize do
          id = data["id"].to_s
          participant = @participants[id]
          participant == nil ? @participants[id] = participant = Participant.new(self, data) : participant.update(data)
          @condition.broadcast
        end
        emit(:participant_joined, participant)
        participant
      end

      def remove_participant_local(id, reason)
        participant = @mutex.synchronize do
          item = @participants.delete(id.to_s)
          item&.mark(:left)
          @condition.broadcast
          item
        end
        emit(:participant_left, participant, reason.to_sym) if participant != nil
      end

      def change_owner(id)
        @mutex.synchronize { @owner_id = id.to_s }
        emit(:owner_changed, owner)
      end

      def change_visibility(value)
        @mutex.synchronize { @public = value == true }
      end

      def deliver(kind, message)
        @messages << [kind.to_sym, message]
        emit(kind.to_sym, message)
      end

      def close_local(reason)
        changed = @mutex.synchronize do
          next false if @state == :closed
          @state = :closed
          @condition.broadcast
          true
        end
        emit(:closed, reason.to_sym) if changed
      end

      private

      def apply_snapshot(data)
        @id = data["id"].to_s
        @metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
        @capacity = data["capacity"].to_i
        @public = data["public"] == true
        @encryption = data["encryption"].to_i
        @owner_id = data["owner_id"].to_s
        @epoch = data["epoch"].to_i
        key = Base64.strict_decode64(data["key"].to_s)
        Crypto.validate(@encryption, key)
        @keys[@epoch] = key
        Array(data["participants"]).each do |participant|
          item = Participant.new(self, participant)
          @participants[item.id] = item
        end
      rescue ArgumentError
        raise ConnectionError, "Server returned an invalid session key"
      end

      def target_ids(targets)
        return [] if targets == nil || targets == :all
        Array(targets).map do |participant|
          ensure_participant!(participant)
          participant.id
        end.uniq
      end

      def ensure_participant!(participant)
        raise ArgumentError, "participant does not belong to this session" unless participant.is_a?(Participant) && self.participant(participant.id).equal?(participant)
      end

      def ensure_open!
        raise SessionClosed, "Session is closed" unless @state == :open
      end

      def validate_size!(data, maximum)
        raise ArgumentError, "data must be a String" unless data.is_a?(String)
        raise MessageTooLarge, "Message exceeds #{maximum} bytes" if data.bytesize > maximum
      end

      def register_callback(kind, &block)
        raise ArgumentError, "callback is required" if block == nil
        @mutex.synchronize { @callbacks[kind] << block }
        self
      end

      def emit(kind, *arguments)
        callbacks = @mutex.synchronize { @callbacks[kind].dup }
        callbacks.each { |callback| @endpoint.enqueue_callback(callback, *arguments) }
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class Endpoint
      STOP_WRITER = Object.new

      attr_reader :app_id, :user, :latency

      def initialize(app_id:, user: nil, token: nil, host: DEFAULT_HOST, port: DEFAULT_PORT, timeout: 5)
        @app_id = app_id.to_s
        @user = (user || EltenAPI::Structs::Session.name).to_s
        @token = (token || EltenAPI::Structs::Session.token).to_s
        @host = host.to_s
        @port = port.to_i
        @timeout = timeout.to_f
        raise AuthenticationError, "Elten user is not logged in" if @user.empty? || @token.empty?
        raise ArgumentError, "app_id is required" if @app_id.empty? || @app_id == "0"

        @mutex = Mutex.new
        @request_mutex = Mutex.new
        @callback_mutex = Mutex.new
        @delivery_mutex = Mutex.new
        @udp_mutex = Mutex.new
        @sessions = {}
        @invitations = {}
        @outgoing_invitations = {}
        @requests = {}
        @deliveries = {}
        @pending_delivery_updates = Hash.new { |hash, key| hash[key] = [] }
        @callbacks = Hash.new { |hash, key| hash[key] = [] }
        @callback_queue = Queue.new
        @invitation_queue = EventQueue.new
        @outgoing = SizedQueue.new(512)
        @received = {}
        @received_mutex = Mutex.new
        @request_serial = SecureRandom.random_number(1 << 30)
        @message_serial = SecureRandom.random_number(1 << 48)
        @udp_pings = {}
        @latency = nil
        @last_udp_pong = 0.0
        @last_control_pong = monotonic
        @udp_registered = false
        @limits = DEFAULT_LIMITS.dup
        @closed = false
        @closing = false
        connect_control
        Communication.register(self)
      rescue Exception
        close_transport
        raise
      end

      def create_session(metadata: {}, participant_metadata: {}, capacity: 2, public: false, encryption: 192)
        result = request(
          "create_session", "metadata" => metadata, "participant_metadata" => participant_metadata,
          "capacity" => capacity, "public" => public, "encryption" => encryption
        )
        store_session(result)
      end

      def public_sessions
        Array(request("public_sessions")).map { |data| PublicSession.new(data) }
      end

      def join(public_session, participant_metadata: {})
        session_id = public_session.respond_to?(:id) ? public_session.id : public_session.to_s
        result = request("join_public_session", "session_id" => session_id,
                         "participant_metadata" => participant_metadata)
        store_session(result)
      end

      alias join_public_session join

      def connect(user, metadata: {}, participant_metadata: {}, encryption: 192, timeout: 10)
        session = create_session(metadata: metadata, participant_metadata: participant_metadata,
                                 capacity: 2, encryption: encryption)
        invitation = session.invite(user)
        invitation.wait_until_accepted(timeout: timeout)
        session.wait_for_participant(user, timeout: timeout)
        session
      rescue Exception
        session&.close rescue nil
        raise
      end

      def sessions
        @mutex.synchronize { @sessions.values.dup }
      end

      def on_invitation(&block)
        register_callback(:invitation, &block)
      end

      def on_closed(&block)
        register_callback(:closed, &block)
      end

      def next_invitation(timeout: nil)
        @invitation_queue.pop(timeout: timeout)
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
        return false if closed?
        @closing = true
        close_transport
        fail_connection(ConnectionError.new("Communication endpoint was closed"), :closed)
        true
      end

      def dispatch_events(limit = 100)
        count = 0
        while count < limit
          callback, arguments = @callback_queue.pop(true)
          begin
            callback.call(*arguments)
          rescue Exception => error
            Log.warning("Communication callback failed: #{error.class}: #{error.message}") if defined?(Log)
          end
          count += 1
        end
        count
      rescue ThreadError
        count
      end

      def enqueue_callback(callback, *arguments)
        @callback_queue << [callback, arguments]
      end

      def member_id(session_id)
        session = @mutex.synchronize { @sessions[session_id.to_s] }
        session&.participants&.find { |participant| participant.user.casecmp?(@user) }&.id
      end

      def invite(session, user, metadata)
        result = request("invite", "session_id" => session.id, "user" => user.to_s, "metadata" => metadata)
        invitation = OutgoingInvitation.new(self, result["id"], user)
        @mutex.synchronize { @outgoing_invitations[invitation.id] = [invitation, session] }
        invitation
      end

      def cancel_invitation(invitation)
        request("cancel_invitation", "invitation_id" => invitation.id)
        invitation.update(:cancelled)
        @mutex.synchronize { @outgoing_invitations.delete(invitation.id) }
        true
      end

      def accept_invitation(invitation, metadata)
        result = request("accept_invitation", "invitation_id" => invitation.id,
                         "participant_metadata" => metadata)
        @mutex.synchronize { @invitations.delete(invitation.id) }
        store_session(result)
      end

      def reject_invitation(invitation)
        request("reject_invitation", "invitation_id" => invitation.id)
        @mutex.synchronize { @invitations.delete(invitation.id) }
        true
      end

      def leave_session(session)
        request("leave_session", "session_id" => session.id)
        fail_session_operations(session.id, :left)
        @mutex.synchronize { @sessions.delete(session.id) }
      end

      def close_session(session)
        request("close_session", "session_id" => session.id)
        fail_session_operations(session.id, :closed)
        @mutex.synchronize { @sessions.delete(session.id) }
      end

      def remove_participant(session, participant)
        request("remove_participant", "session_id" => session.id, "participant_id" => participant.id)
      end

      def transfer_ownership(session, participant)
        request("transfer_ownership", "session_id" => session.id, "participant_id" => participant.id)
      end

      def set_session_public(session, value)
        request("set_session_public", "session_id" => session.id, "public" => value)
      end

      def send_reliable(session, data, targets)
        attempts = 0
        begin
          attempts += 1
          epoch, key = session.current_key
          message_id = next_message_id
          envelope = Crypto.encrypt(data, session.encryption, key)
          result = request(
            "reliable", "session_id" => session.id, "epoch" => epoch,
            "message_id" => message_id, "targets" => targets,
            "data" => Base64.strict_encode64(envelope)
          )
          delivery = Delivery.new(session, message_id, result["statuses"] || {})
          @delivery_mutex.synchronize do
            key_id = [session.id, message_id]
            @deliveries[key_id] = delivery unless delivery.complete?
            @pending_delivery_updates.delete(key_id).to_a.each do |participant_id, status|
              delivery.update(participant_id, status)
            end
            @deliveries.delete(key_id) if delivery.complete?
          end
          delivery
        rescue StaleKey
          retry if attempts < 2
          raise
        end
      end

      def send_unreliable(session, data, targets)
        epoch, key = session.current_key
        message_id = next_message_id
        envelope = Crypto.encrypt(data, session.encryption, key)
        if fast_path?
          begin
            packet = message_datagram(session.id, epoch, message_id, targets, envelope)
            return if send_datagram(packet)
          rescue ArgumentError
            nil
          end
        end
        send_frame({
          "type" => "unreliable", "session_id" => session.id, "epoch" => epoch,
          "message_id" => message_id, "targets" => targets,
          "data" => Base64.strict_encode64(envelope)
        }, important: false)
      end

      private

      def connect_control
        raw = Socket.tcp(@host, @port, connect_timeout: @timeout)
        raw.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(raw, context)
        ssl.sync_close = true
        ssl.hostname = @host if ssl.respond_to?(:hostname=)
        connect_tls(ssl)
        ssl.post_connection_check(@host)
        @control = ssl
        @writer_thread = Thread.new { writer_loop }
        @reader_thread = Thread.new { reader_loop }
        login = request(
          "login", { "version" => VERSION, "user" => @user, "token" => @token, "app_id" => @app_id },
          timeout: @timeout
        )
        @client_id = login["client_id"].to_s
        @datagram_secret = Base64.strict_decode64(login["datagram_secret"].to_s)
        apply_limits(login["limits"])
        start_datagrams
        @heartbeat_thread = Thread.new { heartbeat_loop }
      rescue AuthenticationError
        raise
      rescue Exception => error
        raise ConnectionError, "Cannot connect to communication service: #{error.message}"
      ensure
        @token = nil
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
            fail_connection(ConnectionError.new("Communication heartbeat timed out"), :connection_lost)
            break
          end
          nonce = SecureRandom.hex(8)
          send_frame({ "type" => "ping", "nonce" => nonce }, important: false)
          probe_datagrams
          sleep(limit(:ping_interval))
        end
      rescue Exception => error
        Log.warning("Communication heartbeat failed: #{error.class}: #{error.message}") if defined?(Log) && !closed?
      end

      def request(type, fields = {}, timeout: 5, **keywords)
        fields = fields.merge(keywords)
        waiter = Waiter.new
        request_id = nil
        @request_mutex.synchronize do
          raise ConnectionError, "Communication endpoint is closed" if closed?
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
        raise MessageTooLarge, "Control frame is too large" if payload.bytesize > limit(:max_frame)
        @outgoing.push([payload.bytesize].pack("N") + payload, true)
        true
      rescue ThreadError
        fail_connection(ConnectionError.new("Communication send queue is full"), :overloaded) if important
        false
      end

      def read_frame(io)
        header = read_exact(io, 4)
        size = header.unpack1("N")
        raise IOError, "Invalid communication frame" if size <= 0 || size > limit(:max_frame)
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
        when "invitation" then handle_invitation(frame)
        when "invitation_closed" then handle_invitation_closed(frame)
        when "invitation_status" then handle_invitation_status(frame)
        when "participant_joined" then session_for(frame)&.add_participant(frame["participant"] || {})
        when "participant_left" then session_for(frame)&.remove_participant_local(frame["participant_id"], frame["reason"] || "left")
        when "owner_changed" then session_for(frame)&.change_owner(frame["owner_id"])
        when "session_visibility" then session_for(frame)&.change_visibility(frame["public"])
        when "session_key" then handle_session_key(frame)
        when "session_closed" then handle_session_closed(frame)
        when "message" then handle_message(frame)
        when "delivery" then handle_delivery(frame)
        end
      end

      def handle_response(frame)
        waiter = @request_mutex.synchronize { @requests[frame["request_id"].to_s] }
        return if waiter == nil
        if frame["ok"] == true
          waiter.resolve(frame["result"])
        else
          waiter.resolve(nil, remote_error(frame["error"], frame["message"]))
        end
      end

      def handle_invitation(frame)
        invitation = Invitation.new(self, frame)
        @mutex.synchronize { @invitations[invitation.id] = invitation }
        @invitation_queue << invitation
        emit(:invitation, invitation)
      end

      def handle_invitation_closed(frame)
        invitation = @mutex.synchronize { @invitations.delete(frame["invitation_id"].to_s) }
        invitation&.close(frame["status"] || "closed")
      end

      def handle_invitation_status(frame)
        pair = @mutex.synchronize { @outgoing_invitations.delete(frame["invitation_id"].to_s) }
        return if pair == nil
        invitation, session = pair
        participant_data = frame["participant"]
        participant = participant_data.is_a?(Hash) ? session.participant(participant_data["id"]) : nil
        invitation.update(frame["status"] || "closed", participant)
      end

      def handle_session_key(frame)
        session = session_for(frame)
        return if session == nil
        session.apply_key(frame["epoch"], Base64.strict_decode64(frame["key"].to_s))
      rescue ArgumentError
        fail_connection(ConnectionError.new("Server returned an invalid session key"), :protocol_error)
      end

      def handle_session_closed(frame)
        session = @mutex.synchronize { @sessions.delete(frame["session_id"].to_s) }
        fail_session_operations(frame["session_id"], :session_closed)
        session&.close_local(frame["reason"] || "closed")
      end

      def handle_message(frame)
        session = session_for(frame)
        return if session == nil
        kind = (frame["kind"] || "unreliable").to_sym
        sender_id = frame["sender_id"].to_s
        message_id = frame["message_id"].to_i
        if duplicate_message?(session.id, sender_id, message_id, kind)
          acknowledge(session.id, sender_id, message_id, "delivered") if kind == :reliable
          return
        end
        envelope = frame["raw_data"] || Base64.strict_decode64(frame["data"].to_s)
        sender = session.participant(sender_id)
        raise Error, "Unknown message sender" if sender == nil
        data = session.decrypt(frame["epoch"], envelope)
        remember_message(session.id, sender_id, message_id, kind)
        session.deliver(kind, Message.new(sender: sender, data: data, id: message_id, kind: kind))
        acknowledge(session.id, sender_id, message_id, "delivered") if kind == :reliable
      rescue Exception => error
        acknowledge(frame["session_id"], frame["sender_id"], frame["message_id"], "failed") if frame["kind"] == "reliable"
        Log.warning("Communication message rejected: #{error.class}: #{error.message}") if defined?(Log)
      end

      def handle_delivery(frame)
        key = [frame["session_id"].to_s, frame["message_id"].to_i]
        @delivery_mutex.synchronize do
          delivery = @deliveries[key]
          if delivery == nil
            @pending_delivery_updates[key] << [frame["participant_id"], frame["status"]]
          else
            delivery.update(frame["participant_id"], frame["status"])
            @deliveries.delete(key) if delivery.complete?
          end
        end
      end

      def acknowledge(session_id, sender_id, message_id, status)
        send_frame({
          "type" => "ack", "session_id" => session_id, "sender_id" => sender_id,
          "message_id" => message_id, "status" => status
        }, important: false)
      end

      def store_session(data)
        session = Session.new(self, data)
        @mutex.synchronize { @sessions[session.id] = session }
        session
      end

      def session_for(frame)
        @mutex.synchronize { @sessions[frame["session_id"].to_s] }
      end

      def remote_error(code, message)
        klass = case code.to_s
                when "authentication_failed", "not_authenticated" then AuthenticationError
                when "peer_unavailable" then PeerUnavailable
                when "session_closed", "session_not_found" then SessionClosed
                when "message_too_large" then MessageTooLarge
                when "not_owner" then NotOwner
                when "stale_key" then StaleKey
                else RemoteError
                end
        klass == RemoteError ? klass.new(code, message) : klass.new(message.to_s)
      end

      def register_callback(kind, &block)
        raise ArgumentError, "callback is required" if block == nil
        @callback_mutex.synchronize { @callbacks[kind] << block }
        self
      end

      def emit(kind, *arguments)
        callbacks = @callback_mutex.synchronize { @callbacks[kind].dup }
        callbacks.each { |callback| enqueue_callback(callback, *arguments) }
      end

      def next_message_id
        @mutex.synchronize do
          @message_serial = (@message_serial + 1) & 0xffffffffffffffff
        end
      end

      def duplicate_message?(session_id, sender_id, message_id, kind)
        @received_mutex.synchronize { @received.key?([session_id, sender_id, message_id, kind]) }
      end

      def remember_message(session_id, sender_id, message_id, kind)
        @received_mutex.synchronize do
          @received[[session_id, sender_id, message_id, kind]] = monotonic
          @received.shift while @received.size > 4096
        end
      end

      def start_datagrams
        @datagram = UDPSocket.new
        @datagram.connect(@host, @port)
        @datagram_thread = Thread.new { datagram_reader_loop }
        send_registration
      rescue IOError, SystemCallError, SocketError => error
        @datagram&.close rescue nil
        @datagram = nil
        Log.warning("Communication fast path unavailable: #{error.class}: #{error.message}") if defined?(Log)
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
            handle_message(
              "kind" => "unreliable", "session_id" => parsed[:session_id],
              "sender_id" => parsed[:sender_id], "epoch" => parsed[:epoch],
              "message_id" => parsed[:message_id], "raw_data" => parsed[:envelope]
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
            type: type, session_id: bytes_id(data.byteslice(5, 16)),
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
        @outgoing.push(STOP_WRITER, true) rescue nil
        @control&.close rescue nil
        @datagram&.close rescue nil
      end

      def fail_session_operations(session_id, status)
        session_id = session_id.to_s
        deliveries = @delivery_mutex.synchronize do
          selected = @deliveries.select { |(id, _), _| id == session_id }
          selected.each_key { |key| @deliveries.delete(key) }
          selected.values
        end
        deliveries.each { |delivery| delivery.fail_pending(status) }
        invitations = @mutex.synchronize do
          selected = @outgoing_invitations.select { |_, (_, session)| session.id == session_id }
          selected.each_key { |key| @outgoing_invitations.delete(key) }
          selected.values.map(&:first)
        end
        invitations.each { |invitation| invitation.update(status) }
      end

      def fail_connection(error, reason)
        changed = @mutex.synchronize do
          next false if @closed
          @closed = true
          true
        end
        return unless changed
        Communication.unregister(self)
        close_transport
        waiters = @request_mutex.synchronize do
          current = @requests.values
          @requests = {}
          current
        end
        waiters.each { |waiter| waiter.resolve(nil, error) }
        deliveries = @delivery_mutex.synchronize do
          current = @deliveries.values
          @deliveries = {}
          @pending_delivery_updates.clear
          current
        end
        deliveries.each { |delivery| delivery.fail_pending(:connection_lost) }
        outgoing = @mutex.synchronize do
          current = @outgoing_invitations.values.map(&:first)
          @outgoing_invitations = {}
          @invitations.each_value { |invitation| invitation.close(:connection_lost) }
          @invitations = {}
          current
        end
        outgoing.each { |invitation| invitation.update(:connection_lost) }
        sessions = @mutex.synchronize do
          current = @sessions.values
          @sessions = {}
          current
        end
        sessions.each { |session| session.close_local(reason) }
        emit(:closed, error)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class << self
      def register(endpoint)
        endpoints_mutex.synchronize { endpoints << endpoint unless endpoints.include?(endpoint) }
      end

      def unregister(endpoint)
        endpoints_mutex.synchronize { endpoints.delete(endpoint) }
      end

      def tick
        current = endpoints_mutex.synchronize { endpoints.dup }
        current.sum { |endpoint| endpoint.dispatch_events }
      end

      private

      def endpoints
        @endpoints ||= []
      end

      def endpoints_mutex
        @endpoints_mutex ||= Mutex.new
      end
    end
  end
end
