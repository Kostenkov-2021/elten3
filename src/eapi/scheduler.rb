# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

require "json"
require "fileutils"
require "monitor"

module EltenAPI
  module Scheduler
    VERSION = 1
    TICK_INTERVAL = 1.0
    KEY_PATTERN = /\A[a-z][a-z0-9_]*\z/

    class SchedulerError < StandardError
    end

    class TaskDefinition
      attr_reader :key, :interval, :autorun, :persistent, :first, :callback

      def initialize(key, seconds: 0, minutes: 0, hours: 0, days: 0, autorun: true,
        persistent: true, first: :after_interval, &callback)
        @key = key.to_s
        raise SchedulerError, "Scheduler task key must use lowercase letters, numbers and underscores" if @key !~ KEY_PATTERN
        @interval = duration(seconds, minutes, hours, days)
        raise SchedulerError, "Scheduler task interval must be greater than zero" if @interval <= 0
        raise SchedulerError, "Scheduler autorun must be true or false" if autorun != true && autorun != false
        raise SchedulerError, "Scheduler persistent must be true or false" if persistent != true && persistent != false
        @first = first.to_sym rescue nil
        raise SchedulerError, "Scheduler first must be after_interval or immediate" if ![:after_interval, :immediate].include?(@first)
        raise SchedulerError, "Scheduler task callback is required" if !callback.is_a?(Proc)
        @autorun = autorun
        @persistent = persistent
        @callback = callback
        freeze
      end

      private

      def duration(seconds, minutes, hours, days)
        values = [seconds, minutes, hours, days].map do |value|
          number = Float(value)
          raise SchedulerError, "Scheduler duration values must be non-negative numbers" if !number.finite? || number < 0
          number
        rescue ArgumentError, TypeError
          raise SchedulerError, "Scheduler duration values must be non-negative numbers"
        end
        values[0] + values[1] * 60 + values[2] * 3600 + values[3] * 86400
      end
    end

    class RunContext
      attr_reader :scheduled_at, :started_at, :last_success_at, :token

      def initialize(scheduled_at, started_at, last_success_at, token)
        @scheduled_at = Scheduler.time_value(scheduled_at)
        @started_at = Scheduler.time_value(started_at)
        @last_success_at = Scheduler.time_value(last_success_at)
        @token = token
        freeze
      end

      def late_by
        return 0.0 if @scheduled_at == nil || @started_at == nil
        [@started_at.to_f - @scheduled_at.to_f, 0.0].max
      end

      def catch_up?
        late_by > 0.001
      end
    end

    class TaskStatus
      attr_reader :next_run_at, :last_started_at, :last_finished_at, :last_success_at, :last_error

      def initialize(active, due, running, pending, state)
        @active = active
        @due = due
        @running = running
        @pending = pending
        @next_run_at = Scheduler.time_value(state[:next_run_at])
        @last_started_at = Scheduler.time_value(state[:last_started_at])
        @last_finished_at = Scheduler.time_value(state[:last_finished_at])
        @last_success_at = Scheduler.time_value(state[:last_success_at])
        @last_error = state[:last_error]
        freeze
      end

      def active?
        @active
      end

      def due?
        @due
      end

      def running?
        @running
      end

      def pending?
        @pending
      end
    end

    class TaskHandle
      attr_reader :key

      def initialize(full_key, key)
        @full_key = full_key
        @key = key.to_s
      end

      def trigger
        Scheduler.trigger_task(@full_key, self)
      end

      def status
        Scheduler.task_status(@full_key, self)
      end

      def active?
        status.active?
      end

      def due?
        status.due?
      end

      def running?
        status.running?
      end

      def pending?
        status.pending?
      end

      def next_run_at
        status.next_run_at
      end

      def last_started_at
        status.last_started_at
      end

      def last_finished_at
        status.last_finished_at
      end

      def last_success_at
        status.last_success_at
      end

      def last_error
        status.last_error
      end

      def unregister(remove_state: false)
        Scheduler.unregister_task(@full_key, self, remove_state: remove_state)
      end
    end

    Binding = Struct.new(:full_key, :owner_key, :store_kind, :scope, :persist_key,
      :definition, :registration, :runtime, :handle)
    Worker = Struct.new(:owner_key, :queue, :thread, :current_key, :current_token)

    class JsonStore
      def initialize(path, programs)
        @path = path
        @programs = programs
        @monitor = Monitor.new
        @loaded = false
        @data = nil
      end

      def fetch(scope, key)
        @monitor.synchronize do
          tasks = tasks_for(scope, false)
          record = tasks == nil ? nil : tasks[key.to_s]
          record.is_a?(Hash) ? record.dup : nil
        end
      end

      def put(scope, key, record)
        @monitor.synchronize do
          tasks_for(scope, true)[key.to_s] = record
          save
        end
      end

      def delete(scope, key)
        @monitor.synchronize do
          tasks = tasks_for(scope, false)
          return false if tasks == nil || tasks.delete(key.to_s) == nil
          clean_scope(scope)
          save_or_remove
          true
        end
      end

      def delete_scope(scope)
        @monitor.synchronize do
          load_data
          if @programs
            programs = @data["programs"]
            return false if !programs.is_a?(Hash) || programs.delete(scope.to_s) == nil
          else
            tasks = @data["tasks"]
            return false if !tasks.is_a?(Hash) || tasks.empty?
            tasks.clear
          end
          save_or_remove
          true
        end
      end

      private

      def default_data
        @programs ? { "version" => VERSION, "programs" => {} } : { "version" => VERSION, "tasks" => {} }
      end

      def load_data
        return @data if @loaded
        @loaded = true
        @data = default_data
        return @data if !File.file?(@path)
        parsed = JSON.parse(File.binread(@path).to_s)
        @data = parsed if parsed.is_a?(Hash)
        @data["version"] = VERSION
        @data[@programs ? "programs" : "tasks"] = {} if !@data[@programs ? "programs" : "tasks"].is_a?(Hash)
        @data
      rescue Exception => error
        Scheduler.log_warning("Ignoring invalid scheduler state #{@path}: #{error.class}: #{error.message}")
        @data = default_data
      end

      def tasks_for(scope, create)
        load_data
        return @data["tasks"] if !@programs
        programs = @data["programs"]
        entry = programs[scope.to_s]
        if !entry.is_a?(Hash)
          return nil if !create
          entry = programs[scope.to_s] = { "tasks" => {} }
        end
        if !entry["tasks"].is_a?(Hash)
          return nil if !create
          entry["tasks"] = {}
        end
        entry["tasks"]
      end

      def clean_scope(scope)
        return if !@programs
        entry = @data["programs"][scope.to_s]
        @data["programs"].delete(scope.to_s) if entry.is_a?(Hash) && entry["tasks"].is_a?(Hash) && entry["tasks"].empty?
      end

      def empty?
        collection = @data[@programs ? "programs" : "tasks"]
        !collection.is_a?(Hash) || collection.empty?
      end

      def save_or_remove
        if empty?
          File.delete(@path) if File.file?(@path)
          return true
        end
        save
      rescue Exception => error
        Scheduler.log_warning("Cannot remove empty scheduler state #{@path}: #{error.class}: #{error.message}")
        false
      end

      def save
        FileUtils.mkdir_p(File.dirname(@path))
        temporary = "#{@path}.tmp-#{$$}-#{Thread.current.object_id}"
        File.binwrite(temporary, JSON.pretty_generate(@data))
        FileUtils.mv(temporary, @path)
        true
      rescue Exception => error
        Scheduler.log_warning("Cannot save scheduler state #{@path}: #{error.class}: #{error.message}")
        false
      ensure
        File.delete(temporary) if temporary != nil && File.file?(temporary) rescue nil
      end
    end

    class << self
      def every(key, seconds: 0, minutes: 0, hours: 0, days: 0, autorun: true,
        persistent: true, first: :after_interval, &callback)
        definition = TaskDefinition.new(key, seconds: seconds, minutes: minutes, hours: hours,
          days: days, autorun: autorun, persistent: persistent, first: first, &callback)
        bind_task(Binding.new(
          "elten/#{definition.key}", "elten", :core, "elten", definition.key,
          definition, nil, nil, nil
        ))
      end

      def register_extension(registration)
        handles = []
        registration.definition.schedules.each do |definition|
          runtime = registration.runtime
          storage_id = Programs.storage_id_for_entry(runtime.entry_id, uuid: runtime.manifest.id)
          owner = "program/#{storage_id}"
          persist_key = "#{registration.name}/#{definition.key}"
          binding = Binding.new(
            "#{owner}/#{persist_key}", owner, :program, storage_id, persist_key,
            definition, registration, runtime, nil
          )
          handle = bind_task(binding)
          registration.__send__(:attach_scheduled_task, definition.key, handle)
          handles << handle
        end
        handles
      rescue Exception
        handles.each { |handle| handle.unregister rescue nil }
        raise
      end

      def tick
        now_mono = monotonic_time
        now = Time.now.to_f
        mutex.synchronize do
          return false if @shutting_down
          wake = @wake == true
          return false if !wake && @last_tick != nil && now_mono - @last_tick < TICK_INTERVAL
          @last_tick = now_mono
          @wake = false
          bindings.each_value do |binding|
            state = states[binding.full_key]
            next if state == nil || state[:running] || state[:queued]
            ready = state[:pending] || (binding.definition.autorun && state[:next_run_at].to_f <= now)
            next if !ready
            worker = worker_for(binding.owner_key)
            state[:queued] = true
            worker.queue << binding.full_key
          end
          workers.each_value do |worker|
            next if worker.queue.empty? || (worker.thread != nil && worker.thread.alive?)
            worker.thread = Thread.new(worker.owner_key) { |owner_key| worker_loop(owner_key) }
            worker.thread.report_on_exception = false if worker.thread.respond_to?(:report_on_exception=)
          end
        end
        true
      rescue Exception => error
        log_error("Scheduler tick failed", error)
        false
      end

      def trigger_task(full_key, expected_handle = nil)
        mutex.synchronize do
          binding = bindings[full_key]
          return :inactive if binding == nil
          return :inactive if expected_handle != nil && !binding.handle.equal?(expected_handle)
          state = states[full_key]
          return :inactive if state == nil
          return :running if state[:running]
          return :queued if state[:pending] || state[:queued]
          now = Time.now.to_f
          due = state[:last_started_at] == nil || state[:interrupted] || state[:next_run_at].to_f <= now
          return :not_due if !due
          state[:pending] = true
          state[:pending_at] = now
          @wake = true
          :queued
        end
      end

      def task_status(full_key, expected_handle = nil)
        mutex.synchronize do
          state = states[full_key] || fresh_state(nil, Time.now.to_f)
          binding = bindings[full_key]
          active = binding != nil && (expected_handle == nil || binding.handle.equal?(expected_handle))
          now = Time.now.to_f
          due = active && !state[:running] && (state[:last_started_at] == nil || state[:interrupted] || state[:next_run_at].to_f <= now)
          TaskStatus.new(active, due, state[:running] == true, state[:pending] == true || state[:queued] == true, state)
        end
      end

      def unregister_task(full_key, expected_handle = nil, remove_state: false, reason: :unload)
        expected = expected_handle == nil ? nil : { full_key => expected_handle }
        selected = detach_bindings([full_key], reason, expected)
        wait_for_keys(selected.map(&:full_key))
        remove_states(selected) if remove_state
        !selected.empty?
      end

      def unregister_extension(registration, reason = :unload)
        selected = mutex.synchronize do
          bindings.values.select { |binding| binding.registration.equal?(registration) }.map(&:full_key)
        end
        detached = detach_bindings(selected, reason)
        wait_for_keys(detached.map(&:full_key))
        true
      end

      def unregister_program_runtime(runtime, reason = :unload, remove_state: false)
        return true if runtime == nil
        selected = mutex.synchronize do
          bindings.values.select { |binding| binding.runtime.equal?(runtime) }.map(&:full_key)
        end
        detached = detach_bindings(selected, reason)
        owners = detached.map(&:owner_key).uniq
        wait_for_owners(owners)
        if remove_state
          scopes = detached.map(&:scope).uniq
          scopes.each { |scope| remove_program(scope) }
        end
        true
      end

      def remove_program(storage_id)
        scope = storage_id.to_s
        return false if scope == ""
        owner = "program/#{scope}"
        selected = mutex.synchronize do
          bindings.values.select { |binding| binding.owner_key == owner }.map(&:full_key)
        end
        detach_bindings(selected, :uninstall)
        wait_for_owners([owner])
        mutex.synchronize do
          states.delete_if { |key, _state| key.start_with?("#{owner}/") }
          workers.delete(owner)
        end
        program_store.delete_scope(scope)
        true
      end

      def shutdown(reason = :client_shutdown)
        selected = mutex.synchronize do
          @shutting_down = true
          bindings.keys
        end
        detached = detach_bindings(selected, reason)
        wait_for_owners(detached.map(&:owner_key).uniq)
        true
      end

      def time_value(value)
        value == nil ? nil : Time.at(value.to_f)
      rescue Exception
        nil
      end

      def log_warning(message)
        Log.warning(message) if defined?(Log)
      end

      private

      def bind_task(binding)
        raise SchedulerError, "Scheduler is shutting down" if mutex.synchronize { @shutting_down == true }
        if mutex.synchronize { bindings.key?(binding.full_key) }
          raise SchedulerError, "Scheduler task #{binding.persist_key} is already registered"
        end

        now = Time.now.to_f
        state = mutex.synchronize { states[binding.full_key] }
        if state != nil && state[:persistent] && !binding.definition.persistent
          store_for(binding.store_kind).delete(binding.scope, binding.persist_key)
          state = nil
        elsif state == nil && binding.definition.persistent
          state = state_from_record(store_for(binding.store_kind).fetch(binding.scope, binding.persist_key), now)
        elsif state == nil && !binding.definition.persistent
          # Remove state left by an older persistent version of this declaration.
          store_for(binding.store_kind).delete(binding.scope, binding.persist_key)
        end
        state ||= fresh_state(binding.definition, now)
        configure_state(state, binding.definition, now)
        handle = TaskHandle.new(binding.full_key, binding.definition.key)
        binding.handle = handle
        mutex.synchronize do
          raise SchedulerError, "Scheduler task #{binding.persist_key} is already registered" if bindings.key?(binding.full_key)
          bindings[binding.full_key] = binding
          states[binding.full_key] = state
          @wake = true if binding.definition.autorun && state[:next_run_at].to_f <= now
        end
        persist(binding, state) if binding.definition.persistent
        handle
      end

      def configure_state(state, definition, now)
        old_interval = state[:interval]
        state[:created_at] ||= now
        state[:interval] = definition.interval
        state[:autorun] = definition.autorun
        state[:persistent] = definition.persistent
        state[:first] = definition.first
        state[:pending] = false
        state[:pending_at] = nil
        state[:queued] = false
        if state.delete(:loaded_running)
          state[:running] = false
          state[:interrupted] = true
          state[:next_run_at] = now if definition.autorun
        elsif state[:next_run_at] == nil || (old_interval != nil && old_interval.to_f != definition.interval)
          base = state[:last_started_at] || state[:created_at]
          state[:next_run_at] = if state[:last_started_at] == nil && definition.first == :immediate
                                  now
                                else
                                  base.to_f + definition.interval
                                end
        end
        state[:running] = false
      end

      def fresh_state(definition, now)
        interval = definition == nil ? 0.0 : definition.interval
        first = definition == nil ? :after_interval : definition.first
        {
          :created_at => now,
          :next_run_at => first == :immediate ? now : now + interval,
          :last_started_at => nil,
          :last_finished_at => nil,
          :last_success_at => nil,
          :last_error => nil,
          :running => false,
          :pending => false,
          :pending_at => nil,
          :queued => false,
          :interrupted => false,
          :interval => interval,
          :autorun => definition == nil ? false : definition.autorun,
          :persistent => definition == nil ? false : definition.persistent,
          :first => first
        }
      end

      def state_from_record(record, now)
        return nil if !record.is_a?(Hash)
        state = fresh_state(nil, now)
        [:created_at, :next_run_at, :last_started_at, :last_finished_at, :last_success_at].each do |key|
          state[key] = numeric_value(record[key.to_s])
        end
        state[:created_at] ||= now
        state[:interval] = numeric_value(record["interval"])
        state[:autorun] = record["autorun"] == true
        state[:persistent] = true
        state[:last_error] = record["last_error"].to_s if record["last_error"] != nil
        state[:loaded_running] = record["running"] == true
        state[:interrupted] = record["interrupted"] == true
        state
      end

      def numeric_value(value)
        return nil if value == nil
        number = Float(value)
        number.finite? ? number : nil
      rescue ArgumentError, TypeError
        nil
      end

      def state_record(state)
        {
          "interval" => state[:interval],
          "autorun" => state[:autorun] == true,
          "created_at" => state[:created_at],
          "next_run_at" => state[:next_run_at],
          "last_started_at" => state[:last_started_at],
          "last_finished_at" => state[:last_finished_at],
          "last_success_at" => state[:last_success_at],
          "running" => state[:running] == true,
          "interrupted" => state[:interrupted] == true,
          "last_error" => state[:last_error]
        }
      end

      def persist(binding, state)
        return if !state[:persistent]
        store_for(binding.store_kind).put(binding.scope, binding.persist_key, state_record(state))
      end

      def detach_bindings(keys, reason, expected_handles = nil)
        selected = nil
        tokens = []
        mutex.synchronize do
          selected = keys.map do |key|
            binding = bindings[key]
            expected = expected_handles == nil ? nil : expected_handles[key]
            next if binding == nil || (expected != nil && !binding.handle.equal?(expected))
            bindings.delete(key)
          end.compact
          selected.each do |binding|
            state = states[binding.full_key]
            if state != nil
              state[:pending] = false
              state[:pending_at] = nil
              state[:queued] = false
            end
            worker = workers[binding.owner_key]
            next if worker == nil
            worker.queue.delete(binding.full_key)
            if worker.current_key == binding.full_key && worker.current_token != nil
              tokens << worker.current_token
            end
          end
        end
        cancellation = Tasks::Cancelled.new("Scheduled task stopped: #{reason}")
        tokens.uniq.each { |token| token.cancel(cancellation) }
        selected
      end

      def remove_states(selected)
        selected.each do |binding|
          mutex.synchronize { states.delete(binding.full_key) }
          store_for(binding.store_kind).delete(binding.scope, binding.persist_key)
        end
      end

      def wait_for_keys(keys)
        return if keys.empty?
        loop do
          running = mutex.synchronize { keys.any? { |key| states[key] != nil && states[key][:running] } }
          break if !running
          wait_step
        end
      end

      def wait_for_owners(owner_keys)
        owner_keys.uniq.each do |owner|
          loop do
            thread = mutex.synchronize do
              worker = workers[owner]
              worker == nil ? nil : worker.thread
            end
            break if thread == nil || !thread.alive? || thread.equal?(Thread.current)
            thread.join(0.05)
            service_window
          end
        end
      end

      def wait_step
        service_window
        sleep(0.05)
      end

      def service_window
        if defined?($mainthread) && Thread.current == $mainthread && defined?(EltenWindow) && EltenWindow.respond_to?(:service_window_update)
          EltenWindow.service_window_update
        end
      rescue Exception
      end

      def worker_loop(owner_key)
        loop do
          binding = nil
          state = nil
          context = nil
          mutex.synchronize do
            worker = workers[owner_key]
            return if worker == nil
            full_key = worker.queue.shift
            if full_key == nil
              worker.thread = nil if worker.thread.equal?(Thread.current)
              return
            end
            binding = bindings[full_key]
            state = states[full_key]
            if binding != nil && state != nil
              state[:queued] = false
              started_at = Time.now.to_f
              scheduled_at = state[:pending_at] || state[:next_run_at] || started_at
              token = Tasks::CancellationToken.new
              state[:pending] = false
              state[:pending_at] = nil
              state[:running] = true
              state[:interrupted] = false
              state[:last_started_at] = started_at
              state[:next_run_at] = started_at + binding.definition.interval
              worker.current_key = full_key
              worker.current_token = token
              context = RunContext.new(scheduled_at, started_at, state[:last_success_at], token)
            end
          end
          next if binding == nil || state == nil || context == nil

          persist(binding, state)
          error = nil
          begin
            invoke(binding, context)
          rescue Exception => caught
            error = caught
            log_task_error(binding, caught) if !caught.is_a?(Tasks::Cancelled)
          ensure
            finished_at = Time.now.to_f
            final_state = nil
            mutex.synchronize do
              current = states[binding.full_key]
              if current != nil
                current[:running] = false
                current[:last_finished_at] = finished_at
                if error == nil
                  current[:last_success_at] = finished_at
                  current[:last_error] = nil
                else
                  current[:last_error] = "#{error.class}: #{error.message}"
                end
                final_state = current
              end
              worker = workers[owner_key]
              if worker != nil && worker.current_key == binding.full_key
                worker.current_key = nil
                worker.current_token = nil
              end
            end
            persist(binding, final_state) if final_state != nil
          end
        end
      rescue Exception => error
        log_error("Scheduler worker #{owner_key} failed", error)
      ensure
        mutex.synchronize do
          worker = workers[owner_key]
          if worker != nil && worker.thread.equal?(Thread.current)
            worker.thread = nil
            worker.current_key = nil
            worker.current_token = nil
          end
        end
      end

      def invoke(binding, context)
        callback = binding.definition.callback
        arguments = callback.arity == 0 ? [] : [context]
        if binding.registration != nil
          binding.registration.invoke(callback, *arguments)
        else
          callback.call(*arguments)
        end
      end

      def worker_for(owner_key)
        workers[owner_key] ||= Worker.new(owner_key, [], nil, nil, nil)
      end

      def store_for(kind)
        kind == :program ? program_store : core_store
      end

      def core_store
        @core_store ||= JsonStore.new(EltenPath.join(Dirs.eltendata, "scheduler.json"), false)
      end

      def program_store
        @program_store ||= JsonStore.new(EltenPath.join(Programs.appsdata_dir, "scheduler.json"), true)
      end

      def bindings
        @bindings ||= {}
      end

      def states
        @states ||= {}
      end

      def workers
        @workers ||= {}
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue Exception
        Time.now.to_f
      end

      def log_task_error(binding, error)
        log_error("Scheduled task #{binding.full_key} failed", error)
      end

      def log_error(message, error)
        return if !defined?(Log)
        Log.error("#{message}: #{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}")
      end
    end
  end
end
