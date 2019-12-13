# encoding: ASCII-8BIT
# frozen_string_literal: true

module Atlona; end
module Atlona::OmniStream; end

class Atlona::OmniStream::AutoSwitcher
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    descriptive_name 'Atlona Omnistream Auto Switcher'
    generic_name :AutoSwitcher
    implements :logic

    def on_load
        # input id => true / false - presence detected
        @last_known_state = {}
        on_update
    end

    def on_update
        switcher = setting(:virtual_switcher) || :Switcher

        # { "output": ["input_1", "input_2"] }
        auto_switch = setting(:auto_switch) || {}
        self[:enabled] = @enabled = setting(:auto_switch_enabled) || true

        schedule.clear
        poll_every = setting(:auto_switch_poll_every) || '3s'
        schedule.every(poll_every) { poll_inputs }

        # Bind to all the encoders for presence detection
        if @virtual_switcher != switcher || @auto_switch != auto_switch
          if @auto_switch != auto_switch
              @auto_switch = auto_switch
              switch_all
          end

          @virtual_switcher = switcher
          subscribe_virtual_inputs
        end
    end

    def enabled(state)
        self[:enabled] = @enabled = !!state
        define_setting(:auto_switch_enabled, @enabled)
        switch_all
        nil
    end


    protected


    def poll_inputs
        input_mappings = system[@virtual_switcher][:input_mappings]
        encoders = []
        @auto_switch.each do |output, inputs|
            inputs.each do |input|
                input = input.to_s
                input_details = input_mappings[input]
                next unless input_details

                encoders << input_details[:encoder]
            end
        end

        encoders.uniq!
        encoders.each do |encoder|
          system[encoder].hdmi_input
        end

        nil
    end

    def switch_all
        return unless @enabled

        @auto_switch.each do |output, inputs|
            system[@virtual_switcher].switch({ inputs => output })
        end
    end

    def subscribe_virtual_inputs
        # unsubscribe to changes
        clear_encoder_subs
        unsubscribe(@virtual_input_sub) if @virtual_input_sub

        # subscribe to switcher details
        @virtual_input_sub = system.subscribe(@virtual_switcher, :input_mappings) do |notify|
            logger.debug { "Detected change of input mappings on #{@virtual_switcher} - resubscribing" }
            subscribe_encoders notify.value
        end
    end

    def clear_encoder_subs
        @subscriptions ||= []
        @subscriptions.each { |ref| unsubscribe(ref) }
        @subscriptions.clear
    end

    def subscribe_encoders(input_mappings)
        clear_encoder_subs
        @auto_switch.each do |output, inputs|
            inputs.each do |input|
                input = input.to_s
                input_details = input_mappings[input]
                session_index = input_details[:session] - 1
                encoder_name = input_details[:encoder]

                encoder = system[encoder_name]
                next if encoder.nil?

                sessions = encoder[:sessions]
                next unless sessions
                vc2_name = sessions.dig(session_index, :video, :encoder)
                next unless vc2_name
                input_name = (Array(encoder[:encoders]).select { |enc| enc[:name] == vc2_name }).dig(0, :input)
                next unless input_name

                @subscriptions << system.subscribe(encoder_name, :inputs) do |notify|
                    if @enabled
                        check_auto_switch output, inputs, input, input_name, notify.value
                    end
                end
            end
        end
    end

    def check_auto_switch(auto_output, auto_inputs, checking_input, input_name, encoder_inputs)
        input_details = (encoder_inputs.select { |enc_inp| enc_inp[:name] == input_name })[0]
        return unless input_details

        current_value = @last_known_state[checking_input]
        new_value = input_details[:cabledetect]
        if current_value != new_value
            logger.debug { "Switching #{auto_inputs} => #{auto_output} as detected change on encoder input #{checking_input}" }
            @last_known_state[checking_input] = new_value
            system[@virtual_switcher].switch({ auto_inputs => auto_output })
        end
    end
end
