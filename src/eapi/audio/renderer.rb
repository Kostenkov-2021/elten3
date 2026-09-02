# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3.

module Audio
  class Renderer
    class << self
      def export(source, path, encoder:, metadata: nil, validate_extension: true)
        source = normalize_source(source)
        metadata = source.metadata if metadata == nil
        encoder = normalize_encoder(encoder)
        validate_audio_encoder!(encoder)
        validate_output_path!(path, encoder) if validate_extension
        temporary_path = temporary_output_path(path)
        output = FileRecorderOutput.new(temporary_path)
        render(source, output, encoder, metadata)
        output.close
        output = nil
        File.rename(temporary_path, path.to_s)
        temporary_path = nil
        path
      rescue EncodingError
        raise
      rescue Exception => error
        raise EncodingError, "Cannot export audio with #{encoder_name(encoder)}: #{error.class}: #{error.message}"
      ensure
        begin
          output.close if output != nil
        rescue Exception
        end
        begin
          File.delete(temporary_path) if temporary_path != nil && File.file?(temporary_path)
        rescue Exception
        end
      end

      def encode(source, encoder:, metadata: nil)
        source = normalize_source(source)
        metadata = source.metadata if metadata == nil
        encoder = normalize_encoder(encoder)
        validate_audio_encoder!(encoder)
        output = MemoryRecorderOutput.new
        render(source, output, encoder, metadata)
        output.data
      rescue EncodingError
        raise
      rescue Exception => error
        raise EncodingError, "Cannot encode audio with #{encoder_name(encoder)}: #{error.class}: #{error.message}"
      ensure
        output.close if output != nil
      end

      def render(source, output, encoder, metadata = nil)
        validate_audio_encoder!(encoder)
        constraints = encoder.input_constraints
        input_format = constraints.negotiate(source.format)
        prepared = source.convert(:format => input_format)
        session = encoder.start(
          :output => output,
          :input_format => input_format,
          :metadata => normalize_metadata(metadata)
        )
        raise MediaEncoder::UnsupportedOperation, "#{encoder.class} did not create an audio encoding session" if session == nil
        prepared.each_buffer do |buffer|
          if buffer.format != input_format
            raise FormatMismatch, "Audio renderer received #{buffer.format.inspect}, expected #{input_format.inspect}"
          end
          session.process_pcm(buffer.data)
        end
        session.finish
        session = nil
        output
      rescue EncodingError
        raise
      rescue Exception => error
        raise EncodingError, "Audio rendering failed with #{encoder_name(encoder)}: #{error.class}: #{error.message}"
      ensure
        begin
          session.close if session != nil && session.respond_to?(:close)
        rescue Exception
        end
      end

      def to_sound(source, loop: false, effect_buffer: nil, effect_buffer_seconds: nil)
        source = normalize_source(source)
        data = encode(source, :encoder => WaveEncoder.new, :metadata => source.metadata)
        Sound.new(
          nil,
          :loop => loop,
          :stream => data,
          :effect_buffer => effect_buffer,
          :effect_buffer_seconds => effect_buffer_seconds
        )
      end

      private

      def normalize_source(source)
        return source if source.is_a?(Source)
        Audio.open(source)
      end

      def normalize_encoder(encoder)
        if encoder.is_a?(Class) && encoder <= MediaEncoder
          encoder = encoder.new
        end
        raise ArgumentError, "Audio encoder must be a MediaEncoder instance" if !encoder.is_a?(MediaEncoder)
        encoder
      end

      def normalize_metadata(metadata)
        return {} if metadata == nil
        Hash(metadata).each_with_object({}) { |(key, value), result| result[key.to_s] = value.to_s }
      end

      def validate_output_path!(path, encoder)
        descriptor = encoder.output_descriptor
        return if descriptor == nil
        extensions = Array(descriptor[:extensions]).map { |extension| extension.to_s.downcase }
        return if extensions.empty?
        actual = File.extname(path.to_s).downcase
        return if extensions.include?(actual)
        raise EncodingError, "#{encoder.class} expects one of #{extensions.join(', ')}, got #{actual == '' ? '(no extension)' : actual}"
      end

      def validate_audio_encoder!(encoder)
        constraints = encoder.input_constraints
        descriptor = encoder.output_descriptor
        if constraints == nil || descriptor == nil || !encoder.class.audio_supported?
          raise MediaEncoder::UnsupportedOperation, "#{encoder.class} does not support the Audio rendering API"
        end
        true
      end

      def temporary_output_path(path)
        path = path.to_s
        directory = File.dirname(path)
        basename = File.basename(path)
        token = "#{$$}-#{Thread.current.object_id}-#{rand(36**8).to_s(36)}"
        File.join(directory, ".#{basename}.elten-audio-#{token}.tmp")
      end

      def encoder_name(encoder)
        encoder == nil ? "unknown encoder" : encoder.class.to_s
      end
    end
  end
end

class Sound
  def self.from_audio(source, **options)
    Audio::Renderer.to_sound(source, **options)
  end
end
