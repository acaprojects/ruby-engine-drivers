# encoding: ASCII-8BIT
# frozen_string_literal: true

module Atlona; end
module Atlona::OmniStream; end

class Atlona::OmniStream::VirtualSwitcher
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    descriptive_name 'Atlona Omnistream Switcher'
    generic_name :Switcher
    implements :logic

    def on_load
        on_update
    end

    def on_update
        @routes ||= {}
        @encoder_name = setting(:encoder_name) || :Encoder
        @decoder_name = setting(:decoder_name) || :Decoder

        # Support auto-switching we remember the last switch for any grouping
        # of outputs and then auto-switch based on changes to the outputs
        # {"outputs_2_2": { switch: map, monitor: [inp1, inp2], switch_video: true, ... }}
        @auto_switch = {}
        monitor_encoders
    end

    # For introspection from backoffice
    def auto_switch
        @auto_switch
    end

    def switch(map, switch_video: true, switch_audio: true, enable_override: nil, priority_auto_switch: true, **ignore)
        inputs = get_encoders
        outputs = get_decoders

        map.each do |inp, outs|
            begin
                # Select the first input where there is a video signal
                if inp.is_a?(Array)
                    selected = nil
                    monitor = []
                    inp.each_with_index do |check_inp|
                        # Get input details
                        check_inp = check_inp.to_s
                        input, session_index = inputs[check_inp]
                        next if input.nil?

                        # Grab the latest session details
                        sessions = input[:sessions]
                        next unless sessions
                        encoder_name = sessions.dig(session_index, :video, :encoder)
                        next unless encoder_name
                        video_input = (Array(input[:encoders]).select { |encoder| encoder[:name] == encoder_name }).dig(0, :input)
                        next unless video_input

                        video_ins = Array(input[:inputs]).select { |vin| vin[:name] == video_input }
                        next unless video_ins.length > 0

                        monitor.push({
                          input_no: check_inp, # virtual input number
                          # Encoder_index
                          device: self[:input_mappings][check_inp][:encoder],
                          # Video input name
                          video_input: video_input
                        }) if priority_auto_switch

                        # Check if a device is detected
                        if video_ins[0][:cabledetect]
                          selected = check_inp
                          break
                        end
                    end

                    if selected
                      logger.debug { "found active input on #{selected}" }
                    else
                      selected = inp.last
                      logger.debug { "no active input found, switching to #{selected}" }
                    end

                    if priority_auto_switch
                      auto_switch_key = outs.map(&:to_s).join("_")
                      @auto_switch[auto_switch_key] = {
                        switch: map,
                        switch_video: switch_video,
                        switch_audio: switch_audio,
                        enable_override: enable_override,
                        # We only need to switch if a change occurs to one of these inputs
                        monitor: monitor
                      }
                    end

                    inp = selected
                end

                inp = inp.to_s
                if inp == '0'
                    enable = enable_override.nil? ? false : enable_override

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
                    # disable video if there is no audio or video input
                    enable = enable_override.nil? ? true : enable_override

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
                    @routes[out] = inp
                    output, index = outputs[out.to_s]

                    if output.nil?
                        logger.warn "output #{out} not found switching #{inp} => #{outs}"
                        next
                    end

                    logger.debug { "switching #{inp} => #{out}" }
                    output.switch(output: index, video_ip: video_ip, video_port: video_port, audio_ip: audio_ip, audio_port: audio_port, enable: enable)
                end
            rescue => e
                logger.print_error(e, "switching #{inp} => #{outs}")
            end
        end

        self[:routes] = @routes.dup
        true
    end

    def switch_video(map)
        switch(map, switch_audio: false)
    end

    def switch_audio(map)
        switch(map, switch_video: false)
    end

    def mute_video(outputs, state = false)
        state = is_affirmative?(state)
        switch_video({'0' => outputs}, enable_override: state)
    end

    def unmute_video(outputs)
        mute_video(outputs, true)
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

    def monitor_encoders
      logger.debug { "monitoring encoder inputs" }

      @subscriptions ||= []
      @subscriptions.each { |ref| unsubscribe(ref) }
      @subscriptions.clear

      @cached_state = {}

      encoder_name = @encoder_name
      (0...system.count(encoder_name)).each do |index|
        index += 1
        encoder_id = "#{encoder_name}_#{index}"
        @subscriptions << system.subscribe(encoder_name, index, :inputs) do |notify|
          check_auto_switch(encoder_id, notify.value)
        end
      end
    end

    def check_auto_switch(encoder_id, inputs)
      return if inputs.nil?

      logger.debug { "checking for autoswitch changes on #{encoder_id}" }

      # Extract the cable detect state
      state = {}
      Array(inputs).each do |input|
        state[input[:name]] = input[:cabledetect]
      end

      # Check for changes
      changed = []
      state.each do |name, detected|
        if @cached_state[name] != detected
          @cached_state[name] = detected
          changed << name
        end
      end

      return unless changed

      logger.debug { "detected autoswitch changes on #{encoder_id}" }

      # See if there are any routes we should be auto-switching
      do_switch = []
      @auto_switch.each do |outputs, details|
        monitoring = details[:monitor]
        monitoring.each do |input|
          check_encoder_id = input[:device]
          next unless encoder_id == check_encoder_id
          video_input_name = input[:video_input]
          next unless changed.include?(video_input_name)

          do_switch << details
          break
        end
      end

      logger.debug { "found #{do_switch.length} autoswitch actions" }

      # Perform the auto-switching
      do_switch.each do |details|
        switch(details[:switch], **details)
      end
    end

    # Enumerate the devices that make up this virtual switcher
    def get_encoders
        index = 1
        input = 1
        encoder_mapping = {}
        info_mapping = {}

        system.all(@encoder_name).each do |mod|
            # skip any offline devices
            if mod.nil?
                index += 1
                next
            end

            num_sessions = mod[:num_sessions]
            if mod[:type] == :encoder && num_sessions
                (1..num_sessions).each do |num|
                    mapping_details = [mod, num - 1]
                    name = begin
                      mod[:sessions][num - 1][:name]
                    rescue
                      nil
                    end
                    encoder_mapping[name] = mapping_details if name
                    encoder_mapping[input.to_s] = mapping_details

                    mapping_details = {
                        encoder: "#{@encoder_name}_#{index}",
                        session: num
                    }
                    info_mapping[input.to_s] = mapping_details
                    info_mapping[name] = mapping_details if name

                    input += 1
                end
            else
                logger.warn "#{@encoder_name}_#{index} is not an encoder or offline"
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
            # skip any offline devices
            if mod.nil?
                index += 1
                next
            end

            num_outputs = mod[:num_outputs]
            if mod[:type] == :decoder && num_outputs
                (1..num_outputs).each do |num|
                    mapping_details = [mod, num]
                    name = begin
                      mod[:outputs][num - 1][:name]
                    rescue
                      nil
                    end

                    decoder_mapping[name] = mapping_details if name
                    decoder_mapping[output.to_s] = mapping_details

                    mapping_details = {
                        decoder: "#{@decoder_name}_#{index}",
                        output: num
                    }
                    info_mapping[output.to_s] = mapping_details
                    info_mapping[name] = mapping_details if name

                    output += 1
                end
            else
                logger.warn "#{@decoder_name}_#{index} is not an decoder or offline"
            end

            index += 1
        end

        self[:output_mappings] = info_mapping
        decoder_mapping
    end
end
