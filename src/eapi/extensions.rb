# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

module Programs
  module Extensions
    class ExtensionError < Programs::ProgramError
    end

    class Definition
      attr_reader :name, :start_callback, :tick_callback, :tick_interval, :stop_callback, :settings_callback

      def initialize(name)
        @name = name.to_s
        raise ExtensionError, "Extension name must use lowercase letters, numbers and underscores" if @name !~ /\A[a-z][a-z0-9_]*\z/
        @tick_interval = 0.0
      end

      def start(&callback)
        single_callback!(:start, @start_callback)
        @start_callback = required_callback(callback)
      end

      def tick(interval: 0, &callback)
        single_callback!(:tick, @tick_callback)
        value = Float(interval) rescue nil
        raise ExtensionError, "Extension tick interval must be a non-negative number" if value == nil || value < 0
        @tick_interval = value
        @tick_callback = required_callback(callback)
      end

      def stop(&callback)
        single_callback!(:stop, @stop_callback)
        @stop_callback = required_callback(callback)
      end

      def settings(&callback)
        single_callback!(:settings, @settings_callback)
        @settings_callback = required_callback(callback)
      end

      private

      def required_callback(callback)
        raise ExtensionError, "Extension callback is required" if !callback.is_a?(Proc)
        callback
      end

      def single_callback!(kind, current)
        raise ExtensionError, "Extension #{name} already defines #{kind}" if current != nil
      end
    end

    class Registration
      attr_reader :runtime, :definition

      def initialize(runtime, definition)
        @runtime = runtime
        @definition = definition
        @started = false
        @stopped = false
        @running = false
        @last_tick = nil
      end

      def name
        @definition.name
      end

      def unregister(reason = :unload)
        Extensions.unregister(self, reason)
      end

      def registered?
        Extensions.registered?(self)
      end

      def start!
        return if @started || @stopped
        @started = true
        invoke(@definition.start_callback) if @definition.start_callback != nil
      end

      def tick!(now)
        return if !@started || @stopped || @running || @definition.tick_callback == nil
        return if @last_tick != nil && now - @last_tick < @definition.tick_interval
        @last_tick = now
        @running = true
        begin
          invoke(@definition.tick_callback)
        ensure
          @running = false
        end
      end

      def settings!(scene)
        return if !@started || @stopped || @definition.settings_callback == nil
        builder = SettingsBuilder.new(scene, self)
        invoke(@definition.settings_callback, builder)
        builder.render
      end

      def stop!(reason)
        return if @stopped
        @stopped = true
        invoke(@definition.stop_callback, reason) if @started && @definition.stop_callback != nil
      end

      def invoke(callback, *arguments)
        Programs.with_runtime(@runtime) { callback.call(*arguments) }
      end
    end

    class SettingsBuilder
      def initialize(scene, registration)
        @scene = scene
        @registration = registration
        @categories = []
        @current_category = nil
        @keys = {}
      end

      def category(label)
        raise ExtensionError, "Settings category label cannot be empty" if label.to_s.strip == ""
        @current_category = { :label => label.to_s, :settings => [] }
        @categories << @current_category
        true
      end

      def boolean(key, label:, get:, set:)
        add_bound(key, label, :bool, get, set,
          :encode => proc { |value| value == true ? "true" : "false" },
          :decode => proc { |value| value.to_s == "true" })
      end

      def integer(key, label:, get:, set:, range: nil)
        normalized_range = normalize_range(range)
        add_bound(key, label, :number, get, set,
          :encode => proc { |value| Integer(value).to_s },
          :decode => proc do |value|
            number = Integer(value)
            if normalized_range != nil && !normalized_range.include?(number)
              raise ExtensionError, "#{label} must be in #{normalized_range.begin}..#{normalized_range.end}"
            end
            number
          end)
      end

      def text(key, label:, get:, set:)
        add_bound(key, label, :text, get, set,
          :encode => proc { |value| value.to_s }, :decode => proc { |value| value.to_s })
      end

      def choice(key, label:, choices:, get:, set:)
        labels, values = normalize_choices(choices)
        lookup = choice_lookup(values)
        add_bound(key, label, labels, get, set,
          :mapping => values.map { |value| value.to_s },
          :encode => proc { |value| value.to_s },
          :decode => proc { |value| lookup.fetch(value.to_s) })
      end

      def multi_choice(key, label:, choices:, get:, set:)
        labels, values = normalize_choices(choices)
        lookup = choice_lookup(values)
        add_bound(key, label, labels, get, set,
          :mapping => values.map { |value| value.to_s }, :multi => true,
          :encode => proc { |value| Array(value).map { |item| item.to_s.delete(",") }.join(",") },
          :decode => proc { |value| value.to_s.split(",").reject { |item| item == "" }.map { |item| lookup.fetch(item) } })
      end

      def action(key, label:, &callback)
        ensure_category!
        use_key!(key)
        raise ExtensionError, "Settings action callback is required" if !callback.is_a?(Proc)
        wrapped = proc { @registration.invoke(callback) }
        @current_category[:settings] << [:action, label.to_s, wrapped]
        true
      end

      def render
        @categories.each do |category|
          @scene.setting_category(category[:label])
          category[:settings].each do |setting|
            if setting[0] == :action
              @scene.make_setting(setting[1], :custom, setting[2])
            else
              @scene.make_bound_setting(*setting[1..-1])
            end
          end
        end
        true
      end

      private

      def add_bound(key, label, type, getter, setter, mapping: nil, multi: false, encode:, decode:)
        ensure_category!
        use_key!(key)
        raise ExtensionError, "Settings getter and setter must be callable" if !getter.respond_to?(:call) || !setter.respond_to?(:call)
        binding_key = [@registration.runtime.manifest.id, @registration.name, key.to_s].join(":")
        wrapped_getter = proc { encode.call(@registration.invoke(getter)) }
        wrapped_setter = proc { |value| @registration.invoke(setter, decode.call(value)) }
        @current_category[:settings] << [:bound, label.to_s, type, binding_key, wrapped_getter, wrapped_setter, mapping, multi]
        true
      end

      def ensure_category!
        raise ExtensionError, "Call settings.category before adding settings" if @current_category == nil
      end

      def use_key!(key)
        value = key.to_s
        raise ExtensionError, "Settings key must use lowercase letters, numbers and underscores" if value !~ /\A[a-z][a-z0-9_]*\z/
        raise ExtensionError, "Duplicate extension settings key #{value}" if @keys[value]
        @keys[value] = true
      end

      def normalize_choices(choices)
        pairs = if choices.is_a?(Hash)
                  choices.to_a
                else
                  Array(choices).map { |choice| choice.is_a?(Array) && choice.size == 2 ? choice : [choice.to_s, choice] }
                end
        raise ExtensionError, "Settings choices cannot be empty" if pairs.empty?
        [pairs.map { |pair| pair[0].to_s }, pairs.map { |pair| pair[1] }]
      end

      def choice_lookup(values)
        lookup = {}
        values.each do |value|
          key = value.to_s
          raise ExtensionError, "Settings choice values must have unique string forms" if lookup.key?(key)
          raise ExtensionError, "Settings choice values cannot contain commas" if key.include?(",")
          lookup[key] = value
        end
        lookup
      end

      def normalize_range(range)
        return nil if range == nil
        raise ExtensionError, "Settings integer range must be a Range" if !range.is_a?(Range)
        range
      end
    end

    class << self
      def register(runtime, name, &block)
        raise ExtensionError, "Extensions require a loaded program runtime" if runtime == nil || !Programs.runtime_registered?(runtime)
        raise ExtensionError, "Extension definition callback is required" if !block.is_a?(Proc)
        definition = Definition.new(name)
        Programs.with_runtime(runtime) { block.call(definition) }
        definition.freeze
        registration = Registration.new(runtime, definition)
        key = registration_key(runtime, definition.name)
        mutex.synchronize do
          raise ExtensionError, "Extension #{definition.name} is already registered" if registrations.key?(key)
          registrations[key] = registration
        end
        begin
          registration.start!
        rescue Exception
          mutex.synchronize { registrations.delete(key) if registrations[key].equal?(registration) }
          registration.stop!(:load_rollback) rescue nil
          raise
        end
        registration
      end

      def tick
        active = begin_tick
        return if !active
        now = monotonic_time
        snapshot.each do |registration|
          begin
            registration.tick!(now)
          rescue Exception => error
            log_error("tick", registration, error)
          end
        end
      ensure
        end_tick if active
      end

      def render_settings(scene)
        snapshot.each do |registration|
          begin
            registration.settings!(scene)
          rescue Exception => error
            log_error("settings", registration, error)
          end
        end
        true
      end

      def unregister_runtime(runtime, reason = :unload)
        return true if runtime == nil
        removed = mutex.synchronize do
          selected = registrations.values.select { |registration| registration.runtime.equal?(runtime) }
          selected.each { |registration| registrations.delete(registration_key(runtime, registration.name)) }
          selected
        end
        stop_all(removed.reverse, reason)
        true
      end

      def unregister(registration, reason = :unload)
        removed = mutex.synchronize do
          key = registration_key(registration.runtime, registration.name)
          registrations.delete(key) if registrations[key].equal?(registration)
        end
        return false if removed == nil
        stop_all([removed], reason)
        true
      end

      def registered?(registration)
        mutex.synchronize do
          registrations[registration_key(registration.runtime, registration.name)].equal?(registration)
        end
      end

      def shutdown(reason = :client_shutdown)
        removed = mutex.synchronize do
          selected = registrations.values
          registrations.clear
          selected
        end
        stop_all(removed.reverse, reason)
        true
      end

      def count
        mutex.synchronize { registrations.size }
      end

      private

      def registrations
        @registrations ||= {}
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def registration_key(runtime, name)
        [runtime.object_id, name.to_s]
      end

      def snapshot
        mutex.synchronize { registrations.values.dup }
      end

      def begin_tick
        mutex.synchronize do
          return false if @ticking
          @ticking = true
        end
        true
      end

      def end_tick
        mutex.synchronize { @ticking = false } if defined?(@mutex) && @mutex != nil
      end

      def stop_all(selected, reason)
        selected.each do |registration|
          begin
            registration.stop!(reason.to_sym)
          rescue Exception => error
            log_error("stop", registration, error)
          end
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue Exception
        Time.now.to_f
      end

      def log_error(stage, registration, error)
        return if !defined?(Log)
        Log.error("Program extension #{registration.name} #{stage} failed: #{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}")
      end
    end
  end
end
