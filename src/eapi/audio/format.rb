# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3.

module Audio
  class Error < StandardError; end
  class DecodeError < Error; end
  class FormatMismatch < Error; end
  class EncodingError < Error; end
  class UnsupportedOperation < Error; end

  class Format
    SAMPLE_TYPES = {
      :u8 => [:u8, 1],
      :s16le => [:s16le, 2],
      :float => [:float32le, 4],
      :float32 => [:float32le, 4],
      :float32le => [:float32le, 4]
    }.freeze

    attr_reader :sample_rate, :channels, :sample_type

    def initialize(sample_rate:, channels:, sample_type: :float32le)
      @sample_rate = Integer(sample_rate)
      @channels = Integer(channels)
      entry = SAMPLE_TYPES[sample_type.to_sym] if sample_type.respond_to?(:to_sym)
      raise ArgumentError, "Unsupported PCM sample type #{sample_type.inspect}" if entry == nil
      raise ArgumentError, "Audio sample rate must be positive" if @sample_rate <= 0
      raise ArgumentError, "Audio channel count must be between 1 and 32" if @channels < 1 || @channels > 32
      @sample_type = entry[0]
      @bytes_per_sample = entry[1]
      freeze
    end

    def frequency
      @sample_rate
    end

    def bytes_per_sample
      @bytes_per_sample
    end

    def bytes_per_frame
      @bytes_per_sample * @channels
    end

    def bytes_per_second
      bytes_per_frame * @sample_rate
    end

    def frames_for_seconds(seconds)
      seconds = Float(seconds)
      raise ArgumentError, "Audio time must be finite" if !seconds.finite?
      (seconds * @sample_rate).round
    rescue TypeError
      raise ArgumentError, "Audio time must be numeric"
    end

    def seconds_for_frames(frames)
      Integer(frames).to_f / @sample_rate
    end

    def bytes_for_frames(frames)
      Integer(frames) * bytes_per_frame
    end

    def frames_for_bytes(bytes, strict: true)
      bytes = Integer(bytes)
      if strict && bytes % bytes_per_frame != 0
        raise FormatMismatch, "PCM data does not contain complete frames (#{bytes_per_frame} bytes per frame)"
      end
      bytes / bytes_per_frame
    end

    def with(sample_rate: @sample_rate, channels: @channels, sample_type: @sample_type)
      self.class.new(:sample_rate => sample_rate, :channels => channels, :sample_type => sample_type)
    end

    def ==(other)
      other.is_a?(Format) &&
        other.sample_rate == @sample_rate &&
        other.channels == @channels &&
        other.sample_type == @sample_type
    end
    alias eql? ==

    def hash
      [@sample_rate, @channels, @sample_type].hash
    end

    def inspect
      "#<#{self.class} #{@sample_rate}Hz #{@channels}ch #{@sample_type}>"
    end
  end

  class FormatConstraint
    attr_reader :sample_types, :sample_rates, :channels

    def initialize(sample_types: nil, sample_rates: nil, channels: nil)
      @sample_types = normalize_sample_types(sample_types)
      @sample_rates = normalize_numeric_constraint(sample_rates, "sample rates")
      @channels = normalize_numeric_constraint(channels, "channel counts")
      freeze
    end

    def allows?(format)
      format.is_a?(Format) &&
        (@sample_types == nil || @sample_types.include?(format.sample_type)) &&
        numeric_allowed?(@sample_rates, format.sample_rate) &&
        numeric_allowed?(@channels, format.channels)
    end

    def negotiate(format)
      raise ArgumentError, "Expected Audio::Format" if !format.is_a?(Format)
      return format if allows?(format)
      Format.new(
        :sample_rate => choose_numeric(@sample_rates, format.sample_rate),
        :channels => choose_numeric(@channels, format.channels),
        :sample_type => @sample_types == nil ? format.sample_type : @sample_types.first
      )
    end

    private

    def normalize_sample_types(values)
      return nil if values == nil
      types = Array(values).map do |value|
        entry = Format::SAMPLE_TYPES[value.to_sym] if value.respond_to?(:to_sym)
        raise ArgumentError, "Unsupported PCM sample type #{value.inspect}" if entry == nil
        entry[0]
      end.uniq
      raise ArgumentError, "Audio sample type constraint cannot be empty" if types.empty?
      types.freeze
    end

    def normalize_numeric_constraint(value, label)
      return nil if value == nil
      if value.is_a?(Range)
        first = Integer(value.begin)
        last = Integer(value.end)
        last -= 1 if value.exclude_end?
        raise ArgumentError, "Audio #{label} constraint cannot be empty" if first > last
        return (first..last)
      end
      values = Array(value).map { |entry| Integer(entry) }.uniq
      raise ArgumentError, "Audio #{label} constraint cannot be empty" if values.empty?
      values.freeze
    end

    def numeric_allowed?(constraint, value)
      constraint == nil || constraint.include?(value)
    end

    def choose_numeric(constraint, current)
      return current if constraint == nil || constraint.include?(current)
      if constraint.is_a?(Range)
        [[current, constraint.begin].max, constraint.end].min
      else
        constraint.first
      end
    end
  end

  class Envelope
    INTERPOLATIONS = [:linear, :step].freeze

    attr_reader :points, :interpolation

    def self.linear(points)
      new(points, :interpolation => :linear)
    end

    def self.step(points)
      new(points, :interpolation => :step)
    end

    def initialize(points, interpolation: :linear)
      @interpolation = interpolation.to_sym
      raise ArgumentError, "Unsupported envelope interpolation #{@interpolation.inspect}" if !INTERPOLATIONS.include?(@interpolation)
      normalized = Array(points).map do |point|
        pair = Array(point)
        raise ArgumentError, "Envelope points must contain time and value" if pair.size != 2
        time = Float(pair[0])
        value = Float(pair[1])
        raise ArgumentError, "Envelope points must be finite" if !time.finite? || !value.finite?
        raise ArgumentError, "Envelope time cannot be negative" if time < 0.0
        [time, value].freeze
      end
      raise ArgumentError, "Envelope must contain at least one point" if normalized.empty?
      @points = normalized.sort_by(&:first).freeze
      freeze
    rescue TypeError
      raise ArgumentError, "Envelope points must be numeric"
    end

    def value_at(time)
      time = Float(time)
      return @points.first[1] if time <= @points.first[0]
      return @points.last[1] if time >= @points.last[0]
      right_index = @points.bsearch_index { |point| point[0] >= time }
      right = @points[right_index]
      left = @points[right_index - 1]
      return left[1] if @interpolation == :step || right[0] == left[0]
      progress = (time - left[0]) / (right[0] - left[0])
      left[1] + (right[1] - left[1]) * progress
    end
  end

  module PCM
    module_function

    def decode(data, format)
      data = data.to_s.b
      format.frames_for_bytes(data.bytesize)
      case format.sample_type
      when :float32le
        data.unpack("e*")
      when :s16le
        data.unpack("s<*").map { |sample| sample.to_f / 32768.0 }
      when :u8
        data.unpack("C*").map { |sample| (sample - 128).to_f / 128.0 }
      else
        raise FormatMismatch, "Unsupported PCM sample type #{format.sample_type.inspect}"
      end
    end

    def encode(samples, format)
      values = Array(samples)
      if values.size % format.channels != 0
        raise FormatMismatch, "PCM samples do not contain complete frames"
      end
      case format.sample_type
      when :float32le
        values.map { |sample| finite_sample(sample) }.pack("e*")
      when :s16le
        values.map do |sample|
          sample = finite_sample(sample).clamp(-1.0, 1.0)
          sample < 0.0 ? (sample * 32768.0).round : (sample * 32767.0).round
        end.pack("s<*")
      when :u8
        values.map do |sample|
          ((finite_sample(sample).clamp(-1.0, 1.0) * 127.5) + 127.5).round.clamp(0, 255)
        end.pack("C*")
      else
        raise FormatMismatch, "Unsupported PCM sample type #{format.sample_type.inspect}"
      end
    end

    def convert(data, from:, to:)
      raise FormatMismatch, "PCM conversion cannot change sample rate or channels" if from.sample_rate != to.sample_rate || from.channels != to.channels
      return data.to_s.b if from.sample_type == to.sample_type
      encode(decode(data, from), to)
    end

    def finite_sample(sample)
      value = Float(sample)
      value.finite? ? value : 0.0
    rescue ArgumentError, TypeError
      0.0
    end
  end
end
