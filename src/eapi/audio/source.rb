# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3.

module Audio
  DEFAULT_CHUNK_FRAMES = 4096

  class Source
    def format
      raise NotImplementedError
    end

    def duration
      nil
    end

    def frame_count
      value = duration
      value == nil ? nil : format.frames_for_seconds(value)
    end

    def metadata
      {}.freeze
    end

    def seekable?
      false
    end

    def each_buffer(start_frame: 0, frame_count: nil, chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :start_frame => start_frame, :frame_count => frame_count, :chunk_frames => chunk_frames) if !block_given?
      start_frame = Integer(start_frame)
      frame_count = Integer(frame_count) if frame_count != nil
      chunk_frames = Integer(chunk_frames)
      raise ArgumentError, "Audio start frame cannot be negative" if start_frame < 0
      raise ArgumentError, "Audio frame count cannot be negative" if frame_count != nil && frame_count < 0
      raise ArgumentError, "Audio chunk size must be positive" if chunk_frames <= 0
      return self if frame_count == 0

      skipped = start_frame
      remaining = frame_count
      each_full_buffer(:chunk_frames => chunk_frames) do |buffer|
        raise FormatMismatch, "Audio source yielded a buffer with a different format" if buffer.format != format
        available = buffer.frame_count
        if skipped >= available
          skipped -= available
          next
        end
        offset = skipped
        skipped = 0
        take = available - offset
        take = [take, remaining].min if remaining != nil
        yield buffer.slice_frames(offset, take) if take > 0
        remaining -= take if remaining != nil
        break if remaining == 0
      end
      self
    end

    def each_pcm(**options)
      return enum_for(__method__, **options) if !block_given?
      each_buffer(**options) { |buffer| yield buffer.data }
      self
    end

    def segment(from:, to:)
      SegmentSource.new(self, :from => from, :to => to)
    end

    def concat(*sources, format: nil)
      Audio.concat(self, *sources, :format => format)
    end

    def resample(to:, quality: :high)
      sample_rate = Integer(to)
      return self if sample_rate == format.sample_rate
      ResampleSource.new(self, :sample_rate => sample_rate, :quality => quality)
    end

    def downmix(to: :mono, matrix: nil, clipping: :clip)
      channels = case to
      when :mono then 1
      when :stereo then 2
      else Integer(to)
      end
      return self if channels == format.channels && matrix == nil
      ChannelMixSource.new(self, :channels => channels, :matrix => matrix, :clipping => clipping)
    end

    def convert(format:)
      raise ArgumentError, "Expected Audio::Format" if !format.is_a?(Format)
      source = self
      processing_format = source.format
      if (processing_format.sample_rate != format.sample_rate || processing_format.channels != format.channels) && processing_format.sample_type != :float32le
        source = SampleFormatSource.new(source, :sample_type => :float32le)
      end
      source = source.resample(:to => format.sample_rate) if source.format.sample_rate != format.sample_rate
      source = source.downmix(:to => format.channels) if source.format.channels != format.channels
      source = SampleFormatSource.new(source, :sample_type => format.sample_type) if source.format.sample_type != format.sample_type
      source
    end

    def with_attribute(attribute_class, value = nil, envelope: nil)
      if !defined?(::SoundAttribute) || !attribute_class.is_a?(Class) || !(attribute_class <= SoundAttribute)
        raise ArgumentError, "Audio attribute must be a SoundAttribute class"
      end
      attribute_class.build_audio_source(self, :value => value, :envelope => envelope)
    end

    def with_effects(*effects)
      effects.flatten.reduce(self) { |source, effect| EffectSource.new(source, effect) }
    end

    def to_buffer
      data = "".b
      each_buffer { |buffer| data << buffer.data }
      Buffer.new(:data => data, :format => format, :metadata => metadata)
    end

    def encode(encoder:, metadata: self.metadata)
      Renderer.encode(self, :encoder => encoder, :metadata => metadata)
    end

    def export(path, encoder:, metadata: self.metadata, validate_extension: true)
      Renderer.export(self, path, :encoder => encoder, :metadata => metadata, :validate_extension => validate_extension)
    end

    def to_sound(**options)
      Renderer.to_sound(self, **options)
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      raise NotImplementedError
    end
  end

  class Buffer < Source
    attr_reader :data, :format

    def initialize(data:, format:, metadata: nil)
      raise ArgumentError, "Expected Audio::Format" if !format.is_a?(Format)
      raise TypeError, "PCM data must be a string" if !data.respond_to?(:to_str)
      @format = format
      @data = data.to_str.b.dup.freeze
      @format.frames_for_bytes(@data.bytesize)
      @metadata = normalize_metadata(metadata)
      freeze
    end

    def frame_count
      @data.bytesize / @format.bytes_per_frame
    end

    def duration
      @format.seconds_for_frames(frame_count)
    end

    def metadata
      @metadata
    end

    def seekable?
      true
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :chunk_frames => chunk_frames) if !block_given?
      chunk_frames = Integer(chunk_frames)
      raise ArgumentError, "Audio chunk size must be positive" if chunk_frames <= 0
      offset = 0
      chunk_bytes = @format.bytes_for_frames(chunk_frames)
      while offset < @data.bytesize
        bytes = [chunk_bytes, @data.bytesize - offset].min
        yield Buffer.new(:data => @data.byteslice(offset, bytes), :format => @format, :metadata => @metadata)
        offset += bytes
      end
      self
    end

    def each_buffer(start_frame: 0, frame_count: nil, chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :start_frame => start_frame, :frame_count => frame_count, :chunk_frames => chunk_frames) if !block_given?
      start_frame = Integer(start_frame)
      frame_count = self.frame_count - start_frame if frame_count == nil
      frame_count = Integer(frame_count)
      chunk_frames = Integer(chunk_frames)
      raise ArgumentError, "Audio start frame cannot be negative" if start_frame < 0
      raise ArgumentError, "Audio frame count cannot be negative" if frame_count < 0
      raise ArgumentError, "Audio chunk size must be positive" if chunk_frames <= 0
      available = [[self.frame_count - start_frame, 0].max, frame_count].min
      offset = start_frame
      while available > 0
        take = [available, chunk_frames].min
        yield slice_frames(offset, take)
        offset += take
        available -= take
      end
      self
    end

    def slice_frames(start_frame, frame_count)
      start_frame = Integer(start_frame)
      frame_count = Integer(frame_count)
      raise ArgumentError, "Audio frame range cannot be negative" if start_frame < 0 || frame_count < 0
      start_frame = [start_frame, self.frame_count].min
      frame_count = [frame_count, self.frame_count - start_frame].min
      offset = @format.bytes_for_frames(start_frame)
      bytes = @format.bytes_for_frames(frame_count)
      Buffer.new(:data => @data.byteslice(offset, bytes).to_s.b, :format => @format, :metadata => @metadata)
    end

    private

    def normalize_metadata(metadata)
      return {}.freeze if metadata == nil
      Hash(metadata).each_with_object({}) do |(key, value), result|
        result[key.to_s.freeze] = value.to_s.freeze
      end.freeze
    end
  end

  class SilenceSource < Source
    attr_reader :format, :duration

    def initialize(duration:, format:)
      raise ArgumentError, "Expected Audio::Format" if !format.is_a?(Format)
      @duration = Float(duration)
      raise ArgumentError, "Silence duration must be a non-negative finite number" if !@duration.finite? || @duration < 0.0
      @format = format
      @frame_count = @format.frames_for_seconds(@duration)
      @duration = @format.seconds_for_frames(@frame_count)
    end

    def frame_count
      @frame_count
    end

    def seekable?
      true
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :chunk_frames => chunk_frames) if !block_given?
      remaining = frame_count
      while remaining > 0
        frames = [remaining, Integer(chunk_frames)].min
        samples = Array.new(frames * @format.channels, 0.0)
        yield Buffer.new(:data => PCM.encode(samples, @format), :format => @format)
        remaining -= frames
      end
      self
    end
  end

  class BassReader
    BASS_STREAM_PRESCAN = 0x20000

    attr_reader :format, :duration, :metadata

    def initialize(file: nil, data: nil)
      raise ArgumentError, "Audio reader requires a file or encoded data" if file == nil && data == nil
      @file = file
      @data = data == nil ? nil : data.to_s.b
      @url = @file != nil && @file.to_s.downcase.start_with?("http://", "https://")
      flags = Bass::BASS_STREAM_DECODE | Bass::BASS_SAMPLE_FLOAT | BASS_STREAM_PRESCAN
      @channel = if @data != nil
        Bass.create_file_stream_from_memory(@data, flags)
      elsif @url
        Bass.create_url_stream(@file, 0, flags, 0, 0)
      else
        Bass.create_file_stream_from_path(@file, 0, flags)
      end
      raise DecodeError, "Cannot open audio source: #{Bass.error_name}" if @channel.to_i == 0
      frequency = EltenRecorderRuntime.source_frequency(@channel)
      channels = EltenRecorderRuntime.source_channels(@channel)
      @format = Format.new(:sample_rate => frequency, :channels => channels, :sample_type => :float32le)
      @duration = read_duration
      @metadata = Hash(EltenRecorderRuntime.source_tags(@channel)).each_with_object({}) do |(key, value), result|
        result[key.to_s.freeze] = value.to_s.freeze
      end.freeze
      @closed = false
    rescue Exception
      close
      raise
    end

    def each_buffer(start_frame: 0, frame_count: nil, chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :start_frame => start_frame, :frame_count => frame_count, :chunk_frames => chunk_frames) if !block_given?
      ensure_open
      start_frame = Integer(start_frame)
      frame_count = Integer(frame_count) if frame_count != nil
      chunk_frames = Integer(chunk_frames)
      raise ArgumentError, "Audio start frame cannot be negative" if start_frame < 0
      raise ArgumentError, "Audio frame count cannot be negative" if frame_count != nil && frame_count < 0
      raise ArgumentError, "Audio chunk size must be positive" if chunk_frames <= 0
      seek_or_discard(start_frame)
      remaining = frame_count
      buffer = "\0".b * @format.bytes_for_frames(chunk_frames)
      loop do
        break if remaining == 0
        requested_frames = remaining == nil ? chunk_frames : [remaining, chunk_frames].min
        requested_bytes = @format.bytes_for_frames(requested_frames)
        read = Bass::BASS_ChannelGetData.call(@channel, buffer, requested_bytes).to_i
        break if read <= 0
        read -= read % @format.bytes_per_frame
        break if read <= 0
        result = Buffer.new(:data => buffer.byteslice(0, read), :format => @format, :metadata => @metadata)
        yield result
        remaining -= result.frame_count if remaining != nil
      end
      self
    end

    def close
      Bass.free_stream(@channel) if defined?(Bass) && @channel.to_i != 0
      @channel = 0
      @closed = true
      nil
    rescue Exception
      @channel = 0
      @closed = true
      nil
    end

    private

    def ensure_open
      raise DecodeError, "Audio reader is closed" if @closed || @channel.to_i == 0
    end

    def read_duration
      bytes = Bass::BASS_ChannelGetLength.call(@channel, 0).to_i
      return nil if bytes <= 0 || bytes == 0xffffffffffffffff
      seconds = Bass::BASS_ChannelBytes2Seconds.call(@channel, bytes).to_f
      seconds.finite? && seconds >= 0.0 ? seconds : nil
    rescue Exception
      nil
    end

    def seek_or_discard(start_frame)
      return if start_frame <= 0
      seconds = @format.seconds_for_frames(start_frame)
      position = Bass::BASS_ChannelSeconds2Bytes.call(@channel, seconds).to_i
      return if position >= 0 && Bass::BASS_ChannelSetPosition.call(@channel, position, 0).to_i != 0
      discard_frames(start_frame)
    end

    def discard_frames(frames)
      buffer = "\0".b * @format.bytes_for_frames([frames, DEFAULT_CHUNK_FRAMES].min)
      remaining = frames
      while remaining > 0
        take = [remaining, DEFAULT_CHUNK_FRAMES].min
        read = Bass::BASS_ChannelGetData.call(@channel, buffer, @format.bytes_for_frames(take)).to_i
        break if read <= 0
        remaining -= read / @format.bytes_per_frame
      end
    end
  end

  class DecodedSource < Source
    def initialize(file: nil, data: nil)
      @file = file == nil ? nil : file.to_s.dup.freeze
      @data = data == nil ? nil : data.to_s.b.freeze
      @info_mutex = Mutex.new
      @info_loaded = false
    end

    def format
      load_info
      @format
    end

    def duration
      load_info
      @duration
    end

    def metadata
      load_info
      @metadata
    end

    def seekable?
      @data != nil || (@file != nil && !@file.to_s.downcase.start_with?("http://", "https://"))
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES, &block)
      each_buffer(:chunk_frames => chunk_frames, &block)
    end

    def each_buffer(start_frame: 0, frame_count: nil, chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :start_frame => start_frame, :frame_count => frame_count, :chunk_frames => chunk_frames) if !block_given?
      reader = build_reader
      reader.each_buffer(:start_frame => start_frame, :frame_count => frame_count, :chunk_frames => chunk_frames) { |buffer| yield buffer }
      self
    ensure
      reader.close if reader != nil
    end

    private

    def build_reader
      BassReader.new(:file => @file, :data => @data)
    end

    def load_info
      return if @info_loaded
      @info_mutex.synchronize do
        return if @info_loaded
        reader = build_reader
        @format = reader.format
        @duration = reader.duration
        @metadata = reader.metadata
        @info_loaded = true
      ensure
        reader.close if reader != nil
      end
    end
  end

  class SegmentSource < Source
    attr_reader :source, :from, :to, :format, :duration

    def initialize(source, from:, to:)
      raise ArgumentError, "Expected Audio::Source" if !source.is_a?(Source)
      @source = source
      @from = Float(from)
      requested_to = Float(to)
      if !@from.finite? || !requested_to.finite? || @from < 0.0 || requested_to < @from
        raise ArgumentError, "Invalid audio segment range"
      end
      source_duration = source.duration
      if source_duration != nil
        raise ArgumentError, "Audio segment starts after the end of the source" if @from > source_duration
        requested_to = [requested_to, source_duration].min
      end
      @to = requested_to
      @format = source.format
      @first_frame = @format.frames_for_seconds(@from)
      last_frame = @format.frames_for_seconds(@to)
      @frame_count = [last_frame - @first_frame, 0].max
      @duration = @format.seconds_for_frames(@frame_count)
    rescue TypeError
      raise ArgumentError, "Audio segment boundaries must be numeric"
    end

    def metadata
      @source.metadata
    end

    def frame_count
      @frame_count
    end

    def seekable?
      @source.seekable?
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :chunk_frames => chunk_frames) if !block_given?
      @source.each_buffer(:start_frame => @first_frame, :frame_count => @frame_count, :chunk_frames => chunk_frames) { |buffer| yield buffer }
      self
    end
  end

  class ConcatSource < Source
    attr_reader :sources, :format

    def initialize(sources, format: nil)
      values = Array(sources)
      raise ArgumentError, "Audio concatenation requires at least one source" if values.empty?
      raise ArgumentError, "Audio concatenation accepts only Audio::Source objects" if values.any? { |source| !source.is_a?(Source) }
      if format != nil
        raise ArgumentError, "Expected Audio::Format" if !format.is_a?(Format)
        values = values.map { |source| source.convert(:format => format) }
      else
        format = values.first.format
        mismatch = values.find { |source| source.format != format }
        raise FormatMismatch, "Concatenated audio sources must have the same format or an explicit target format" if mismatch != nil
      end
      @sources = values.freeze
      @format = format
    end

    def duration
      values = @sources.map(&:duration)
      values.any?(&:nil?) ? nil : values.sum
    end

    def metadata
      @sources.first.metadata
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :chunk_frames => chunk_frames) if !block_given?
      @sources.each do |source|
        source.each_buffer(:chunk_frames => chunk_frames) { |buffer| yield buffer }
      end
      self
    end
  end

  class SampleFormatSource < Source
    attr_reader :source, :format

    def initialize(source, sample_type:)
      @source = source
      @format = source.format.with(:sample_type => sample_type)
    end

    def duration
      @source.duration
    end

    def metadata
      @source.metadata
    end

    def seekable?
      @source.seekable?
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :chunk_frames => chunk_frames) if !block_given?
      @source.each_buffer(:chunk_frames => chunk_frames) do |buffer|
        data = PCM.convert(buffer.data, :from => buffer.format, :to => @format)
        yield Buffer.new(:data => data, :format => @format, :metadata => buffer.metadata)
      end
      self
    end
  end

  class ChannelMixSource < Source
    attr_reader :source, :format, :matrix

    def initialize(source, channels:, matrix: nil, clipping: :clip)
      channels = Integer(channels)
      raise ArgumentError, "Audio channel count must be between 1 and 32" if channels < 1 || channels > 32
      @source = source.format.sample_type == :float32le ? source : SampleFormatSource.new(source, :sample_type => :float32le)
      @format = @source.format.with(:channels => channels, :sample_type => :float32le)
      @matrix = normalize_matrix(matrix || default_matrix(@source.format.channels, channels))
      @clipping = clipping.to_sym
      raise ArgumentError, "Audio clipping must be :clip or :none" if ![:clip, :none].include?(@clipping)
    end

    def duration
      @source.duration
    end

    def metadata
      @source.metadata
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :chunk_frames => chunk_frames) if !block_given?
      input_channels = @source.format.channels
      output_channels = @format.channels
      @source.each_buffer(:chunk_frames => chunk_frames) do |buffer|
        input = PCM.decode(buffer.data, buffer.format)
        output = Array.new(buffer.frame_count * output_channels, 0.0)
        for frame in 0...buffer.frame_count
          for output_channel in 0...output_channels
            sample = 0.0
            for input_channel in 0...input_channels
              sample += input[frame * input_channels + input_channel] * @matrix[output_channel][input_channel]
            end
            sample = sample.clamp(-1.0, 1.0) if @clipping == :clip
            output[frame * output_channels + output_channel] = sample
          end
        end
        yield Buffer.new(:data => PCM.encode(output, @format), :format => @format, :metadata => buffer.metadata)
      end
      self
    end

    private

    def default_matrix(input_channels, output_channels)
      if output_channels == 1
        [Array.new(input_channels, 1.0 / input_channels)]
      elsif input_channels == 1
        Array.new(output_channels) { [1.0] }
      else
        Array.new(output_channels) do |output_channel|
          Array.new(input_channels) { |input_channel| output_channel == input_channel ? 1.0 : 0.0 }
        end
      end
    end

    def normalize_matrix(matrix)
      rows = Array(matrix).map { |row| Array(row).map { |value| Float(value) } }
      if rows.size != @format.channels || rows.any? { |row| row.size != @source.format.channels }
        raise ArgumentError, "Audio channel matrix has invalid dimensions"
      end
      raise ArgumentError, "Audio channel matrix must contain finite values" if rows.flatten.any? { |value| !value.finite? }
      rows.map(&:freeze).freeze
    rescue TypeError
      raise ArgumentError, "Audio channel matrix must contain numeric values"
    end
  end

  class ResampleSource < Source
    QUALITIES = [:nearest, :linear, :high].freeze

    attr_reader :source, :format, :quality

    def initialize(source, sample_rate:, quality: :high, input_step: nil)
      sample_rate = Integer(sample_rate)
      raise ArgumentError, "Audio sample rate must be positive" if sample_rate <= 0
      @quality = quality.to_sym
      raise ArgumentError, "Unsupported resampling quality #{@quality.inspect}" if !QUALITIES.include?(@quality)
      @source = source.format.sample_type == :float32le ? source : SampleFormatSource.new(source, :sample_type => :float32le)
      @format = @source.format.with(:sample_rate => sample_rate, :sample_type => :float32le)
      @input_step = input_step == nil ? @source.format.sample_rate.to_f / sample_rate : Float(input_step)
      raise ArgumentError, "Audio resampling ratio must be a positive finite number" if !@input_step.finite? || @input_step <= 0.0
    end

    def duration
      value = @source.duration
      value == nil ? nil : value / @input_step * (@source.format.sample_rate.to_f / @format.sample_rate)
    end

    def metadata
      @source.metadata
    end

    def each_full_buffer(chunk_frames: DEFAULT_CHUNK_FRAMES)
      return enum_for(__method__, :chunk_frames => chunk_frames) if !block_given?
      chunk_frames = Integer(chunk_frames)
      channels = @format.channels
      samples = []
      buffer_start = 0
      total_input_frames = 0
      output_index = 0
      output_samples = []
      known_input_frames = @source.frame_count
      known_target_frames = known_input_frames == nil ? nil : (known_input_frames / @input_step).round
      return self if known_target_frames == 0

      emit = proc do |eof, target_frames|
        loop do
          break if target_frames != nil && output_index >= target_frames
          buffered_frames = samples.size / channels
          break if buffered_frames <= 0
          last_frame = buffer_start + buffered_frames - 1
          position = output_index * @input_step
          required = required_input_frame(position)
          break if !eof && required > last_frame
          break if eof && position > last_frame && output_index >= target_frames.to_i
          for channel in 0...channels
            output_samples << interpolate(samples, buffer_start, last_frame, position, channel, channels)
          end
          output_index += 1
          if output_samples.size >= chunk_frames * channels
            yield Buffer.new(:data => PCM.encode(output_samples, @format), :format => @format, :metadata => metadata)
            output_samples = []
          end
        end

        next_position = output_index * @input_step
        keep_from = next_position.floor
        keep_from -= 1 if @quality == :high
        drop = [keep_from - buffer_start, 0].max
        buffered_frames = samples.size / channels
        drop = [drop, buffered_frames - 1].min if buffered_frames > 0
        if drop > 0
          samples = samples.drop(drop * channels)
          buffer_start += drop
        end
      end

      @source.each_buffer(:chunk_frames => chunk_frames) do |buffer|
        decoded = PCM.decode(buffer.data, buffer.format)
        samples.concat(decoded)
        total_input_frames += buffer.frame_count
        emit.call(false, known_target_frames)
        break if known_target_frames != nil && output_index >= known_target_frames
      end
      target_frames = (total_input_frames / @input_step).round
      emit.call(true, target_frames)
      if !output_samples.empty?
        yield Buffer.new(:data => PCM.encode(output_samples, @format), :format => @format, :metadata => metadata)
      end
      self
    end

    private

    def required_input_frame(position)
      case @quality
      when :nearest then position.round
      when :linear then position.floor + 1
      else position.floor + 2
      end
    end

    def interpolate(samples, buffer_start, last_frame, position, channel, channels)
      case @quality
      when :nearest
        sample_at(samples, buffer_start, last_frame, position.round, channel, channels)
      when :linear
        left = position.floor
        fraction = position - left
        first = sample_at(samples, buffer_start, last_frame, left, channel, channels)
        second = sample_at(samples, buffer_start, last_frame, left + 1, channel, channels)
        first + (second - first) * fraction
      else
        center = position.floor
        fraction = position - center
        p0 = sample_at(samples, buffer_start, last_frame, center - 1, channel, channels)
        p1 = sample_at(samples, buffer_start, last_frame, center, channel, channels)
        p2 = sample_at(samples, buffer_start, last_frame, center + 1, channel, channels)
        p3 = sample_at(samples, buffer_start, last_frame, center + 2, channel, channels)
        0.5 * ((2.0 * p1) + (-p0 + p2) * fraction +
          (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * fraction * fraction +
          (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * fraction * fraction * fraction)
      end
    end

    def sample_at(samples, buffer_start, last_frame, frame, channel, channels)
      frame = frame.clamp(buffer_start, last_frame)
      samples[(frame - buffer_start) * channels + channel]
    end
  end

  class RateSource < ResampleSource
    attr_reader :rate

    def initialize(source, rate:, quality: :high)
      @rate = Float(rate)
      raise ArgumentError, "Audio playback frequency must be a positive finite number" if !@rate.finite? || @rate <= 0.0
      super(source, :sample_rate => source.format.sample_rate, :quality => quality, :input_step => @rate / source.format.sample_rate)
    end
  end

  class << self
    def open(input)
      return input if input.is_a?(Source)
      DecodedSource.new(:file => input)
    end

    def open_data(data)
      DecodedSource.new(:data => data)
    end

    def from_pcm(data, format: nil, sample_rate: nil, channels: nil, sample_type: :float32le, metadata: nil)
      format ||= Format.new(:sample_rate => sample_rate, :channels => channels, :sample_type => sample_type)
      Buffer.new(:data => data, :format => format, :metadata => metadata)
    end

    def load(input)
      open(input).to_buffer
    end

    def concat(*sources, format: nil)
      ConcatSource.new(sources.flatten, :format => format)
    end

    def silence(duration:, format:)
      SilenceSource.new(:duration => duration, :format => format)
    end
  end
end
