# encoding: ASCII-8BIT
# frozen_string_literal: true

module Atlona; end
module Atlona::Omnistream; end

class Atlona::Omnistream::VirtualSwitcher
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    descriptive_name 'Atlona Omnistream Switcher'
    generic_name :Switcher
    implements :logic

    def on_load
        on_update
    end

    def on_update
        @encoder_name = setting(:encoder_name) || :Encoder
        @decoder_name = setting(:decoder_name) || :Decoder
    end

    def switch(map, switch_video: true, switch_audio: true)
        inputs = get_encoders
        outputs = get_decoders

        map.each do |inp, outs|
            begin
                inp = inp.to_s
                if inp == '0'
                    # mute the audio and video
                    if switch_video
                        video_ip = ""
                        video_port = 1200 # just needs to be a valid port number
                    end
                    if switch_audio
                        audio_ip = ""
                        audio_port = 1200
                    end
                else
                    input, session = inputs[inp]
                    if input.nil?
                        logger.warn "input not found switching #{inp} => #{outs}"
                        next
                    end

                    session = input[:sessions][session]

                    if switch_video
                        video = session[:video][:stream]
                        video_ip = video[:destination_address]
                        video_port = video[:destination_port]
                    end
                    unless video_ip.present? && video_port.present?
                        video_ip = nil
                        video_port = nil
                    end

                    if switch_audio
                        audio = session[:audio][:stream]
                        audio_ip = audio[:destination_address]
                        audio_port = audio[:destination_port]
                    end
                    unless audio_ip.present? && audio_port.present?
                        audio_ip = nil
                        audio_port = nil
                    end
                end

                Array(outs).each do |out|
                    output, index = outputs[out.to_s]

                    if output.nil?
                        logger.warn "output #{out} not found switching #{inp} => #{outs}"
                        next
                    end

                    output.switch(output: index, video_ip: video_ip, video_port: video_port, audio_ip: audio_ip, audio_port: audio_port)
                end
            rescue => e
                logger.print_error(e, "switching #{inp} => #{outs}")
            end
        end
    end

    def switch_video(map)
        switch(map, switch_audio: false)
    end

    def switch_audio(map)
        switch(map, switch_video: false)
    end

    def mute_video(outputs)
        switch_video({'0' => outputs})
    end

    def unmute_video(outputs)
        # need to restore the stream...
    end

    def mute_audio(outputs, mute = true)
        outs = get_decoders
        outputs.each do |out|
            decoder, index = outs[out.to_s]
            next if decoder.nil?

            decoder.mute(mute, output: index)
        end
    end

    def unmute_audio(outputs)
        mute_audio(outputs, false)
    end

    def get_mappings
        inputs = get_encoders
        outputs = get_decoders
        {
            inputs: inputs,
            outputs: outputs
        }
    end

    protected

    # Enumerate the devices that make up this virtual switcher
    def get_encoders
        index = 1
        input = 1
        encoder_mapping = {}
        info_mapping = {}

        system.all(@encoder_name).each do |mod|
            if mod[:type] == :encoder
                (1..mod[:num_sessions]).each do |num|
                    encoder_mapping[input.to_s] = [mod, num - 1]
                    info_mapping[input.to_s] = {
                        encoder: "#{@encoder_name}_#{index}",
                        session: num
                    }

                    input += 1
                end
            else
                logger.warn "#{@encoder_name}_#{index} is not an encoder"
            end

            index += 1
        end

        self[:input_mappings] = info_mapping
        encoder_mapping
    end

    def get_decoders
        index = 1
        output = 1
        decoder_mapping = {}
        info_mapping = {}

        system.all(@decoder_name).each do |mod|
            if mod[:type] == :decoder
                (1..mod[:num_outputs]).each do |num|
                    decoder_mapping[output.to_s] = [mod, num]
                    info_mapping[output.to_s] = {
                        encoder: "#{@decoder_name}_#{index}",
                        output: num
                    }

                    output += 1
                end
            else
                logger.warn "#{@decoder_name}_#{index} is not an decoder"
            end

            index += 1
        end

        self[:output_mappings] = info_mapping
        decoder_mapping
    end
end
