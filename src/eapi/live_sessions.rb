# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# frozen_string_literal: true

require "json"
require "securerandom"
require "thread"

module EltenAPI
  module LiveSessions
    CONTROL_INTERVAL = 5.0
    CONTROL_RETRY_INTERVAL = 2.0
    MAX_PENDING_INVITATIONS = 128

    class Error < StandardError; end
    class TimeoutError < Error; end
    class SessionClosed < Error; end
    class NotOwner < Error; end

    Message = Struct.new(:id, :sequence, :sender, :packet, keyword_init: true)

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
            return nil if !deadline.nil? && deadline <= monotonic
            @condition.wait(@mutex, deadline == nil ? nil : deadline - monotonic)
          end
          @items.shift
        end
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class Participant
      attr_reader :id, :user, :metadata, :joined_at

      def initialize(data)
        update(data)
      end

      def update(data)
        @id = data["id"].to_s
        @user = data["user"].to_s
        @metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
        @joined_at = data["joined_at"].to_i
        self
      end
    end

    class Invitation
      attr_reader :id, :metadata, :invitation_metadata, :inviter, :capacity, :expires_at

      def initialize(endpoint, data)
        @endpoint = endpoint
        @id = data["session_id"].to_s
        @metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
        @invitation_metadata = data["invitation_metadata"].is_a?(Hash) ? data["invitation_metadata"] : {}
        @inviter = Participant.new(data["invited_by"].is_a?(Hash) ? data["invited_by"] : {})
        @capacity = data["capacity"].to_i
        @expires_at = data["expires_at"].to_i
        @state = :pending
      end

      def accept(participant_metadata: {})
        raise Error, "Invitation is no longer pending" unless pending?
        session = @endpoint.accept_invitation(self, participant_metadata)
        @state = :accepted
        session
      end

      def reject
        return false unless pending?
        @endpoint.reject_invitation(self)
        @state = :rejected
        true
      end

      def pending?
        @state == :pending && !expired?
      end

      def expired?
        @expires_at.positive? && Time.now.to_i >= @expires_at
      end
    end

    class Session
      attr_reader :id, :metadata, :capacity, :owner_id, :participant_id, :state

      def initialize(endpoint, data)
        @endpoint = endpoint
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @callbacks = Hash.new { |hash, key| hash[key] = [] }
        @messages = EventQueue.new
        @participants = {}
        @ack = 0
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

      def owner?
        @participant_id == @owner_id
      end

      def closed?
        @mutex.synchronize { @state == :closed }
      end

      def invite(user, metadata: {})
        ensure_open!
        @endpoint.invite(self, user, metadata)
      end

      def invite_all(users, metadata: {})
        Array(users).map { |user| invite(user, metadata: metadata) }
      end

      def send(packet)
        ensure_open!
        validate_json!(packet)
        @endpoint.send_packet(self, packet)
      end

      def receive(timeout: nil)
        @messages.pop(timeout: timeout)
      end

      def leave
        return false if closed?
        @endpoint.leave_session(self)
        close_local(:left)
        true
      end

      def close
        ensure_open!
        raise NotOwner, "Only the live session owner can close it" unless owner?
        @endpoint.close_session(self)
        close_local(:closed)
        true
      end

      def on_message(&block); register_callback(:message, &block); end
      def on_participant_joined(&block); register_callback(:participant_joined, &block); end
      def on_participant_left(&block); register_callback(:participant_left, &block); end
      def on_gap(&block); register_callback(:gap, &block); end
      def on_closed(&block); register_callback(:closed, &block); end

      def wait_for_participant(user = nil, timeout: 10)
        deadline = monotonic + timeout.to_f
        @mutex.synchronize do
          loop do
            found = @participants.values.find do |entry|
              entry.id != @participant_id && (user == nil || entry.user.casecmp?(user.to_s))
            end
            return found unless found.nil?
            raise SessionClosed, "Live session is closed" if @state == :closed
            remaining = deadline - monotonic
            raise TimeoutError, "Participant did not join in time" if remaining <= 0
            @condition.wait(@mutex, remaining)
          end
        end
      end

      def control_entry
        @mutex.synchronize do
          {
            "id" => @id,
            "participant_id" => @participant_id,
            "ack" => @ack
          }
        end
      end

      def apply_envelope(data)
        apply_snapshot(data)
        seen = @mutex.synchronize { @ack }
        Array(data["events"]).sort_by { |event| event["seq"].to_i }.each do |event|
          sequence = event["seq"].to_i
          next if sequence <= seen
          apply_event(event)
          seen = sequence
        end
        cursor = data["cursor"].to_i
        @mutex.synchronize { @ack = [@ack, cursor].max }
        data["has_more"] == true
      end

      def close_local(reason)
        changed = @mutex.synchronize do
          next false if @state == :closed
          @state = :closed
          @condition.broadcast
          true
        end
        if changed
          @endpoint.session_closed(self)
          emit(:closed, reason.to_sym)
        end
        changed
      end

      private

      def apply_snapshot(data)
        @mutex.synchronize do
          @id = (data["id"] || data["session_id"] || @id).to_s
          @metadata = data["metadata"] if data["metadata"].is_a?(Hash)
          @metadata ||= {}
          @capacity = data["capacity"].to_i if data.key?("capacity")
          @owner_id = data["owner_id"].to_s unless data["owner_id"].to_s.empty?
          @participant_id = data["participant_id"].to_s unless data["participant_id"].to_s.empty?
          if data["participants"].is_a?(Array)
            current = {}
            data["participants"].each do |row|
              next unless row.is_a?(Hash)
              id = row["id"].to_s
              next if id.empty?
              current[id] = @participants[id]&.update(row) || Participant.new(row)
            end
            @participants = current
            @condition.broadcast
          end
        end
      end

      def apply_event(event)
        case event["type"].to_s
        when "message"
          sender_data = event["sender"].is_a?(Hash) ? event["sender"] : {}
          sender = participant(event["sender_id"]) || Participant.new(sender_data)
          message = Message.new(
            id: event["message_id"].to_s,
            sequence: event["seq"].to_i,
            sender: sender,
            packet: event["packet"]
          )
          @messages << message
          emit(:message, sender, message.packet)
        when "participant_joined"
          row = event["participant"]
          if row.is_a?(Hash)
            item = @mutex.synchronize do
              id = row["id"].to_s
              @participants[id] ||= Participant.new(row)
            end
            emit(:participant_joined, item)
          end
        when "participant_left"
          row = event["participant"].is_a?(Hash) ? event["participant"] : {}
          item = @mutex.synchronize do
            removed = @participants.delete(row["id"].to_s)
            @condition.broadcast
            removed || Participant.new(row)
          end
          emit(:participant_left, item, event["reason"].to_s.to_sym)
        when "gap"
          emit(:gap, event["from"].to_i, event["to"].to_i)
        when "closed"
          close_local(event["reason"].to_s.empty? ? :closed : event["reason"])
        end
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

      def ensure_open!
        raise SessionClosed, "Live session is closed" if closed?
      end

      def validate_json!(value)
        JSON.generate(value)
      rescue JSON::GeneratorError
        raise ArgumentError, "packet must be JSON-convertible"
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class Endpoint
      attr_reader :app_id, :instance_id, :user

      def initialize(app_id:, client:, user: nil, token: nil)
        @app_id = app_id.to_s.downcase
        @client = client
        @user = (user || session_value(:name)).to_s
        @token = (token || session_value(:token)).to_s
        unless @app_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
          raise ArgumentError, "A valid app_id is required"
        end
        raise Error, "Elten user is not logged in" if @user.empty? || @token.empty?
        @instance_id = SecureRandom.uuid
        @mutex = Mutex.new
        @sessions = {}
        @invitations = {}
        @resolved_invitations = {}
        @pending_envelopes = Hash.new { |hash, key| hash[key] = [] }
        @callbacks = Hash.new { |hash, key| hash[key] = [] }
        @callback_queue = Queue.new
        @invitation_queue = EventQueue.new
        @control_responses = Queue.new
        @control_pending = false
        @next_control_at = monotonic
        @closed = false
        LiveSessions.register(self)
      end

      def create(metadata: {}, participant_metadata: {}, capacity: 2)
        ensure_open!
        data = EltenLink::Apps.create_live_session(
          @client,
          appid: @app_id,
          instance_id: @instance_id,
          metadata: metadata,
          participant_metadata: participant_metadata,
          capacity: capacity
        )
        store_session(data)
      end

      def connect(user, metadata: {}, participant_metadata: {}, capacity: 2, timeout: 10)
        session = create(metadata: metadata, participant_metadata: participant_metadata, capacity: capacity)
        session.invite(user)
        session.wait_for_participant(user, timeout: timeout)
        session
      rescue Exception
        session&.close rescue nil
        raise
      end

      def sessions
        @mutex.synchronize { @sessions.values.reject(&:closed?) }
      end

      def on_invitation(&block)
        register_callback(:invitation, &block)
      end

      def next_invitation(timeout: nil)
        @invitation_queue.pop(timeout: timeout)
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def close
        current = @mutex.synchronize do
          return false if @closed
          @closed = true
          @sessions.values.reject(&:closed?)
        end
        current.each do |session|
          begin
            EltenLink::Apps.leave_live_session(
              @client,
              session_id: session.id,
              participant_id: session.participant_id
            )
          rescue Exception
            nil
          ensure
            session.close_local(:endpoint_closed)
          end
        end
        LiveSessions.unregister(self)
        true
      end

      def invite(session, user, metadata)
        ensure_session!(session)
        EltenLink::Apps.invite_live_session(
          @client,
          session_id: session.id,
          participant_id: session.participant_id,
          user: user.to_s,
          metadata: metadata
        )
      end

      def accept_invitation(invitation, participant_metadata)
        ensure_open!
        data = EltenLink::Apps.accept_live_session(
          @client,
          session_id: invitation.id,
          appid: @app_id,
          instance_id: @instance_id,
          participant_metadata: participant_metadata
        )
        resolve_invitation(invitation.id)
        store_session(data)
      end

      def reject_invitation(invitation)
        ensure_open!
        EltenLink::Apps.reject_live_session(@client, session_id: invitation.id, appid: @app_id)
        resolve_invitation(invitation.id)
        true
      end

      def send_packet(session, packet)
        ensure_session!(session)
        EltenLink::Apps.send_live_session(
          @client,
          session_id: session.id,
          participant_id: session.participant_id,
          packet: packet,
          message_id: SecureRandom.uuid
        )
      end

      def leave_session(session)
        ensure_session!(session)
        EltenLink::Apps.leave_live_session(
          @client,
          session_id: session.id,
          participant_id: session.participant_id
        )
      end

      def close_session(session)
        ensure_session!(session)
        EltenLink::Apps.close_live_session(
          @client,
          session_id: session.id,
          participant_id: session.participant_id
        )
      end

      def session_closed(_session)
        true
      end

      def enqueue_callback(callback, *arguments)
        @callback_queue << [callback, arguments]
        true
      end

      def enqueue_envelope(envelope)
        return false if closed?
        kind = envelope["kind"].to_s
        if kind == "events" && envelope["instance_id"].to_s != @instance_id
          return false
        end
        if kind == "invitation"
          receive_invitation(envelope)
        elsif kind == "events"
          receive_events(envelope)
        end
        true
      end

      def tick
        return false if closed?
        drain_control_responses
        dispatch_events
        expire_invitations
        now = monotonic
        start_control(now) if now >= @next_control_at.to_f
        true
      end

      def dispatch_events(limit = 100)
        count = 0
        while count < limit
          callback, arguments = @callback_queue.pop(true)
          begin
            callback.call(*arguments)
          rescue Exception => error
            Log.warning("Live session callback failed: #{error.class}: #{error.message}") if defined?(Log)
          end
          count += 1
        end
        count
      rescue ThreadError
        count
      end

      private

      def receive_invitation(data)
        invitation = nil
        @mutex.synchronize do
          id = data["session_id"].to_s
          return if id.empty? || @resolved_invitations.key?(id) || @invitations.key?(id)
          invitation = Invitation.new(self, data)
          @invitations[id] = invitation
        end
        @invitation_queue << invitation
        emit(:invitation, invitation)
      end

      def receive_events(data)
        session = @mutex.synchronize { @sessions[data["session_id"].to_s] }
        if session.nil?
          @mutex.synchronize do
            queue = @pending_envelopes[data["session_id"].to_s]
            queue << data
            queue.shift while queue.length > 32
          end
          return
        end
        request_control if session.apply_envelope(data)
      end

      def store_session(data)
        session = Session.new(self, data)
        pending = @mutex.synchronize do
          existing = @sessions[session.id]
          if existing.nil?
            @sessions[session.id] = session
          else
            session = existing
          end
          @next_control_at = monotonic
          @pending_envelopes.delete(session.id) || []
        end
        pending.each { |envelope| session.apply_envelope(envelope) }
        session
      end

      def resolve_invitation(id)
        @mutex.synchronize do
          @invitations.delete(id.to_s)
          @resolved_invitations[id.to_s] = Time.now.to_i
          @resolved_invitations.shift while @resolved_invitations.length > MAX_PENDING_INVITATIONS
        end
      end

      def expire_invitations
        now = Time.now.to_i
        @mutex.synchronize do
          @invitations.delete_if { |_id, invitation| invitation.expires_at.positive? && invitation.expires_at <= now }
          @resolved_invitations.delete_if { |_id, time| time < now - 300 }
        end
      end

      def start_control(now)
        entries = sessions.map(&:control_entry)
        @mutex.synchronize do
          @next_control_at = now + CONTROL_INTERVAL
          return if @control_pending || entries.empty? || @closed
          @control_pending = true
        end
        path = EltenLink::Client.append_query(
          "/api/v1/apps/live-sessions/control",
          { "name" => @user, "token" => @token }
        )
        @client.e_json_request(
          "POST",
          path,
          { "appid" => @app_id, "instance_id" => @instance_id, "sessions" => entries }
        ) do |answer, _data|
          @control_responses << answer
        end
      rescue Exception => error
        @mutex.synchronize do
          @control_pending = false
          @next_control_at = monotonic + CONTROL_RETRY_INTERVAL
        end
        Log.warning("Live session control failed: #{error.class}: #{error.message}") if defined?(Log)
      end

      def drain_control_responses
        loop do
          answer = @control_responses.pop(true)
          @mutex.synchronize { @control_pending = false }
          payload = answer.is_a?(String) ? JSON.parse(answer) : nil
          data = payload.is_a?(Hash) && payload["success"] == true ? payload["data"] : nil
          unless data.is_a?(Hash) && data["accepted"] == true
            request_control(CONTROL_RETRY_INTERVAL)
            next
          end
          lease = data["lease_seconds"].to_f
          interval = lease.positive? ? [[lease / 3.0, 2.0].max, CONTROL_INTERVAL].min : CONTROL_INTERVAL
          @mutex.synchronize { @next_control_at = monotonic + interval }
          Array(data["sessions"]).each do |status|
            next unless status.is_a?(Hash) && status["accepted"] != true
            session = @mutex.synchronize { @sessions[status["id"].to_s] }
            session&.close_local((status["reason"] || "expired").to_sym)
          end
        end
      rescue ThreadError
        nil
      rescue JSON::ParserError, TypeError
        request_control(CONTROL_RETRY_INTERVAL)
      end

      def request_control(delay = 0)
        @mutex.synchronize { @next_control_at = [@next_control_at.to_f, monotonic + delay.to_f].min }
      end

      def ensure_session!(session)
        ensure_open!
        known = @mutex.synchronize { @sessions[session.id].equal?(session) }
        raise ArgumentError, "session does not belong to this endpoint" unless known
        raise SessionClosed, "Live session is closed" if session.closed?
        true
      end

      def ensure_open!
        raise SessionClosed, "Live session endpoint is closed" if closed?
      end

      def register_callback(kind, &block)
        raise ArgumentError, "callback is required" if block == nil
        @mutex.synchronize { @callbacks[kind] << block }
        self
      end

      def emit(kind, *arguments)
        callbacks = @mutex.synchronize { @callbacks[kind].dup }
        callbacks.each { |callback| enqueue_callback(callback, *arguments) }
      end

      def session_value(name)
        session = if defined?(EltenAPI::Structs::Session)
                    EltenAPI::Structs::Session
                  elsif Object.const_defined?(:Session)
                    Object.const_get(:Session)
                  end
        session.respond_to?(name) ? session.public_send(name) : nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    class << self
      def register(endpoint)
        mutex.synchronize do
          endpoints << endpoint
          pending_for(endpoint.app_id).each { |envelope| endpoint.enqueue_envelope(envelope) }
        end
        true
      end

      def unregister(endpoint)
        mutex.synchronize { endpoints.delete(endpoint) }
        true
      end

      def receive(rows)
        Array(rows).each do |row|
          next unless row.is_a?(Hash)
          appid = row["appid"].to_s.downcase
          selected = mutex.synchronize do
            found = endpoints.select { |endpoint| endpoint.app_id == appid && !endpoint.closed? }
            remember_pending(appid, row) if found.empty? && row["kind"].to_s == "invitation"
            found
          end
          selected.each { |endpoint| endpoint.enqueue_envelope(row) }
        end
        true
      end

      def tick
        current = mutex.synchronize do
          cleanup_pending
          endpoints.dup
        end
        current.each(&:tick)
        true
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end

      def endpoints
        @endpoints ||= []
      end

      def pending
        @pending ||= Hash.new { |hash, key| hash[key] = {} }
      end

      def pending_for(appid)
        pending[appid.to_s.downcase].values
      end

      def remember_pending(appid, row)
        bucket = pending[appid]
        bucket[row["session_id"].to_s] = row
        bucket.shift while bucket.length > MAX_PENDING_INVITATIONS
      end

      def cleanup_pending
        now = Time.now.to_i
        pending.delete_if do |_appid, bucket|
          bucket.delete_if { |_id, row| row["expires_at"].to_i.positive? && row["expires_at"].to_i <= now }
          bucket.empty?
        end
      end
    end
  end
end
