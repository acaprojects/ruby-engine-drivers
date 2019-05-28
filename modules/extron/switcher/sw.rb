# frozen_string_literal: true

load File.expand_path('../base.rb', File.dirname(__FILE__))

module Extron::Switcher; end

class Extron::Switcher::Sw < Extron::Base
    descriptive_name 'Extron Switcher SW'
    generic_name :Switcher

    def switch_to(input)
        do_send "#{input}!"
    end

    def mute_video(state = true)
        val = is_affirmative?(state) ? 1 : 0
        do_send "#{val}B"
    end

    def unmute_video
        mute_video false
    end

    def mute_audio(state = true)
        val = is_affirmative?(state) ? 1 : 0
        do_send "#{val}Z"
    end

    def unmute_audio
        mute_audio false
    end

    def query_sync
        do_send "\eLS"
    end

    def connected
        super
        query_sync
    end

    def received(data, resolve, command)
        logger.debug { "Extron switcher sent #{data}" }

        if data =~ /Login/i
            device_ready
        else
            response, _, param = data.partition(/(?=\d)/)

            case response.strip.to_sym
            when :In
                self[:input] = param.to_i
            when :Vmt
                self[:video_muted] = param > '0'
            when :Amt
                self[:audio_muted] = param > '0'
            when :Sig
                inputs, outputs = param.split('*')
                inputs.split.each_with_index do |state, idx|
                    self[:"input_#{idx + 1}_sync"] = state == '1'
                end
                outputs.split.each_with_index do |state, idx|
                    self[:"output_#{idx + 1}_sync"] = state == '1'
                end
            when :E
                code = param.to_i
                logger.warn(ERROR[code] || "Unknown device error (#{code})")
                return :failed
            else
                # Unhandled device response - safe to ignore
            end
        end

        :success
    end


    ERROR = {
        1 => 'Invalid input channel (out of range)',
        6 => 'Invalid input during auto-input switching',
        10 => 'Invalid command',
        13 => 'Invalid value (out of range)'
    }.freeze
end
